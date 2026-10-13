// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SorenVault} from "../src/SorenVault.sol";
import {AdversarialToken} from "./mocks/AdversarialToken.sol";

contract SorenVaultAdversarialTest is Test {
    AdversarialToken internal token;
    SorenVault internal vault;
    address internal alice;
    uint256 internal constant PRIZE = 1_000 ether;
    uint256 internal constant COST = 100 ether;
    uint256 internal constant FUNDED = 10 * PRIZE;
    string internal constant ANSWER = "soren";
    bytes32 internal constant SECRET = keccak256("test secret");
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    function setUp() public {
        alice = makeAddr("alice");
        vm.roll(50);
        vm.warp(1_700_000_000);
        token = new AdversarialToken();
        vault = new SorenVault(address(this));
        vault.setToken(address(token));
        token.transfer(alice, 10_000 ether);
        token.approve(address(vault), 100_000 ether);
        vm.prank(alice);
        token.approve(address(vault), 10_000 ether);
        vault.fund(FUNDED);
        vault.publishChapter(1, keccak256(bytes(ANSWER)), PRIZE, "test transmission");
    }

    function test_falseReturnFundingRevertsWithoutLosingTokens() public {
        uint256 ownerBefore = token.balanceOf(address(this));
        token.configureModes(AdversarialToken.Mode.Normal, AdversarialToken.Mode.ReturnFalse);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        vault.fund(PRIZE);
        assertEq(token.balanceOf(address(this)), ownerBefore);
        assertEq(vault.prizeBalance(), FUNDED);
    }

    function test_falseReturnCommitRevertsAllCountersAndCommitment() public {
        token.configureModes(AdversarialToken.Mode.Normal, AdversarialToken.Mode.ReturnFalse);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        _commit();
        _assertNoBurn();
    }

    function test_revertingBurnRevertsAllCountersAndCommitment() public {
        token.configureModes(AdversarialToken.Mode.Normal, AdversarialToken.Mode.RevertTransfer);
        vm.expectRevert(AdversarialToken.MockTransferReverted.selector);
        _commit();
        _assertNoBurn();
    }

    function test_falseReturnPayoutRollsBackWinAndAllowsRetry() public {
        _commit();
        vm.roll(vm.getBlockNumber() + 1);
        token.configureModes(AdversarialToken.Mode.ReturnFalse, AdversarialToken.Mode.Normal);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        _reveal();
        _assertUnsettled();
        token.configureModes(AdversarialToken.Mode.Normal, AdversarialToken.Mode.Normal);
        _reveal();
        assertEq(vault.getChapter(1).solver, alice);
        assertEq(token.balanceOf(alice), 10_000 ether - COST + PRIZE);
        assertEq(vault.totalBurned(), COST);
    }

    function test_revertingPayoutDoesNotConsumeCommitment() public {
        _commit();
        vm.roll(vm.getBlockNumber() + 1);
        token.configureModes(AdversarialToken.Mode.RevertTransfer, AdversarialToken.Mode.Normal);
        vm.expectRevert(AdversarialToken.MockTransferReverted.selector);
        _reveal();
        _assertUnsettled();
    }

    function test_safeErc20SupportsNoReturnTransfers() public {
        token.configureModes(AdversarialToken.Mode.NoReturn, AdversarialToken.Mode.NoReturn);
        vault.fund(PRIZE);
        _commit();
        vm.roll(vm.getBlockNumber() + 1);
        _reveal();
        assertEq(vault.prizeBalance(), FUNDED);
        assertEq(vault.getChapter(1).solver, alice);
        assertEq(token.balanceOf(DEAD), COST);
    }

    function test_feeAndNoMovementFundingRejectedAtomically() public {
        AdversarialToken.Mode[3] memory modes =
            [AdversarialToken.Mode.RecipientFee, AdversarialToken.Mode.SenderFee, AdversarialToken.Mode.NoMovement];
        uint256 ownerBefore = token.balanceOf(address(this));
        uint256 supplyBefore = token.totalSupply();
        for (uint256 i; i < modes.length; ++i) {
            token.configureModes(AdversarialToken.Mode.Normal, modes[i]);
            vm.expectRevert(SorenVault.UnexpectedTokenAmount.selector);
            vault.fund(PRIZE);
            assertEq(token.balanceOf(address(this)), ownerBefore);
            assertEq(vault.prizeBalance(), FUNDED);
            assertEq(token.totalSupply(), supplyBefore);
        }
    }

    function test_feeAndNoMovementBurnRejectedAtomically() public {
        AdversarialToken.Mode[3] memory modes =
            [AdversarialToken.Mode.RecipientFee, AdversarialToken.Mode.SenderFee, AdversarialToken.Mode.NoMovement];
        for (uint256 i; i < modes.length; ++i) {
            token.configureModes(AdversarialToken.Mode.Normal, modes[i]);
            vm.expectRevert(SorenVault.UnexpectedTokenAmount.selector);
            _commit();
            _assertNoBurn();
        }
    }

    function test_feeAndNoMovementPayoutRejectedAtomically() public {
        _commit();
        vm.roll(vm.getBlockNumber() + 1);
        AdversarialToken.Mode[3] memory modes =
            [AdversarialToken.Mode.RecipientFee, AdversarialToken.Mode.SenderFee, AdversarialToken.Mode.NoMovement];
        for (uint256 i; i < modes.length; ++i) {
            token.configureModes(modes[i], AdversarialToken.Mode.Normal);
            vm.expectRevert(SorenVault.UnexpectedTokenAmount.selector);
            _reveal();
            _assertUnsettled();
        }
    }

    function test_burnCallbackCannotReenterAnyMutation() public {
        bytes[] memory attempts = _reentryAttempts();
        for (uint256 i; i < attempts.length; ++i) {
            token.configureCallback(address(vault), attempts[i], false, true, false);
            _commit();
            assertFalse(token.callbackSucceeded());
            assertEq(
                token.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
            );
        }
        assertEq(vault.totalBurned(), attempts.length * COST);
        assertEq(vault.getChapter(1).commits, attempts.length);
        assertEq(vault.prizeBalance(), FUNDED);
        assertEq(vault.chaptersSolved(), 0);
    }

    function test_fundingCallbackCannotReenter() public {
        token.configureCallback(address(vault), abi.encodeCall(vault.fund, (PRIZE)), false, true, false);
        vault.fund(PRIZE);
        assertFalse(token.callbackSucceeded());
        assertEq(token.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(vault.prizeBalance(), FUNDED + PRIZE);
    }

    function test_payoutCallbackCannotDoubleSettle() public {
        _commit();
        vm.roll(vm.getBlockNumber() + 1);
        token.configureCallback(address(vault), abi.encodeCall(vault.reveal, (1, ANSWER, SECRET)), true, false, false);
        _reveal();
        assertFalse(token.callbackSucceeded());
        assertEq(token.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(vault.chaptersSolved(), 1);
        assertEq(vault.totalPrizesPaid(), PRIZE);
        assertEq(vault.prizeBalance(), FUNDED - PRIZE);
        assertEq(token.balanceOf(alice), 10_000 ether - COST + PRIZE);
    }

    function test_bubbledCallbackFailureRollsBackSettlement() public {
        _commit();
        vm.roll(vm.getBlockNumber() + 1);
        token.configureCallback(address(vault), abi.encodeCall(vault.reveal, (1, ANSWER, SECRET)), true, false, true);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        _reveal();
        _assertUnsettled();
    }

    function _commit() private {
        vm.prank(alice);
        vault.commit(1, keccak256(abi.encode(ANSWER, alice, SECRET)));
    }

    function _reveal() private {
        vm.prank(alice);
        vault.reveal(1, ANSWER, SECRET);
    }

    function _assertNoBurn() private view {
        (bytes32 hash,,) = vault.commitments(1, alice);
        assertEq(hash, bytes32(0));
        assertEq(token.balanceOf(alice), 10_000 ether);
        assertEq(token.balanceOf(DEAD), 0);
        assertEq(vault.totalBurned(), 0);
        assertEq(vault.getChapter(1).commits, 0);
        assertEq(vault.getChapter(1).burned, 0);
        (uint256 guesses, uint256 burned, uint256 solved) = vault.playerStats(alice);
        assertEq(guesses, 0);
        assertEq(burned, 0);
        assertEq(solved, 0);
    }

    function _assertUnsettled() private view {
        SorenVault.Chapter memory chapter = vault.getChapter(1);
        assertEq(uint256(chapter.status), uint256(SorenVault.Status.Open));
        assertEq(chapter.solver, address(0));
        assertEq(chapter.solvedAt, 0);
        assertEq(vault.reservedPrizes(), PRIZE);
        assertEq(vault.totalPrizesPaid(), 0);
        assertEq(vault.chaptersSolved(), 0);
        assertEq(vault.prizeBalance(), FUNDED);
        (bytes32 hash,,) = vault.commitments(1, alice);
        assertEq(hash, keccak256(abi.encode(ANSWER, alice, SECRET)));
        (uint256 guesses, uint256 burned, uint256 solved) = vault.playerStats(alice);
        assertEq(guesses, 1);
        assertEq(burned, COST);
        assertEq(solved, 0);
        assertEq(token.balanceOf(alice), 10_000 ether - COST);
        assertEq(token.balanceOf(DEAD), COST);
    }

    function _reentryAttempts() private view returns (bytes[] memory calls) {
        calls = new bytes[](6);
        calls[0] = abi.encodeCall(vault.setToken, (address(token)));
        calls[1] = abi.encodeCall(vault.fund, (1));
        calls[2] = abi.encodeCall(vault.publishChapter, (2, SECRET, PRIZE, "reentry"));
        calls[3] = abi.encodeCall(vault.setHint, (1, "reentry"));
        calls[4] = abi.encodeCall(vault.commit, (1, SECRET));
        calls[5] = abi.encodeCall(vault.reveal, (1, ANSWER, SECRET));
    }
}
