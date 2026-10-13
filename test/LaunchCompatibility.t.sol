// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {SorenVault} from "../src/SorenVault.sol";

/// @dev Local floor-equivalent checks without verifier-owned environment variables.
contract LaunchCompatibilityTest is Test {
    function test_factoryDeploymentPreservesEntireSupplyAndExplicitOwner() public {
        address owner = makeAddr("launch owner without code");
        address factory = makeAddr("factory");
        vm.startPrank(factory);
        LaunchToken token = new LaunchToken();
        SorenVault vault = new SorenVault(owner);
        vm.stopPrank();
        assertEq(owner.code.length, 0);
        assertEq(vault.owner(), owner);
        assertEq(address(vault.token()), address(0));
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(factory), token.totalSupply());
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(token.balanceOf(owner), 0);
    }

    function test_vaultConstructorRunsWithoutAnyTokenDependency() public {
        address owner = makeAddr("owner");
        SorenVault vault = new SorenVault(owner);
        assertEq(vault.owner(), owner);
        assertEq(address(vault.token()), address(0));
        assertEq(vault.lastPublishedChapter(), 0);
        assertEq(vault.chaptersSolved(), 0);
    }

    function test_runtimeSizesAndForbiddenOpcodesMatchProtectedFloor() public {
        LaunchToken token = new LaunchToken();
        SorenVault vault = new SorenVault(makeAddr("owner"));
        _checkRuntime(address(token));
        _checkRuntime(address(vault));
    }

    function _checkRuntime(address deployed) private view {
        bytes memory runtime = deployed.code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 opcode = uint8(runtime[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                i += opcode - 0x5f;
                continue;
            }
            assertTrue(opcode != 0xf4 && opcode != 0xf2 && opcode != 0xff, "forbidden opcode");
        }
    }
}
