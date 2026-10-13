// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice The fixed-supply Sorn (SORN) launch token. The factory distributes the supply.
contract LaunchToken is ERC20 {
    constructor() ERC20("Sorn", "SORN") {
        _mint(msg.sender, 1_000_000_000 * 10 ** 18);
    }
}
