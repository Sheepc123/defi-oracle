// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";

/// @title MockSource —— 报价可任意设定的假数据源
///
/// @notice 两个用途：
///
///         1. **LendingPool 单元测试**：需要一个能瞬间改价的 Oracle，
///            才能单独验证「报价变化 → maxBorrow 变化」这条传导，
///            而不必真的去操纵一个 DEX。
///
///         2. **AggregatedOracle 的降级测试（C）**：注入 0 / 陈旧值 /
///            极端离群值，观察聚合器在单个数据源异常时的行为。
///
/// @dev ⚠️ 只放在 test/ 下，不进 src/。
///      理由：它是测试替身，不该出现在可部署合约的集合里，
///      也不该被 CI 的 `forge build --sizes` 统计。
///
///      ⚠️ 【给 C 的提醒】不要用三个 MockSource 来做聚合器的**主实验**。
///      那样只能证明 median() 函数写对了，证明不了任何关于 Oracle 的性质 ——
///      「中位数不受单个离群值影响」是数学恒等式，不是实验发现。
///      主实验请用多个真实的 SimpleDEX 实例，见 README.md「给 C：多个 DEX 实例」一节。


contract MockSource is IPriceOracle {
    /// @notice 当前报价，单位与 IPriceOracle 一致：mUSD/ETH，18 位定点
    uint256 public price;

    string private label;

    /// @param initialPrice 初始报价，18 位定点（2000 mUSD/ETH 传 2000e18）
    /// @param sourceLabel  会出现在结果表里的名字
    constructor(uint256 initialPrice, string memory sourceLabel) {
        price = initialPrice;
        label = sourceLabel;
    }

    /// @notice 任意改价，无权限控制 —— 测试替身不需要
    function setPrice(uint256 newPrice) external {
        price = newPrice;
    }

    function getPrice() external view returns (uint256) {
        return price;
    }

    function description() external view returns (string memory) {
        return label;
    }
}
