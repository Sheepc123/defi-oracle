// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title 极简恒定乘积 AMM（ETH <-> mUSD）
/// @notice 实验用最小实现。相比教学版增加了两样东西：
///         1) 0.3% 手续费 —— 否则「买入再卖回」精确可逆，价格操纵零成本
///         2) 价格累加器 —— TWAPOracle 的唯一数据来源
contract SimpleDEX {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;

    uint256 public ethReserve;
    uint256 public tokenReserve;
    bool public initialized;

    // ── 手续费 ────────────────────────────────────────────────
    /// @dev 30 bps = 0.3%，与 Uniswap V2 一致。手续费留在池内，k 单调增长。
    uint256 public constant FEE_BPS = 30;
    uint256 public constant BPS_DENOM = 10_000;

    // ── 价格累加器（Uniswap V2 风格）─────────────────────────
    /// @dev Σ (spotPrice × 该价格持续的秒数)，18 位精度
    uint256 public priceCumulative;
    uint256 public lastUpdateTime;

    event Swap(address indexed who, bool ethIn, uint256 amountIn, uint256 amountOut);

    constructor(address tokenAddress) {
        token = IERC20(tokenAddress);
    }

    // ─────────────────────────────────────────────────────────
    // 流动性
    // ─────────────────────────────────────────────────────────

    function initializeLiquidity(uint256 tokenAmount) external payable {
        require(!initialized, "Already initialized");
        require(msg.value > 0, "ETH required");
        require(tokenAmount > 0, "Token required");

        token.safeTransferFrom(msg.sender, address(this), tokenAmount);

        ethReserve = msg.value;
        tokenReserve = tokenAmount;
        initialized = true;

        lastUpdateTime = block.timestamp; // 累加器起点
    }

    // ─────────────────────────────────────────────────────────
    // 价格
    // ─────────────────────────────────────────────────────────

    /// @notice 瞬时价格：1 ETH 值多少 mUSD，18 位精度
    function getSpotPrice() public view returns (uint256) {
        require(initialized, "Not initialized");
        return (tokenReserve * 1e18) / ethReserve;
    }

    /// @notice 截至当前区块的价格累计值 —— TWAPOracle 的唯一数据来源
    /// @dev 无需外部 poke DEX：把「上次记账以来的时间 × 当前价格」现场补算进去。
    ///      因此 Oracle 只需存自己的观测点，不必驱动 DEX 记账。
    function currentCumulativePrice() public view returns (uint256 cumulative, uint256 timestamp) {
        timestamp = block.timestamp;
        cumulative = priceCumulative;

        uint256 elapsed = timestamp - lastUpdateTime;
        if (elapsed > 0 && initialized) {
            cumulative += getSpotPrice() * elapsed;
        }
    }

    /// @dev 把「旧价格 × 经过时间」计入累加器。
    ///
    ///      ⚠️ 必须在任何修改储备的操作【之前】调用。
    ///      放到之后会把新价格记进累加器，TWAP 的抗操纵性看起来比实际差，
    ///      而普通单元测试发现不了。守这一点的测试见 SimpleDEX.t.sol:
    ///      testCumulativeAccruesOldPriceNotNew
    function _accrue() internal {
        uint256 elapsed = block.timestamp - lastUpdateTime;
        if (elapsed > 0 && initialized) {
            priceCumulative += getSpotPrice() * elapsed;
        }
        lastUpdateTime = block.timestamp;
    }

    // ─────────────────────────────────────────────────────────
    // Swap
    // ─────────────────────────────────────────────────────────

    /// @notice 卖 mUSD 换 ETH。会推高报价（tokenReserve↑ / ethReserve↓）
    function swapTokenForETH(uint256 tokenIn) external returns (uint256 ethOut) {
        require(initialized, "Not initialized");
        require(tokenIn > 0, "Invalid amount");

        _accrue(); // 先记账，再动储备

        token.safeTransferFrom(msg.sender, address(this), tokenIn);

        uint256 inAfterFee = (tokenIn * (BPS_DENOM - FEE_BPS)) / BPS_DENOM;
        ethOut = (inAfterFee * ethReserve) / (tokenReserve + inAfterFee);

        require(ethOut > 0, "Zero output");
        require(ethOut < ethReserve, "Insufficient liquidity");

        tokenReserve += tokenIn; // 全额入池，手续费留在池内
        ethReserve -= ethOut;

        (bool ok,) = payable(msg.sender).call{value: ethOut}("");
        require(ok, "ETH transfer failed");

        emit Swap(msg.sender, false, tokenIn, ethOut);
    }

    /// @notice 买 mUSD 卖 ETH。会压低报价
    function swapETHForToken() external payable returns (uint256 tokenOut) {
        require(initialized, "Not initialized");
        require(msg.value > 0, "ETH required");

        _accrue();

        // msg.value 已经进入 address(this).balance，但 ethReserve 尚未更新，
        // 因此这里用的仍是交易前的储备，公式正确。
        uint256 inAfterFee = (msg.value * (BPS_DENOM - FEE_BPS)) / BPS_DENOM;
        tokenOut = (inAfterFee * tokenReserve) / (ethReserve + inAfterFee);

        require(tokenOut > 0, "Zero output");
        require(tokenOut < tokenReserve, "Insufficient liquidity");

        ethReserve += msg.value;
        tokenReserve -= tokenOut;

        token.safeTransfer(msg.sender, tokenOut);

        emit Swap(msg.sender, true, msg.value, tokenOut);
    }
}
