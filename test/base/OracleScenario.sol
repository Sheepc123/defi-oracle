// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";

import {MiniUSD} from "../../src/MiniUSD.sol";
import {LendingPool} from "../../src/LendingPool.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";

/// @title OracleScenario —— 三种 Oracle 共用的实验骨架
///
/// @notice ## 这个类存在的唯一理由
///
///         最终那张对比表要有意义，前提是三组数字**来自同一段代码**。
///         如果 A/B/C 各写各的攻击脚本，哪怕只是抵押顺序不同、平仓时机不同，
///         数字就不可比，D 的汇总表直接作废。
///
///         所以：攻击时序和指标计算全部封死在这里，子类只填三个洞。
///         **不要在子类里覆盖 runAttack()。** 需要改攻击流程请在组里同步后改本文件。
///
///         ## 子类要实现的三个 hook
///
///         | hook                | 职责                                        |
///         | ------------------- | ------------------------------------------- |
///         | `_deployOracle()`   | 部署 DEX（可多个）+ Oracle，注入流动性        |
///         | `_manipulate(预算)` | 花 mUSD 推高报价，返回 (实际花掉, 换到的 ETH) |
///         | `_unwind()`         | 把 ETH 全换回 mUSD，返回换回的数量            |
///         | `_warmUp()`（可选） | 攻击前的预热，TWAP 需要它积累观测点            |
///
///         最小实现范例见同目录的 OracleScenario.t.sol。
///
/// @dev ## 指标定义：为什么是「超额借款 − 操纵成本」
///
///      攻击者有两条路可走：
///
///        (a) 诚实借款：抵押 10 ETH，按真实报价借 13,333 mUSD
///        (b) 操纵后借款：抵押 10 ETH，推高报价，借 16,127 mUSD，然后平仓走人
///
///      两条路的抵押品**完全相同**，所以抵押品的成本在相减时消掉了。
///      两条路的差额就是：
///
///          净利 = (多借到的 mUSD) − (操纵 DEX 的往返损失)
///
///      净利为正 = 这个 Oracle 在这个参数下可被**盈利**攻击。
///      这才是能横向比较的量。
///
///      ⚠️ 不要用「攻击后报价偏离了多少」当核心指标。
///      TWAP 在单区块操纵下的偏离必然是 0，那是定义决定的，不是实验发现。
///      详见 README.md「价格累加器」一节。
abstract contract OracleScenario is Test {
    // ─────────────────────────────────────────────────────────
    // 全局固定参数 —— 三种场景必须一致，否则数字不可比
    // ─────────────────────────────────────────────────────────

    /// @notice 全系统 ETH 深度**预算**（不是「部署一个 100 ETH 的池」）。
    /// @dev 聚合场景拆成多个池时，各池之和不得超过这个值。
    ///      否则聚合版凭空多出几倍流动性，「聚合更稳健」里就混进了
    ///      「钱更多所以更难操纵」，结论不成立。


    uint256 internal constant TOTAL_ETH_DEPTH = 100 ether;


    /// @notice 全系统 mUSD 深度预算。与上面配对，保证初始价 = 2000。
    uint256 internal constant TOTAL_TOKEN_DEPTH = 200_000e18;



    /// @notice 参考市场价：1 ETH = 2000 mUSD。所有偏离度都相对它计算。
    uint256 internal constant REFERENCE_PRICE = 2000e18;


    /// @notice 借贷池的可借资金
    uint256 internal constant POOL_FUNDING = 200_000e18;

    /// @notice 攻击者的 mUSD 预算。必须 ≥ 最大攻击档位。
    uint256 internal constant ATTACKER_TOKEN_BUDGET = 500_000e18;

    /// @notice 攻击者的 ETH 抵押品
    uint256 internal constant ATTACKER_COLLATERAL = 10 ether;

    /// @notice 起始时间戳。
    /// @dev Foundry 默认 block.timestamp = 1，TWAP 的窗口运算会贴到 0 边界，
    ///      出现「窗口比链的历史还长」这种测试专属的怪状态。设成一个正常的
    ///      Unix 时间戳可以彻底避开。
    uint256 internal constant START_TIME = 1_700_000_000;

    /// @notice 标准攻击规模档位（mUSD）。A/B/C 统一扫这四档，便于横向对齐。
    /// @dev 首元素必须显式转 uint256，否则 Solidity 会按最小容纳类型推断
    ///      整个数组的类型（uint80[4]），无法隐式转成 uint256[4]。
    
    function attackSizes() internal pure returns (uint256[4] memory) {
        return [uint256(50_000e18), 100_000e18, 200_000e18, 400_000e18];
    }

    // ─────────────────────────────────────────────────────────
    // 共享部署产物
    // ─────────────────────────────────────────────────────────

    MiniUSD internal token;
    LendingPool internal pool;
    IPriceOracle internal oracle;
    address internal attacker;

    // ─────────────────────────────────────────────────────────
    // 子类 hook
    // ─────────────────────────────────────────────────────────

    /// @notice 部署 DEX（一个或多个）+ Oracle，注入流动性，返回 Oracle 地址。
    ///
    /// @dev 调用时 `token` 已经部署好，测试合约持有全部 1,000,000 mUSD 和 1000 ETH，
    ///      直接 `token.approve(...)` + `dex.initializeLiquidity{value: ...}(...)` 即可。
    ///
    ///      约束：所有池的 ETH 之和 ≤ TOTAL_ETH_DEPTH，
    ///            mUSD 之和 ≤ TOTAL_TOKEN_DEPTH，
    ///            且每个池的初始价都必须是 2000（tokenAmount / ethAmount == 2000）。
    function _deployOracle() internal virtual returns (IPriceOracle);

    /// @notice 攻击者花 mUSD 推高报价。
    ///
    /// @param tokenBudget 本轮允许花掉的 mUSD 上限
    /// @return tokenSpent 实际花掉的 mUSD（多池场景可以只花一部分预算）
    /// @return ethGained  换到的 ETH 总量
    ///
    /// @dev 调用时已经处于 `vm.startPrank(attacker)` 上下文，
    ///      所以里面的 `token.approve(...)` / `dex.swap...` 都是以攻击者身份发出的。
    ///
    ///      ⚠️ 多池场景必须把「每个池各换到多少 ETH」记到子类自己的 storage 里，
    ///      因为 `_unwind()` 不接收参数 —— 平仓要按池分别换回，一个总量是不够的。
    function _manipulate(uint256 tokenBudget) internal virtual returns (uint256 tokenSpent, uint256 ethGained);

    /// @notice 攻击者平仓：把手上全部 ETH 换回 mUSD。
    /// @return tokenReturned 换回的 mUSD 总量
    /// @dev 同样处于 `vm.startPrank(attacker)` 上下文。
    ///      故意不接收参数，见 `_manipulate` 的说明。
    function _unwind() internal virtual returns (uint256 tokenReturned);

    /// @notice 攻击前的预热。默认空实现。
    /// @dev TWAP 必须覆盖它：构造完 Oracle 之后立刻 getPrice() 会因为
    ///      elapsed == 0 而 revert，必须先推进时间并周期性 update()
    ///      把窗口填满。参考写法：
    ///
    ///          function _warmUp() internal override {
    ///              for (uint256 i = 0; i < window / 60; i++) {
    ///                  _advance(60);
    ///                  twap.update();
    ///              }
    ///          }
    function _warmUp() internal virtual {}

    // ─────────────────────────────────────────────────────────
    // 部署
    // ─────────────────────────────────────────────────────────

    /// @dev 子类若要覆盖 setUp()，必须先调 `super.setUp()`。
    function setUp() public virtual {
        // 先把时间挪到一个正常的时间戳，再做任何部署
        vm.warp(START_TIME);
        vm.roll(1);

        attacker = makeAddr("attacker");

        token = new MiniUSD(); // 全部 1,000,000 mUSD 都在 address(this)
        vm.deal(address(this), 1000 ether);

        // 子类在这里部署 DEX 和 Oracle
        oracle = _deployOracle();

        pool = new LendingPool(address(token), address(oracle));
        token.approve(address(pool), POOL_FUNDING);
        pool.fund(POOL_FUNDING);

        token.transfer(attacker, ATTACKER_TOKEN_BUDGET);

        // mUSD 预算分配（总量 1,000,000）：
        //   DEX 流动性  200,000
        //   借贷池资金  200,000
        //   攻击者预算  500,000
        //   余量        100,000
        _warmUp();

        // 实验前提：三种 Oracle 的基线报价必须都等于参考价，否则对比无意义。
        // 放在 _warmUp() 之后，因为 TWAP 预热完才有有效读数。
        assertEq(oracle.getPrice(), REFERENCE_PRICE, "baseline must equal reference price");
    }

    /// @notice 同时推进时间和区块号。
    /// @dev 只 vm.warp 不 vm.roll 会造出「同一区块但时间变了」的状态，
    ///      在累加器相关的逻辑里会得到现实中不可能出现的结果。
    ///      按 12 秒一个区块折算（以太坊主网出块间隔）。
    function _advance(uint256 secs) internal {
        vm.warp(block.timestamp + secs);
        vm.roll(block.number + secs / 12 + 1);
    }

    // ─────────────────────────────────────────────────────────
    // 统一指标
    // ─────────────────────────────────────────────────────────

    /// @notice 一次攻击的完整结果。字段顺序与 RESULTS.md 的表格列对应。
    struct Result {
        string name; // oracle.description()
        uint256 priceBefore; // 攻击前 Oracle 报价，18 位定点
        uint256 priceAfter; // 攻击后 Oracle 报价
        int256 deviationBps; // (priceAfter − 参考价) / 参考价，bps。可以为负
        uint256 tokenSpent; // 攻击者投入的 mUSD
        uint256 ethGained; // 操纵过程中换到的 ETH
        uint256 tokenReturned; // 平仓换回的 mUSD
        int256 attackCost; // tokenSpent − tokenReturned。正数 = 亏损
        uint256 extraBorrow; // 因报价失真多借到的 mUSD
        int256 netProfit; // extraBorrow − attackCost。正数 = 攻击有利可图
        uint256 badDebt; // 平仓后协议承担的坏账
    }

    /// @notice 完整攻击闭环：抵押 → 操纵 → 借满 → 平仓 → 结算。
    ///
    /// @param tokenBudget 本轮攻击预算（mUSD）
    ///
    /// @dev 三种 Oracle 走的是同一段代码，这是可比性的唯一来源。不要在子类覆盖它。
    function runAttack(uint256 tokenBudget) internal returns (Result memory r) {
        assertGe(token.balanceOf(attacker), tokenBudget, "attacker budget too small for this size");

        r.name = oracle.description();
        r.priceBefore = oracle.getPrice();

        // ── 1. 攻击者抵押 ETH，建立头寸 ──────────────────────
        // vm.deal 是覆盖式赋值，所以攻击者的 ETH 余额从这一刻起完全可控：
        // 存完抵押品后归零，之后余额里的 ETH 只可能来自操纵所得。
        vm.deal(attacker, ATTACKER_COLLATERAL);
        vm.prank(attacker);
        pool.depositETH{value: ATTACKER_COLLATERAL}();

        uint256 borrowBefore = pool.availableToBorrow(attacker);

        // ── 2. 操纵 DEX 报价 ─────────────────────────────────
        vm.startPrank(attacker);
        (r.tokenSpent, r.ethGained) = _manipulate(tokenBudget);
        vm.stopPrank();

        r.priceAfter = oracle.getPrice();

        uint256 borrowAfter = pool.availableToBorrow(attacker);
        r.extraBorrow = borrowAfter > borrowBefore ? borrowAfter - borrowBefore : 0;

        // ── 3. 趁报价失真把额度借满 ──────────────────────────
        // 真的调 borrow()，而不是只读 availableToBorrow：
        // 要确认这笔钱能真正提出来，而不是一个纸面数字。
        if (borrowAfter > 0) {
            vm.prank(attacker);
            pool.borrow(borrowAfter);
        }

        // ── 4. 平仓，报价回落 ────────────────────────────────
        vm.startPrank(attacker);
        r.tokenReturned = _unwind();
        vm.stopPrank();

        // ── 5. 结算 ─────────────────────────────────────────
        r.attackCost = int256(r.tokenSpent) - int256(r.tokenReturned);
        r.netProfit = int256(r.extraBorrow) - r.attackCost;
        r.deviationBps = ((int256(r.priceAfter) - int256(REFERENCE_PRICE)) * 10_000) / int256(REFERENCE_PRICE);

        // 平仓之后报价已经回到真实水平，此时的坏账就是协议的净损失
        r.badDebt = pool.badDebt(attacker);
    }

    /// @notice 打印一条结果。数字都按整数 mUSD / 整数价格输出，方便直接抄进表格。
    /// @dev 小数部分被截断。需要完整精度时直接看 Result 结构体的原始字段。
    function logResult(Result memory r) internal pure {
        console2.log("----------------------------------------");
        console2.log(r.name);
        console2.log("  token spent    (mUSD):", r.tokenSpent / 1e18);
        console2.log("  price before   (/ETH):", r.priceBefore / 1e18);
        console2.log("  price after    (/ETH):", r.priceAfter / 1e18);
        console2.log("  deviation       (bps):", r.deviationBps);
        console2.log("  attack cost    (mUSD):", r.attackCost / int256(1e18));
        console2.log("  extra borrow   (mUSD):", r.extraBorrow / 1e18);
        console2.log("  NET PROFIT     (mUSD):", r.netProfit / int256(1e18));
        console2.log("  protocol bad debt    :", r.badDebt / 1e18);
    }

    /// @notice 扫描四档攻击规模，返回结果数组并打印。
    ///
    /// @dev 返回值给 D 用：直接遍历它生成 RESULTS.md 的表格，不必重新跑一遍。
    ///
    ///      ⚠️【给 B 的提醒】这里用 snapshotState / revertToState 在档位之间重置状态。
    ///      Foundry 的快照会把 block.timestamp 一起还原，本仓库已实测确认
    ///      （见 OracleScenario.t.sol 的 testSnapshotRestoresTimestamp）。
    ///      但如果你的 TWAP 实验依赖精确的时间轴，更稳妥的做法是每档单独写一个
    ///      test 函数 —— 每个 test 都从干净的 setUp() 开始，不存在任何残留。


    function sweep() internal returns (Result[4] memory results) {
        uint256[4] memory sizes = attackSizes();

        for (uint256 i = 0; i < sizes.length; i++) {
            uint256 snap = vm.snapshotState();

            results[i] = runAttack(sizes[i]);
            logResult(results[i]);

            vm.revertToState(snap);
        }
    }
}
