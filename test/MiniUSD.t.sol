// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MiniUSD} from "../src/MiniUSD.sol";

/// @notice MiniUSD 本身只是 OpenZeppelin ERC20 加一次 mint，
///         transfer / approve 之类的行为由 OZ 自己的测试覆盖，这里不重复。
///         唯一值得钉住的是**总供应量**：它是全项目的预算上限
///         （DEX 流动性 + 借贷池资金 + 攻击者预算都从这 100 万里出）。

contract MiniUSDTest is Test {
    MiniUSD token;

    function setUp() public {
        token = new MiniUSD();
    }

    function testInitialSupply() public view {
        assertEq(token.totalSupply(), 1_000_000e18);
        assertEq(token.balanceOf(address(this)), 1_000_000e18);
    }
}