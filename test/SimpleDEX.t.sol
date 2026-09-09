// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MiniUSD} from "../src/MiniUSD.sol";
import {SimpleDEX} from "../src/SimpleDEX.sol";
import {Test, console2} from "forge-std/Test.sol";

contract SimpleDEXTest is Test {
    MiniUSD token;
    SimpleDEX dex;

    address alice;
    // Alice 用于购买 ETH 的 mUSD 数量
    uint256 constant ALICE_TOKEN_AMOUNT = 20_000e18;

    function setUp() public {
        token = new MiniUSD();

        dex = new SimpleDEX(address(token));

        vm.deal(address(this), 200 ether);

        token.approve(address(dex), 200_000e18);

        dex.initializeLiquidity{value: 100 ether}(200_000e18);

        alice = makeAddr("alice");

        bool success = token.transfer(alice, ALICE_TOKEN_AMOUNT);

        assertTrue(success);
    }

    function testInitialSpotPrice() public view {
        uint256 price = dex.getSpotPrice();

        assertEq(price, 2000e18);
    }

    // ─────────────────────────────────────────────────────────
    // 辅助
    // ─────────────────────────────────────────────────────────

    /// @dev alice 把手上全部 mUSD 砸进池子换 ETH，返回换到的 ETH
    function _aliceDumpsToken() internal returns (uint256 ethOut) {
        vm.startPrank(alice);
        token.approve(address(dex), ALICE_TOKEN_AMOUNT);
        ethOut = dex.swapTokenForETH(ALICE_TOKEN_AMOUNT);
        vm.stopPrank();
    }

    /// @dev 同时推进时间和区块号。只 warp 不 roll 会造出「同一区块但时间变了」的怪状态。
    function _advance(uint256 secs) internal {
        vm.warp(block.timestamp + secs);
        vm.roll(block.number + secs / 12 + 1);
    }

    // ─────────────────────────────────────────────────────────
    // 手续费：决定「操纵成本」这个指标是否存在
    // ─────────────────────────────────────────────────────────

    /// @notice 买入再立刻卖回必须亏钱。
    ///         零手续费的恒定乘积池是精确可逆的，往返只损失几 wei，
    ///         那样价格操纵就是免费的，整个实验的「操纵成本」一列会全是 0。

    function testFeeIsCharged() public {
        uint256 ethOut = _aliceDumpsToken();

        vm.prank(alice);
        uint256 tokenBack = dex.swapETHForToken{value: ethOut}();

        assertLt(tokenBack, ALICE_TOKEN_AMOUNT, "round trip must lose money");

        uint256 loss = ALICE_TOKEN_AMOUNT - tokenBack;

        console2.log("round trip loss (mUSD):", loss / 1e18);
        console2.log("loss in bps:", (loss * 10_000) / ALICE_TOKEN_AMOUNT);

        // 两次 0.3% 手续费，扣掉滑点部分抵消后约 0.5%。给一个宽区间避免脆弱断言。
        assertGt(loss, (ALICE_TOKEN_AMOUNT * 40) / 10_000, "loss should exceed 0.4%");
        assertLt(loss, (ALICE_TOKEN_AMOUNT * 80) / 10_000, "loss should stay under 0.8%");
    }

    /// @notice 手续费留在池内，所以 k = ethReserve * tokenReserve 必须单调增长。
    ///         如果 k 不变，说明手续费被算进了入池数量，等于没收。
    function testKGrowsAfterSwap() public {
        uint256 kBefore = dex.ethReserve() * dex.tokenReserve();

        _aliceDumpsToken();

        uint256 kAfter = dex.ethReserve() * dex.tokenReserve();

        assertGt(kAfter, kBefore, "fee must stay in the pool");
    }

    // ─────────────────────────────────────────────────────────
    // 价格累加器：TWAP 的全部机制基础
    // ─────────────────────────────────────────────────────────

    /// @notice 【最关键的一个测试】
    ///         _accrue() 必须在储备变更【之前】调用，落盘的累加器只能包含旧价格。
    ///         若把 _accrue() 误放到 swap 之后，这里会记进被推高的新价格，
    ///         TWAP 的抗操纵性会失真 —— 而其它任何测试都发现不了这个 bug。
    function testCumulativeAccruesOldPriceNotNew() public {
        assertEq(dex.priceCumulative(), 0, "cumulative starts at zero");

        uint256 priceBefore = dex.getSpotPrice(); // 2000e18

        _advance(3600);

        // 期间没有任何交易：落盘值仍是 0，但 view 要现场补算出来
        assertEq(dex.priceCumulative(), 0, "storage untouched without a trade");

        (uint256 cumView,) = dex.currentCumulativePrice();
        assertEq(cumView, priceBefore * 3600, "view must extrapolate to now");

        // 现在砸一笔大额 swap 把价格推高
        _aliceDumpsToken();

        assertGt(dex.getSpotPrice(), priceBefore, "price should be manipulated up");

        // 核心断言：落盘的累加器只能是「旧价格 × 3600」，不得掺入新价格
        assertEq(dex.priceCumulative(), priceBefore * 3600, "must accrue OLD price only");
        assertEq(dex.lastUpdateTime(), block.timestamp, "checkpoint moved to now");
    }

    /// @notice 同一区块内的操纵不改变累计值 —— TWAP 抗单块操纵的机制来源。
    ///         B 的整个实验都压在这条性质上。
    function testCumulativeIgnoresIntraBlockSwap() public {
        _advance(3600);

        (uint256 cumBefore,) = dex.currentCumulativePrice();

        _aliceDumpsToken(); // 不推进时间，同一区块内完成

        (uint256 cumAfter,) = dex.currentCumulativePrice();

        assertEq(cumAfter, cumBefore, "single-block manipulation must not move TWAP input");
    }

    /// @notice 反面：一旦攻击者【维持】被推高的价格，时间一过累加器就开始记录它。
    ///         这就是操纵 TWAP 的真实代价所在 —— 必须跨区块持有头寸。
    function testCumulativeAccruesManipulatedPriceOverTime() public {
        _advance(3600);

        (uint256 cumBefore,) = dex.currentCumulativePrice();

        _aliceDumpsToken();

        uint256 manipulatedPrice = dex.getSpotPrice();

        _advance(600); // 攻击者维持 10 分钟

        (uint256 cumAfter,) = dex.currentCumulativePrice();

        assertEq(cumAfter, cumBefore + manipulatedPrice * 600, "held manipulation must enter the accumulator");

        console2.log("manipulated price (/ETH):", manipulatedPrice / 1e18);
    }
}
