// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title 统一价格预言机接口
/// @notice Spot / TWAP / Aggregated 三种实现都通过这个接口接入 LendingPool，
///         保证实验条件一致。LendingPool 不知道自己接的是哪一种。
/// @dev 【单位约定 —— 任何实现都必须遵守，不得擅改】
///
///      getPrice() 返回 1 ETH 的价格，以 mUSD 计价，18 位定点。
///      例：1 ETH = 2000 mUSD  ->  返回 2000e18
///
///      注意方向：这是「每 1 ETH 值多少 mUSD」，不是反过来。
///      推导来源：SimpleDEX 中 price = tokenReserve * 1e18 / ethReserve
///
///      消费方统一写法： value = ethAmount * oracle.getPrice() / 1e18
interface IPriceOracle {
    /// @return price 1 ETH 的 mUSD 价格，18 位精度
    function getPrice() external view returns (uint256 price);

    /// @return 该 Oracle 的可读名称，用于 benchmark 表格
    function description() external view returns (string memory);
}
