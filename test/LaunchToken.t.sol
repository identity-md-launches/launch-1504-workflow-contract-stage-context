// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken internal token;
    address internal alice;
    address internal bob;
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        token = new LaunchToken();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
    }

    function test_metadataAndWholeSupplyMintedToDeployer() public view {
        assertEq(token.name(), "Sorn");
        assertEq(token.symbol(), "SORN");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(address(token)), 0);
    }

    function testFuzz_transferMovesExactAmount(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFromSpendsAllowanceAndPreservesSupply() public {
        token.approve(alice, 123 ether);
        vm.prank(alice);
        assertTrue(token.transferFrom(address(this), bob, 23 ether));
        assertEq(token.allowance(address(this), alice), 100 ether);
        assertEq(token.balanceOf(bob), 23 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 23 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferWithoutBalanceReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transfer(bob, 1);
    }

    function test_transferWithoutAllowanceReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transferFrom(address(this), bob, 1);
    }

    function test_transferToZeroReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    function test_burnAddressTransferDoesNotChangeTotalSupply() public {
        address burn = 0x000000000000000000000000000000000000dEaD;
        token.transfer(burn, 100 ether);
        assertEq(token.balanceOf(burn), 100 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_noAdministrativeMintOrControlEntryPoints() public {
        string[13] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "pause()",
            "unpause()",
            "setMinter(address)",
            "blacklist(address)",
            "setFee(uint256)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], alice, uint256(1));
            (bool ownerSuccess,) = address(token).call(data);
            assertFalse(ownerSuccess);
            vm.prank(alice);
            (bool attackerSuccess,) = address(token).call(data);
            assertFalse(attackerSuccess);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }
}
