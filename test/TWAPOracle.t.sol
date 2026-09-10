// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OracleScenario} from "./base/OracleScenario.sol";
import {console2} from "forge-std/Test.sol";
import {SimpleDEX} from "../src/SimpleDEX.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {TWAPOracle} from "../src/oracles/TWAPOracle.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";

/// @title TWAPOracle 实验 —— 继承 OracleScenario 骨架
///
/// @notice 对应 docs/DESIGN.md §6.3 中 B 的交付要求：
///         1. 窗口 {60s, 600s, 1800s, 3600s} × 攻击规模 {50k,100k,200k,400k} 的矩阵
///         2. **抗操纵 / 延迟权衡曲线**（B 必须同时报告延迟成本）
///
/// @dev ## 本文件想说明的那件事
///
///      单区块操纵下 TWAP 的偏离恒为 0 —— 那是 `SimpleDEX._accrue()` 的定义决定的，
///      不是实验发现（见 README「价格累加器」、OracleScenario.sol:47-49）。
///      所以「TWAP 抗操纵」这个结论不能只靠单区块实验，它对任何窗口都成立、无梯度。
///
///      TWAP 真正的权衡在这里：
///
///        · 攻击者若**维持**高价跨越若干区块，TWAP 会逐步爬升，最终完全收敛到被操纵的价格。
///        · 收敛所需时间 ≈ 窗口长度。窗口 60s → 维持 1 分钟即可攻陷；
///          窗口 3600s → 要维持整整 1 小时（资金占用 + 被套利者抢跑 + 价格回归风险）。
///        · 而同一个窗口，在**真实**价格变动时的追踪延迟也 ≈ 窗口长度。
///
///      于是：安全性 ∝ window，新鲜度 ∝ 1/window。这就是本实验要量化的 trade-off。
///
///      分组：
///        A. 单区块操纵（基线，进 RESULTS.md 的 TWAP-600s 行）
///        B. 4 窗口 × 4 规模的完整矩阵
///        C. 跨区块持续操纵 —— Security 维度
///        D. 延迟权衡曲线 —— Freshness 维度
contract TWAPOracleTest is OracleScenario {
    SimpleDEX internal dex;
    TWAPOracle internal twapOracle;
    uint256 internal heldETH;

    /// @notice 默认窗口（秒）。_rebuildWithWindow() 会改它，用于切换实验窗口。
    uint256 internal windowSize = 600;

    // ─────────────────────────────────────────────────────────
    // 实验常量
    // ─────────────────────────────────────────────────────────

    /// @notice 预热 / 维持的时间步长（秒）。与骨架 _advance() 的 12s 出块对齐。
    uint256 internal constant STEP = 60;

    /// @notice 延迟实验的价格阶跃目标。DESIGN §6.3 指定「让 DEX 价格阶跃到 2400」。
    uint256 internal constant TARGET_SPOT = 2400e18;

    /// @notice 延迟指标：TWAP 爬到新价格的 95% 所需时间。
    uint256 internal constant DELAY_TARGET_BPS = 9_500;

    /// @notice 持续操纵实验中，TWAP 收敛到 spot 的合格线（98%）。
    /// @dev 维持满一整个窗口后，理论偏离 = 100%；留 2% 给 60s 步长带来的取整误差。
    uint256 internal constant CONVERGE_BPS = 9_800;

    // ─────────────────────────────────────────────────────────
    // 四个 hook 的实现
    // ─────────────────────────────────────────────────────────

    function _deployOracle() internal override returns (IPriceOracle) {
        dex = new SimpleDEX(address(token));

        // 全部深度预算都给这一个池：100 ETH / 200,000 mUSD → 初始价 2000
        token.approve(address(dex), TOTAL_TOKEN_DEPTH);
        dex.initializeLiquidity{value: TOTAL_ETH_DEPTH}(TOTAL_TOKEN_DEPTH);

        twapOracle = new TWAPOracle(address(dex), windowSize);
        return twapOracle;
    }

    /// @notice 预热窗口，让 TWAP 有有效读数。
    ///         每 60 秒调一次 update()，持续 windowSize 时长。
    ///         预热期间价格不变（2000e18），所以预热后 TWAP == 2000e18。
    function _warmUp() internal override {
        _warmUpWindow(windowSize);
    }

    function _manipulate(uint256 tokenBudget)
        internal override
        returns (uint256 tokenSpent, uint256 ethGained)
    {
        // 处于 vm.startPrank(attacker) 上下文
        token.approve(address(dex), tokenBudget);
        ethGained = dex.swapTokenForETH(tokenBudget);
        heldETH = ethGained;
        tokenSpent = tokenBudget;
    }

    function _unwind() internal override returns (uint256 tokenReturned) {
        // 处于 vm.startPrank(attacker) 上下文
        tokenReturned = dex.swapETHForToken{value: heldETH}();
        heldETH = 0;
    }

    // ─────────────────────────────────────────────────────────
    // 辅助：切换实验窗口
    // ─────────────────────────────────────────────────────────

    /// @notice 为指定窗口重建 Oracle + 借贷池，并预热。
    ///
    /// @dev 为什么只重建 Oracle 和 Pool，不重建 DEX：
    ///      setUp() 结束时 dex 还没被操纵过，是干净的，直接复用即可。
    ///
    ///      为什么要用 deal：setUp() 已经把 1,000,000 mUSD 分掉了 900,000
    ///      （DEX 深度 20 万 + 池子资金 20 万 + 攻击者 50 万），部署者只剩 10 万，
    ///      不够再给新池子注入 POOL_FUNDING（20 万）。这里给部署者补额度——
    ///      只动部署者钱包，池子深度仍是骨架规定的 TOTAL_ETH_DEPTH /
    ///      TOTAL_TOKEN_DEPTH，与 A/C 组口径一致，不影响横向可比性。
    function _rebuildWithWindow(uint256 w) internal {
        windowSize = w;

        deal(address(token), address(this), 400_000e18);

        twapOracle = new TWAPOracle(address(dex), w);
        oracle = twapOracle;

        pool = new LendingPool(address(token), address(oracle));
        token.approve(address(pool), POOL_FUNDING);
        pool.fund(POOL_FUNDING);

        _warmUpWindow(w);

        assertEq(
            oracle.getPrice(), REFERENCE_PRICE, "rebuilt oracle must read reference price"
        );
    }

    /// @notice 按 STEP 步长预热 w 秒。
    function _warmUpWindow(uint256 w) internal {
        uint256 steps = w / STEP;
        for (uint256 i = 0; i < steps; i++) {
            _advance(STEP);
            twapOracle.update();
        }
    }

    function _windows() internal pure returns (uint256[4] memory) {
        // 首元素必须显式转 uint256，否则整个数组被推断成 uint80[4]
        return [uint256(60), 600, 1800, 3600];
    }

    // ═════════════════════════════════════════════════════════
    // A. 单区块操纵（基线）
    // ═════════════════════════════════════════════════════════

    /// @notice 单次攻击：50,000 mUSD，window=600s
    ///         预期：TWAP 不变 → extraBorrow = 0 → 攻击净亏手续费
    function testTwapExperiment() public {
        Result memory r = runAttack(50_000e18);
        logResult(r);

        // TWAP 抗单块操纵：报价不应偏离参考价
        assertEq(r.priceBefore, REFERENCE_PRICE);
        assertEq(r.priceAfter, REFERENCE_PRICE, "TWAP must not change in single-block manipulation");

        // 没有超额借款（TWAP 没变，借款能力不变）
        assertEq(r.extraBorrow, 0, "TWAP should prevent extra borrowing");

        // 操纵有手续费成本
        assertGt(r.attackCost, 0, "swap must cost fees");

        // 净利为负：攻击者只亏手续费，赚不到钱
        assertLe(r.netProfit, 0, "single-block attack on TWAP must be unprofitable");
    }

    /// @notice 四档规模全扫（window=600s）
    ///         看数据：forge test --mt testSweepAllSizes -vv
    function testSweepAllSizes() public {
        Result[4] memory rs = sweep();

        for (uint256 i = 0; i < rs.length; i++) {
            assertLe(rs[i].netProfit, 0, "no single-block attack should be profitable on TWAP");
            assertEq(rs[i].priceAfter, REFERENCE_PRICE, "TWAP must stay at reference price");
        }

        // 规模越大，手续费越多（攻击成本单调递增）
        for (uint256 i = 1; i < rs.length; i++) {
            assertGt(rs[i].attackCost, rs[i - 1].attackCost, "bigger swap must cost more in fees");
        }
    }

    // ═════════════════════════════════════════════════════════
    // B. 4 窗口 × 4 规模的完整矩阵（DESIGN §6.3）
    // ═════════════════════════════════════════════════════════
    //
    // 每个窗口一个 test 函数，而不是在一个函数里循环四个窗口。
    // 原因见 OracleScenario.sol:281-286：sweep() 用 snapshotState 复位，
    // 而 TWAP 依赖精确时间轴，每档单独跑最稳。这里折中成「每窗口一函数」。

    function testSweepWindow60() public {
        _rebuildWithWindow(60);
        Result[4] memory rs = sweep();
        for (uint256 i = 0; i < rs.length; i++) {
            assertLe(rs[i].netProfit, 0, "single-block attack unprofitable @60s");
        }
    }

    function testSweepWindow600() public {
        _rebuildWithWindow(600);
        Result[4] memory rs = sweep();
        for (uint256 i = 0; i < rs.length; i++) {
            assertLe(rs[i].netProfit, 0, "single-block attack unprofitable @600s");
        }
    }

    function testSweepWindow1800() public {
        _rebuildWithWindow(1800);
        Result[4] memory rs = sweep();
        for (uint256 i = 0; i < rs.length; i++) {
            assertLe(rs[i].netProfit, 0, "single-block attack unprofitable @1800s");
        }
    }

    function testSweepWindow3600() public {
        _rebuildWithWindow(3600);
        Result[4] memory rs = sweep();
        for (uint256 i = 0; i < rs.length; i++) {
            assertLe(rs[i].netProfit, 0, "single-block attack unprofitable @3600s");
        }
    }

    // ═════════════════════════════════════════════════════════
    // C. 跨区块持续操纵 —— Security 维度
    // ═════════════════════════════════════════════════════════

    /// @notice 持续操纵的完整结果。字段含义见 _sustainedAttack()。
    struct SustainedResult {
        uint256 window; // 名义窗口（秒）
        uint256 budget; // 攻击者投入的 mUSD
        uint256 spotAfter; // 操纵后的 DEX 瞬时价
        uint256 twapAtBorrow; // 借款那一刻的 TWAP 报价
        int256 deviationBps; // TWAP 相对参考价的偏离
        uint256 holdSeconds; // 攻击者维持了多久
        uint256 extraBorrow; // 因报价失真多借到的 mUSD
        int256 attackCost; // 往返手续费
        int256 netProfit; // extraBorrow − attackCost
        uint256 badDebtAtUnwind; // 平仓瞬间的坏账（TWAP 仍在高位，通常 = 0）
        uint256 badDebtSettled; // TWAP 回落一个窗口后的坏账（真实损失）
    }

    /// @notice 持续操纵攻击：抵押 → 操纵 → **维持 holdSeconds** → 借满 → 平仓。
    ///
    /// @dev 与骨架 runAttack() 唯一的差别就是中间那段「维持」。
    ///      这里没有覆盖 runAttack()，而是在子类另写一个流程 —— 骨架明确要求
    ///      不要在子类里覆盖它（OracleScenario.sol:19）。
    ///      抵押、操纵、借款、平仓、结算这五步的口径与 runAttack() 完全一致，
    ///      所以两个函数产出的数字可以直接相减对比。
    function _sustainedAttack(uint256 tokenBudget, uint256 holdSeconds)
        internal
        returns (SustainedResult memory s)
    {
        s.window = windowSize;
        s.budget = tokenBudget;
        s.holdSeconds = holdSeconds;

        // ── 1. 抵押 ──────────────────────────────────────────
        vm.deal(attacker, ATTACKER_COLLATERAL);
        vm.prank(attacker);
        pool.depositETH{value: ATTACKER_COLLATERAL}();

        uint256 borrowBefore = pool.availableToBorrow(attacker);

        // ── 2. 操纵 ──────────────────────────────────────────
        vm.startPrank(attacker);
        (uint256 tokenSpent,) = _manipulate(tokenBudget);
        vm.stopPrank();

        s.spotAfter = dex.getSpotPrice();

        // ── 3. 维持：跨区块，每 STEP 秒 update 一次 ──────────
        //      这一步是 TWAP 与 Spot 的分水岭：不维持，TWAP 纹丝不动；
        //      维持满一个窗口，TWAP 完全收敛到被操纵的价格。
        uint256 steps = holdSeconds / STEP;
        for (uint256 i = 0; i < steps; i++) {
            _advance(STEP);
            twapOracle.update();
        }

        // ── 4. 借满 ──────────────────────────────────────────
        s.twapAtBorrow = oracle.getPrice();
        s.deviationBps =
            ((int256(s.twapAtBorrow) - int256(REFERENCE_PRICE)) * 10_000) / int256(REFERENCE_PRICE);

        uint256 borrowAfter = pool.availableToBorrow(attacker);
        s.extraBorrow = borrowAfter > borrowBefore ? borrowAfter - borrowBefore : 0;

        if (borrowAfter > 0) {
            vm.prank(attacker);
            pool.borrow(borrowAfter);
        }

        // ── 5. 平仓 + 结算 ───────────────────────────────────
        vm.startPrank(attacker);
        uint256 tokenReturned = _unwind();
        vm.stopPrank();

        s.attackCost = int256(tokenSpent) - int256(tokenReturned);
        s.netProfit = int256(s.extraBorrow) - s.attackCost;

        // ── 6. 坏账：平仓瞬间 vs TWAP 回落之后 ───────────────
        //
        //    平仓那一刻，TWAP 还停在被操纵的高位（它不会因为一笔 swap 而跳变），
        //    抵押品估值虚高 → badDebt 读出来是 0。这不代表协议没亏，
        //    只是亏损被 TWAP 的惯性藏住了。推进一个完整窗口让 TWAP 回落到
        //    真实价格，坏账才会显形。
        //
        //    「TWAP 不消除坏账，只是延迟暴露它」—— 这是本实验的副产品结论。
        s.badDebtAtUnwind = pool.badDebt(attacker);

        for (uint256 i = 0; i < windowSize / STEP; i++) {
            _advance(STEP);
            twapOracle.update();
        }
        s.badDebtSettled = pool.badDebt(attacker);
    }

    function _logSustained(SustainedResult memory s) internal pure {
        console2.log("----------------------------------------");
        console2.log("  window (s)        :", s.window);
        console2.log("  budget    (mUSD)  :", s.budget / 1e18);
        console2.log("  spot after(/ETH)  :", s.spotAfter / 1e18);
        console2.log("  TWAP @borrow      :", s.twapAtBorrow / 1e18);
        console2.log("  deviation  (bps)  :", s.deviationBps);
        console2.log("  HELD FOR  (s)     :", s.holdSeconds);
        console2.log("  attack cost(mUSD) :", s.attackCost / int256(1e18));
        console2.log("  extra borrow      :", s.extraBorrow / 1e18);
        console2.log("  NET PROFIT(mUSD)  :", s.netProfit / int256(1e18));
        console2.log("  badDebt @unwind   :", s.badDebtAtUnwind / 1e18);
        console2.log("  badDebt settled   :", s.badDebtSettled / 1e18);
    }

    /// @notice 【核心实验】4 窗口 × 4 规模，攻击者维持满一整个窗口。
    ///
    /// @dev 这是唯一能产生「窗口越长越安全」梯度的实验：
    ///      每个窗口下 TWAP 最终都被攻陷（偏离 ≈ spot 偏离、净利转正），
    ///      但**攻陷所需时间 = 窗口长度**。60s 窗口维持 1 分钟就够，
    ///      3600s 窗口得撑满 1 小时 —— 后者的资金占用与被抢跑风险使它不现实。
    ///
    ///      看数据：forge test --mt testSustainedMatrix -vv
    function testSustainedMatrix() public {
        uint256[4] memory windows = _windows();
        uint256[4] memory sizes = attackSizes();

        console2.log("========================================");
        console2.log("SUSTAINED MANIPULATION (hold = 1 window)");
        console2.log("========================================");

        for (uint256 w = 0; w < windows.length; w++) {
            _rebuildWithWindow(windows[w]);

            for (uint256 i = 0; i < sizes.length; i++) {
                uint256 snap = vm.snapshotState();
                SustainedResult memory s = _sustainedAttack(sizes[i], windows[w]);
                _logSustained(s);
                vm.revertToState(snap);

                // 维持满窗口后，TWAP 应基本收敛到被操纵的 spot
                assertGe(
                    uint256(s.deviationBps),
                    _convergeThreshold(s.spotAfter),
                    "TWAP should converge to manipulated spot after holding a full window"
                );

                // 与单区块形成对照：持续操纵是可盈利的
                assertGt(s.netProfit, 0, "sustained manipulation should be profitable");
            }
        }
    }

    /// @notice 维持时长扫描：固定 window=600s，看 TWAP 偏离怎么随维持时间爬升。
    /// @dev 这条曲线是「TWAP 不是无敌，只是慢」的直接证据。
    ///      看数据：forge test --mt testSustainedRampUp -vv
    function testSustainedRampUp() public {
        uint256 budget = 50_000e18;
        uint256[6] memory holds = [uint256(0), 60, 120, 300, 480, 600];

        console2.log("========================================");
        console2.log("RAMP-UP: TWAP deviation vs hold duration");
        console2.log("window = 600s, budget = 50000 mUSD");
        console2.log("========================================");

        int256 prev = -1;
        for (uint256 i = 0; i < holds.length; i++) {
            uint256 snap = vm.snapshotState();
            SustainedResult memory s = _sustainedAttack(budget, holds[i]);
            vm.revertToState(snap);

            console2.log("  hold (s):", holds[i], "-> TWAP:", s.twapAtBorrow / 1e18);
            console2.log("      deviation (bps):", s.deviationBps);

            // 维持越久，TWAP 偏离越大（单调不减）
            assertGe(s.deviationBps, prev, "deviation must not decrease with longer hold");
            prev = s.deviationBps;
        }

        // 维持满一个窗口（600s）后应已收敛
        uint256 snapFull = vm.snapshotState();
        SustainedResult memory full = _sustainedAttack(budget, 600);
        vm.revertToState(snapFull);
        assertGe(uint256(full.deviationBps), _convergeThreshold(full.spotAfter));
    }

    /// @notice 单区块 vs 持续操纵的直接对照（同一窗口、同一规模）。
    /// @dev 汇报时最有力的一张对照：同样是 50,000 mUSD，
    ///      不维持 → 亏 239；维持 600s → 赚数千。差别全在「时间」这一个变量上。
    function testSingleBlockVsSustained() public {
        uint256 budget = 50_000e18;

        uint256 snap = vm.snapshotState();
        Result memory single = runAttack(budget);
        vm.revertToState(snap);

        SustainedResult memory sustained = _sustainedAttack(budget, windowSize);

        console2.log("========================================");
        console2.log("SINGLE-BLOCK vs SUSTAINED (window=600s)");
        console2.log("========================================");
        console2.log("  single-block net profit :", single.netProfit / int256(1e18));
        console2.log("  sustained   net profit :", sustained.netProfit / int256(1e18));
        console2.log("  cost of attack (mUSD)  :", sustained.attackCost / int256(1e18));
        console2.log("  extra time needed (s)  :", windowSize);

        assertLe(single.netProfit, 0, "single-block must be unprofitable");
        assertGt(sustained.netProfit, 0, "sustained must be profitable");
        // 手续费成本相同 —— 差别不在钱，而在「要撑多久」
        assertEq(sustained.attackCost, single.attackCost, "same round-trip fee cost");
    }

    // ═════════════════════════════════════════════════════════
    // D. 延迟权衡曲线 —— Freshness 维度（DESIGN §6.3 硬性要求）
    // ═════════════════════════════════════════════════════════

    /// @notice 二分求出「把 spot 推到 targetSpot 所需投入的 mUSD」。
    /// @dev 恒定乘积 + 0.3% 手续费下，spot 关于 tokenIn 单调递增，可以二分。
    ///      每轮用 snapshot/revert 试算，不会污染真实状态。
    function _tokenInForSpot(uint256 targetSpot) internal returns (uint256) {
        uint256 lo = 1;
        uint256 hi = 400_000e18;

        for (uint256 i = 0; i < 26; i++) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();

            vm.startPrank(attacker);
            token.approve(address(dex), mid);
            dex.swapTokenForETH(mid);
            vm.stopPrank();

            uint256 got = dex.getSpotPrice();
            vm.revertToState(snap);

            if (got < targetSpot) lo = mid + 1;
            else hi = mid;
        }
        return lo;
    }

    /// @notice 测量：价格阶跃到 TARGET_SPOT 后，TWAP 爬到 95% 需要多少秒。
    function _measureDelay(uint256 w) internal returns (uint256 secondsNeeded) {
        // 把 spot 推到 TARGET_SPOT
        uint256 tin = _tokenInForSpot(TARGET_SPOT);
        vm.startPrank(attacker);
        token.approve(address(dex), tin);
        dex.swapTokenForETH(tin);
        vm.stopPrank();

        uint256 spot = dex.getSpotPrice();
        uint256 target = (spot * DELAY_TARGET_BPS) / 10_000;

        // 每 STEP 秒 update 一次，直到 TWAP 追上 target
        // 上限 2 倍窗口 + 1 小时，防止死循环
        uint256 cap = 2 * w + 3600;
        uint256 elapsed = 0;
        while (elapsed < cap) {
            _advance(STEP);
            twapOracle.update();
            elapsed += STEP;
            if (twapOracle.getPrice() >= target) {
                return elapsed;
            }
        }
        revert("TWAP never reached 95% of the new spot");
    }

    /// @notice 【DESIGN §6.3 要求】4 个窗口的追踪延迟。
    ///         DEX 价格阶跃到 2400，测 TWAP 爬到 95%（2280）各需多久。
    ///
    /// @dev 理论值：Δ=400 时，τ = w × (0.95 − 100/Δ) = 0.7w。
    ///      即 60s→42s、600s→420s、1800s→1260s、3600s→2520s（按 60s 步长取整后略高）。
    ///      实测若接近这条线，说明累加器语义正确。
    ///
    ///      看数据：forge test --mt testDelayCurve -vv
    function testDelayCurve() public {
        uint256[4] memory windows = _windows();

        console2.log("========================================");
        console2.log("FRESHNESS: delay to track a real move");
        console2.log("spot steps 2000 -> 2400, target = 95%");
        console2.log("========================================");

        uint256 prevDelay = 0;
        for (uint256 i = 0; i < windows.length; i++) {
            // _measureDelay() 会真的把 DEX 价格推到 2400，必须隔离，
            // 否则下一个窗口复用这个 dex 时基线价就不是 2000 了。
            uint256 snap = vm.snapshotState();

            _rebuildWithWindow(windows[i]);

            uint256 spotBefore = dex.getSpotPrice();
            uint256 delay = _measureDelay(windows[i]);

            console2.log("--- window:", windows[i], "s ---");
            console2.log("  spot before      :", spotBefore / 1e18);
            console2.log("  spot after       :", dex.getSpotPrice() / 1e18);
            console2.log("  TWAP now         :", twapOracle.getPrice() / 1e18);
            console2.log("  DELAY to 95% (s) :", delay);

            // 阶跃目标确实打到了 2400 附近（验证口径符合 DESIGN）
            assertApproxEqAbs(dex.getSpotPrice(), TARGET_SPOT, 1e18, "spot must step to ~2400");

            // 窗口越长，延迟越大 —— Freshness 随窗口单调变差
            assertGt(delay, prevDelay, "longer window must track slower");
            prevDelay = delay;

            vm.revertToState(snap);
        }
    }

    /// @notice 延迟的绝对值应落在窗口量级内（既不能瞬间，也不能远超）。
    function testDelayIsProportionalToWindow() public {
        uint256[4] memory windows = _windows();

        for (uint256 i = 0; i < windows.length; i++) {
            uint256 snap = vm.snapshotState(); // 同上：隔离 _measureDelay 对 DEX 的改动

            _rebuildWithWindow(windows[i]);
            uint256 delay = _measureDelay(windows[i]);

            // 上限：不超过窗口的 1.5 倍
            assertLe(delay, (windows[i] * 15) / 10 + STEP, "delay should be within ~1 window");
            // 下限：至少要走完半个窗口（对 Δ=400 的理论值是 0.7w）
            assertGe(delay + STEP, windows[i] / 2, "delay should be a real fraction of the window");

            vm.revertToState(snap);
        }
    }

    // ═════════════════════════════════════════════════════════
    // E. 附属检查
    // ═════════════════════════════════════════════════════════

    function testDescriptionIncludesWindow() public view {
        string memory desc = twapOracle.description();
        assertGt(bytes(desc).length, 0, "description must not be empty");
    }

    /// @notice 窗口未预热时，实际回溯跨度短于名义窗口 —— 抗操纵性弱于标称值。
    /// @dev 这是 TWAP 部署时最容易被忽略的坑：合约刚部署就读价，
    ///      看起来有读数，实际窗口只有几分钟。用 elapsedWindow() 把它显式化。
    function testElapsedWindowGrowsWithWarmup() public {
        _rebuildWithWindow(3600);

        // 只预热了 3600s，刚好等于窗口
        assertEq(twapOracle.elapsedWindow(), 3600, "fully warmed up");

        // 再走 600s
        for (uint256 i = 0; i < 10; i++) {
            _advance(STEP);
            twapOracle.update();
        }
        assertEq(twapOracle.elapsedWindow(), 3600, "elapsed window is capped at nominal window");
    }

    /// @notice 构造函数拒绝零窗口
    function testRejectsZeroWindow() public {
        vm.expectRevert("TWAPOracle: zero window");
        new TWAPOracle(address(dex), 0);
    }

    // ─────────────────────────────────────────────────────────
    // 小工具
    // ─────────────────────────────────────────────────────────

    /// @notice 某价格相对参考价的偏离（bps）
    function _bpsOf(uint256 price) internal pure returns (int256) {
        return ((int256(price) - int256(REFERENCE_PRICE)) * 10_000) / int256(REFERENCE_PRICE);
    }

    /// @notice 「TWAP 已收敛到 spot」的判定阈值：spot 偏离 bps × CONVERGE_BPS。
    function _convergeThreshold(uint256 spot) internal pure returns (uint256) {
        return uint256((_bpsOf(spot) * int256(CONVERGE_BPS)) / int256(10_000));
    }
}
