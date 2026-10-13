// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {SorenVault} from "../../src/SorenVault.sol";

abstract contract SorenTestBase is Test {
    LaunchToken internal token;
    SorenVault internal vault;
    address internal owner;
    address internal alice;
    address internal bob;
    address internal carol;
    uint256 internal constant PRIZE = 1_000 ether;
    uint256 internal constant COST = 100 ether;
    uint256 internal constant OWNER_FUNDS = 1_000_000 ether;
    uint256 internal constant PLAYER_FUNDS = 10_000 ether;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    string internal constant ANSWER = "soren";
    bytes32 internal constant SECRET = keccak256("a test-only secret");

    function setUp() public virtual {
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        vm.roll(100);
        vm.warp(1_700_000_000);
        token = new LaunchToken();
        vault = new SorenVault(owner);
        token.transfer(owner, OWNER_FUNDS);
        token.transfer(alice, PLAYER_FUNDS);
        token.transfer(bob, PLAYER_FUNDS);
        token.transfer(carol, PLAYER_FUNDS);
        vm.startPrank(owner);
        vault.setToken(address(token));
        token.approve(address(vault), OWNER_FUNDS);
        vm.stopPrank();
        _approve(alice, PLAYER_FUNDS);
        _approve(bob, PLAYER_FUNDS);
        _approve(carol, PLAYER_FUNDS);
    }

    function _approve(address player, uint256 amount) internal {
        vm.prank(player);
        token.approve(address(vault), amount);
    }

    function _fund(uint256 amount) internal {
        vm.prank(owner);
        vault.fund(amount);
    }

    function _publish(uint256 id, string memory answer, uint256 prize) internal {
        vm.prank(owner);
        vault.publishChapter(id, keccak256(bytes(answer)), prize, string.concat("Transmission ", vm.toString(id)));
    }

    function _hash(string memory answer, address player, bytes32 secret) internal pure returns (bytes32) {
        return keccak256(abi.encode(answer, player, secret));
    }

    function _commit(uint256 id, address player, string memory answer, bytes32 secret) internal {
        vm.prank(player);
        vault.commit(id, _hash(answer, player, secret));
    }

    function _nextBlock() internal {
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 12);
    }

    function _reveal(uint256 id, address player, string memory answer, bytes32 secret) internal {
        vm.prank(player);
        vault.reveal(id, answer, secret);
    }

    function _solve(uint256 id, address player, string memory answer) internal {
        _commit(id, player, answer, SECRET);
        _nextBlock();
        _reveal(id, player, answer, SECRET);
    }

    function _assertStats(address player, uint256 guesses, uint256 burned, uint256 solved) internal view {
        (uint256 actualGuesses, uint256 actualBurned, uint256 actualSolved) = vault.playerStats(player);
        assertEq(actualGuesses, guesses);
        assertEq(actualBurned, burned);
        assertEq(actualSolved, solved);
    }

    function _assertConservation() internal view {
        uint256 sum = token.balanceOf(address(this)) + token.balanceOf(owner) + token.balanceOf(alice)
            + token.balanceOf(bob) + token.balanceOf(carol) + token.balanceOf(address(vault)) + token.balanceOf(DEAD);
        assertEq(sum, token.totalSupply());
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertGe(token.balanceOf(address(vault)), vault.reservedPrizes());
    }
}
