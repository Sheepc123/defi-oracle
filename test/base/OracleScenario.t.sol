// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OracleScenario} from "./OracleScenario.sol";

import {SimpleDEX} from "../../src/SimpleDEX.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";

/// @dev 只为验证 OracleScenario 骨架而存在的最小 Oracle。
///
///      ⚠️ **这不是 A 的交付物。** A 请在 `src/oracles/SpotOracle.sol` 里写正式版本
///      （建议把 label 做成构造参数，方便 C 复用为聚合器的单源包装器）。
///      这里刻意写得最简，是为了让自测只暴露骨架自身的问题。


contract HarnessSpotOracle is IPriceOracle {
    SimpleDEX public immutable dex;

    constructor(address dexAddress) {
        dex = SimpleDEX(dexAddress);
    }

    function getPrice() external view returns (uint256) {
        return dex.getSpotPrice();
    }

    function description() external pure returns (string memory) {
        return "harness-spot (self-test only)";
    }
}


/// @title OracleScenario 自测
///
/// @notice ## 为什么需要这个文件
///
///         `OracleScenario` 是要交给四个人共用的骨架。一个没有被任何具体实现
///         验证过的抽象基类，等于把调试成本平摊给下游三个人 ——
///         而且他们第一次遇到问题时，分不清是自己的 Oracle 写错了，还是骨架有 bug。
///
///         所以这里用一个最小的 Spot 实现把骨架跑通一遍，确认：
///           1. 三个 hook 的调用时序正确
///           2. 攻击者的 ETH / mUSD 会计是闭合的
///           3. 各项指标的符号和量级合理
///           4. sweep() 的快照回滚真的把时间也还原了（B 依赖这一点）
///
///         ## 顺便记录一个实测结论
///
///         Spot Oracle 在这套参数下是**灾难性**的：50,000 mUSD 的攻击预算
///         就能拿到数千 mUSD 的净利。A 的实验会给出完整曲线，这里只是确认
///         骨架能把这个信号测出来。


contract OracleScenarioSelfTest is OracleScenario {
    SimpleDEX internal dex;


    /// @dev 攻击者当前持有的、来自操纵所得的 ETH。
    ///      单池场景一个变量就够；多池场景（C）需要按池分别记录。
    uint256 internal heldETH;

    // ─────────────────────────────────────────────────────────
    // 三个 hook 的最小实现
    // ─────────────────────────────────────────────────────────



    function _deployOracle() internal override returns (IPriceOracle) {
        dex = new SimpleDEX(address(token));

        // 全部深度预算都给这一个池：100 ETH / 200,000 mUSD → 初始价 2000
        token.approve(address(dex), TOTAL_TOKEN_DEPTH);
        dex.initializeLiquidity{value: TOTAL_ETH_DEPTH}(TOTAL_TOKEN_DEPTH);

        return new HarnessSpotOracle(address(dex));
    }

    function _manipulate(uint256 tokenBudget)
        internal
        override
        returns (uint256 tokenSpent, uint256 ethGained)
    {
        // 处于 vm.startPrank(attacker) 上下文，所以这两个调用都是攻击者发出的

        token.approve(address(dex), tokenBudget);
        ethGained = dex.swapTokenForETH(tokenBudget);

        heldETH = ethGained;
        tokenSpent = tokenBudget; // 单池场景把预算一次花光
    }

    function _unwind() internal override returns (uint256 tokenReturned) {
        tokenReturned = dex.swapETHForToken{value: heldETH}();
        heldETH = 0;
    }

    // ─────────────────────────────────────────────────────────
    // 骨架自身的验证
    // ─────────────────────────────────────────────────────────

    /// @notice 部署结果符合预算：初始价 = 2000，且分配没有超发总供应。
    function testDeploymentMatchesBudget() public view {
        assertEq(dex.ethReserve(), TOTAL_ETH_DEPTH);
        assertEq(dex.tokenReserve(), TOTAL_TOKEN_DEPTH);
        assertEq(oracle.getPrice(), REFERENCE_PRICE);

        uint256 accounted = dex.tokenReserve() + token.balanceOf(address(pool)) + token.balanceOf(attacker);

        assertEq(token.balanceOf(address(pool)), POOL_FUNDING);
        assertEq(token.balanceOf(attacker), ATTACKER_TOKEN_BUDGET);
        assertLe(accounted, token.totalSupply(), "allocations must fit within total supply");
    }

    /// @notice 骨架端到端跑通，并检查每个指标的符号是否合理。
    function testHarnessRunsEndToEnd() public {
        Result memory r = runAttack(50_000e18);
        logResult(r);

        // 报价确实被推高了
        assertEq(r.priceBefore, REFERENCE_PRICE);
        assertGt(r.priceAfter, r.priceBefore, "spot price must be pushed up");
        assertGt(r.deviationBps, 0, "deviation must be positive");

        // 操纵是有成本的（手续费 + 滑点），这是 SimpleDEX 收费的直接后果
        assertGt(r.attackCost, 0, "manipulation must cost something");
        assertLt(r.tokenReturned, r.tokenSpent);

        // 失真的报价确实放大了借款能力
        assertGt(r.extraBorrow, 0, "inflated price must unlock extra borrowing");

        // Spot Oracle 在这套参数下是可盈利攻击的
        assertGt(r.netProfit, 0, "spot oracle should be profitably attackable");

        // 平仓后报价回落，超借的部分成为协议坏账
        assertGt(r.badDebt, 0, "protocol must be left with bad debt");
    }

    /// @notice 【关键】攻击者的 ETH 会计必须闭合。
    ///
    ///         这条同时验证了一个 Foundry 语义：`vm.prank` 之下带 `{value:}` 的调用，
    ///         ETH 是从**被伪装的地址**扣的，不是从测试合约扣的。
    ///         如果这个假设不成立，整套成本核算都会失真而且不报错。
    function testAttackerEthAccountingIsClosed() public {
        assertEq(attacker.balance, 0, "attacker starts with no ETH");

        runAttack(50_000e18);

        // 抵押品确实记在攻击者名下（说明 depositETH 的 msg.sender 是攻击者）
        assertEq(pool.collateralETH(attacker), ATTACKER_COLLATERAL);
        assertEq(address(pool).balance, ATTACKER_COLLATERAL);

        // 操纵换到的 ETH 全部在平仓时花光
        assertEq(attacker.balance, 0, "all gained ETH must be spent unwinding");
        assertEq(heldETH, 0);
    }

    /// @notice 【B 依赖这一点】确认 snapshotState / revertToState 会把
    ///         block.timestamp 和 block.number 一起还原。
    ///
    ///         如果这条断言在未来的 Foundry 版本里失败，那么 sweep() 就不能用于
    ///         任何依赖时间轴的实验（尤其是 TWAP 的窗口扫描），
    ///         必须改成每档一个独立的 test 函数。
    function testSnapshotRestoresTimestamp() public {
        uint256 t0 = block.timestamp;
        uint256 b0 = block.number;

        uint256 snap = vm.snapshotState();

        _advance(3600);
        assertEq(block.timestamp, t0 + 3600, "_advance should move time forward");
        assertGt(block.number, b0, "_advance should move the block number too");

        vm.revertToState(snap);

        assertEq(block.timestamp, t0, "snapshot must restore block.timestamp");
        assertEq(block.number, b0, "snapshot must restore block.number");
    }

    /// @notice 四档规模全扫一遍，同时验证单调性：
    ///         规模越大 → 报价推得越高、手续费付得越多、净利越大。
    ///         单调性能排除「某个指标被常量卡死」这类静默故障。
    /// @dev 看数据：`forge test --match-test testSweepAllSizes -vv`
    function testSweepAllSizes() public {
        Result[4] memory rs = sweep();

        for (uint256 i = 1; i < rs.length; i++) {
            assertGt(rs[i].priceAfter, rs[i - 1].priceAfter, "bigger swap must move price more");
            assertGt(rs[i].attackCost, rs[i - 1].attackCost, "bigger swap must cost more in fees");
            assertGt(rs[i].netProfit, rs[i - 1].netProfit, "bigger distortion must pay more");
        }
    }
}
