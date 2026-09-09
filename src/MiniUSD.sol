// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MiniUSD is ERC20 {

    constructor() ERC20("Mini USD", "mUSD") {
        _mint(msg.sender, 1_000_000e18);
    }
}