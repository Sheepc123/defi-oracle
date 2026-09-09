// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";

import {MiniUSD} from "../src/MiniUSD.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {MockSource} from "./mocks/MockSource.sol";

/// @title LendingPool 单元测试
///
/// @notice 这里**不做**价格操纵实验 —— 那是 A/B/C 在各自的 Oracle 场景里做的事。
///         本文件只验证一件事：**报价怎么变，可借额度就怎么跟着变**。
///
///         所以刻意用 MockSource 而不是真的 SimpleDEX：
///         把「报价变化」和「报价怎么被操纵出来」两件事解耦，
///         这样 LendingPool 出问题时能立刻定位，不会和 AMM 的数学纠缠在一起。


contract LendingPoolTest is Test {
    MiniUSD internal token;
    MockSource internal oracle;
    LendingPool internal pool;

    address internal alice;

    /// @dev 基线报价：1 ETH = 2000 mUSD。与全项目其它场景保持一致。
    uint256 internal constant BASELINE_PRICE = 2000e18;

    /// @dev 池子可借出的 mUSD
    uint256 internal constant POOL_FUNDING = 200_000e18;

    /// @dev alice 的抵押品
    uint256 internal constant COLLATERAL = 10 ether;

    /// @dev 10 ETH × 2000 mUSD/ETH ÷ 1.5 = 13,333.33... mUSD
    ///      写成表达式而不是字面量，改抵押率时不用手算

    uint256 internal constant EXPECTED_MAX_BORROW = (COLLATERAL * BASELINE_PRICE / 1e18) * 10_000 / 15_000;

    function setUp() public {
        token = new MiniUSD();
        oracle = new MockSource(BASELINE_PRICE, "mock");
        pool = new LendingPool(address(token), address(oracle));

        token.approve(address(pool), POOL_FUNDING);
        pool.fund(POOL_FUNDING);

        alice = makeAddr("alice");
        vm.deal(alice, 100 ether);
    }

    /// @dev alice 抵押 COLLATERAL 数量的 ETH
    function _aliceDeposits() internal {
        vm.prank(alice);
        pool.depositETH{value: COLLATERAL}();
    }

    // ─────────────────────────────────────────────────────────
    // 基础状态
    // ─────────────────────────────────────────────────────────

    function testInitialState() public view {
        assertEq(token.balanceOf(address(pool)), POOL_FUNDING, "pool should hold lendable mUSD");
        assertEq(pool.collateralETH(alice), 0);
        assertEq(pool.debt(alice), 0);
        assertEq(pool.maxBorrow(alice), 0, "no collateral means no borrowing power");
        assertEq(pool.badDebt(alice), 0);
    }

    function testDepositETH() public {
        _aliceDeposits();

        assertEq(pool.collateralETH(alice), COLLATERAL);
        assertEq(address(pool).balance, COLLATERAL);
    }

    function testDepositRevertsOnZero() public {
        vm.prank(alice);
        vm.expectRevert("No ETH");
        pool.depositETH{value: 0}();
    }

    // ─────────────────────────────────────────────────────────
    // 单位换算 —— 全项目最容易出错的地方
    // ─────────────────────────────────────────────────────────

    /// @notice 【守卫测试】1 ETH 在 2000e18 报价下，价值必须**恰好**是 2000e18 mUSD。
    ///
    ///         这条断言同时排除三种典型错误：
    ///           - 漏掉 / 1e18        → 得到 2000e36，大 1e18 倍
    ///           - 乘除方向搞反       → 得到 5e14（即 1/2000），语义变成 ETH per mUSD
    ///           - 把 price 当成整数  → 得到 2000
    function testCollateralValueUnitDirection() public {
        vm.prank(alice);
        pool.depositETH{value: 1 ether}();

        assertEq(pool.collateralValue(alice), 2000e18, "1 ETH @ 2000 must be exactly 2000e18 mUSD");
    }

    // ─────────────────────────────────────────────────────────
    // 借款能力随报价变化 —— 这就是实验的传导路径
    // ─────────────────────────────────────────────────────────

    function testMaxBorrowAtBaseline() public {
        _aliceDeposits();

        assertEq(pool.collateralValue(alice), 20_000e18, "10 ETH @ 2000 = 20,000 mUSD");
        assertEq(pool.maxBorrow(alice), EXPECTED_MAX_BORROW);
        assertEq(pool.availableToBorrow(alice), EXPECTED_MAX_BORROW, "nothing borrowed yet");

        console2.log("maxBorrow at baseline (mUSD):", pool.maxBorrow(alice) / 1e18);
    }

    /// @notice 【核心传导】报价翻倍，可借额度必须严格翻倍；报价减半则减半。
    ///         这是「Oracle 报价失真 → 协议风险」这条链路的全部数学内容。
    function testMaxBorrowScalesWithOracle() public {
        _aliceDeposits();

        uint256 atBaseline = pool.maxBorrow(alice);

        oracle.setPrice(BASELINE_PRICE * 2);
        assertEq(pool.maxBorrow(alice), atBaseline * 2, "doubling price must double capacity");

        oracle.setPrice(BASELINE_PRICE / 2);
        assertEq(pool.maxBorrow(alice), atBaseline / 2, "halving price must halve capacity");

        oracle.setPrice(BASELINE_PRICE);
        assertEq(pool.maxBorrow(alice), atBaseline, "restoring price must restore capacity");
    }

    // ─────────────────────────────────────────────────────────
    // 借款
    // ─────────────────────────────────────────────────────────

    function testBorrowTransfersAndRecordsDebt() public {
        _aliceDeposits();

        uint256 amount = 10_000e18;

        vm.prank(alice);
        pool.borrow(amount);

        assertEq(token.balanceOf(alice), amount, "borrower receives mUSD");
        assertEq(pool.debt(alice), amount);
        assertEq(token.balanceOf(address(pool)), POOL_FUNDING - amount);
    }

    function testBorrowUpToCapExactlySucceeds() public {
        _aliceDeposits();

        // ⚠️【Foundry 陷阱，A/B/C 都会撞到】
        //    vm.prank 只作用于**下一次外部调用**，而函数参数里的外部调用
        //    会先被求值，从而把 prank 消耗掉：
        //
        //        vm.prank(alice);
        //        pool.borrow(pool.maxBorrow(alice));   // ❌ prank 被 maxBorrow 吃掉，
        //                                             //    borrow 变成 address(this) 发起
        //
        //    结果是 "Undercollateralized"，而且报错完全指不到真正的原因。
        //    正确做法：把读取先落到局部变量。
        uint256 cap = pool.maxBorrow(alice);

        // 借到上限本身必须成功（require 用的是 <=，不是 <）
        vm.prank(alice);
        pool.borrow(cap);

        assertEq(pool.availableToBorrow(alice), 0);
        assertEq(pool.badDebt(alice), 0, "at the cap is not bad debt");
    }

    function testBorrowRevertsAboveCap() public {
        _aliceDeposits();

        // 同一个陷阱的另一种表现：若把 maxBorrow 写在参数里，
        // vm.expectRevert 会去检查 maxBorrow 这次调用，而它不会 revert，
        // 于是报 "next call did not revert as expected"。
        uint256 cap = pool.maxBorrow(alice);

        vm.prank(alice);
        vm.expectRevert("Undercollateralized");
        pool.borrow(cap + 1);
    }

    function testBorrowRevertsWithoutCollateral() public {
        vm.prank(alice);
        vm.expectRevert("Undercollateralized");
        pool.borrow(1e18);
    }

    function testBorrowRevertsOnZero() public {
        _aliceDeposits();

        vm.prank(alice);
        vm.expectRevert("Zero amount");
        pool.borrow(0);
    }

    function testAvailableToBorrowShrinksAsDebtGrows() public {
        _aliceDeposits();

        uint256 cap = pool.maxBorrow(alice);

        vm.prank(alice);
        pool.borrow(cap / 4);

        assertEq(pool.availableToBorrow(alice), cap - cap / 4);
    }

    // ─────────────────────────────────────────────────────────
    // 坏账 —— 攻击给协议造成的净损失
    // ─────────────────────────────────────────────────────────

    /// @notice 借满之后报价回落，超出的部分就是协议的坏账。
    ///         这正是攻击者平仓之后留下的东西。
    function testBadDebtAppearsWhenPriceFalls() public {
        _aliceDeposits();

        uint256 cap = pool.maxBorrow(alice); // 先读出来，避免 prank 被参数求值吃掉

        vm.prank(alice);
        pool.borrow(cap);

        uint256 debtAmount = pool.debt(alice);
        assertEq(pool.badDebt(alice), 0, "no bad debt while price holds");

        // 报价腰斩
        oracle.setPrice(BASELINE_PRICE / 2);

        uint256 capAfter = pool.maxBorrow(alice);

        assertEq(pool.badDebt(alice), debtAmount - capAfter);
        assertEq(pool.availableToBorrow(alice), 0, "no headroom left");

        console2.log("bad debt after 50% price drop (mUSD):", pool.badDebt(alice) / 1e18);
    }

    /// @notice 报价上涨不产生坏账（只测 badDebt 不会下溢成天文数字）
    function testNoBadDebtWhenPriceRises() public {
        _aliceDeposits();

        uint256 cap = pool.maxBorrow(alice); // 先读出来，避免 prank 被参数求值吃掉

        vm.prank(alice);
        pool.borrow(cap);

        oracle.setPrice(BASELINE_PRICE * 2);

        assertEq(pool.badDebt(alice), 0);
        assertGt(pool.availableToBorrow(alice), 0, "rising price frees up headroom");
    }
}
