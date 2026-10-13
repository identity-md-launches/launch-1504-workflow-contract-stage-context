// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SorenTestBase} from "./helpers/SorenTestBase.sol";
import {SorenVault} from "../src/SorenVault.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract SorenVaultGameTest is SorenTestBase {
    function setUp() public override {
        super.setUp();
        _fund(10 * PRIZE);
        _publish(1, ANSWER, PRIZE);
    }

    function test_commitBurnsExactly100FromPlayerAndRecordsEverything() public {
        bytes32 hash = _hash(ANSWER, alice, SECRET);
        uint256 prizeBalanceBefore = vault.prizeBalance();
        vm.expectEmit(true, true, false, true, address(vault));
        emit SorenVault.Committed(1, alice, hash, vm.getBlockNumber(), vm.getBlockTimestamp(), COST);
        _commit(1, alice, ANSWER, SECRET);

        assertEq(token.balanceOf(alice), PLAYER_FUNDS - COST);
        assertEq(token.balanceOf(DEAD), COST);
        assertEq(vault.prizeBalance(), prizeBalanceBefore);
        assertEq(vault.totalBurned(), COST);
        assertEq(vault.getChapter(1).commits, 1);
        assertEq(vault.getChapter(1).burned, COST);
        _assertStats(alice, 1, COST, 0);
        (bytes32 storedHash, uint256 storedBlock, uint256 storedTimestamp) = vault.commitments(1, alice);
        assertEq(storedHash, hash);
        assertEq(storedBlock, vm.getBlockNumber());
        assertEq(storedTimestamp, vm.getBlockTimestamp());
        _assertConservation();
    }

    function test_commitRequiresAllowanceAndRollsBackCountersOnFailure() public {
        _approve(alice, COST - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(vault), COST - 1, COST)
        );
        _commit(1, alice, ANSWER, SECRET);
        _assertNoCommit(alice);
        assertEq(vault.getChapter(1).commits, 0);
        assertEq(vault.getChapter(1).burned, 0);
        assertEq(vault.totalBurned(), 0);
        _assertStats(alice, 0, 0, 0);
        assertEq(token.balanceOf(DEAD), 0);
    }

    function test_commitRequiresPlayerBalance() public {
        vm.prank(alice);
        token.transfer(bob, PLAYER_FUNDS - COST + 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, COST - 1, COST));
        _commit(1, alice, ANSWER, SECRET);
        _assertNoCommit(alice);
        assertEq(vault.totalBurned(), 0);
        assertEq(token.balanceOf(DEAD), 0);
        _assertConservation();
    }

    function test_zeroCommitHashRejectedWithoutCharge() public {
        vm.expectRevert(SorenVault.InvalidHash.selector);
        vm.prank(alice);
        vault.commit(1, bytes32(0));
        assertEq(token.balanceOf(alice), PLAYER_FUNDS);
        assertEq(vault.totalBurned(), 0);
    }

    function test_lockedChapterRejectsCommitAndRevealWithoutCharge() public {
        vm.expectRevert(SorenVault.ChapterNotOpen.selector);
        _commit(2, alice, ANSWER, SECRET);
        vm.expectRevert(SorenVault.ChapterNotOpen.selector);
        _reveal(2, alice, ANSWER, SECRET);
        assertEq(token.balanceOf(alice), PLAYER_FUNDS);
    }

    function test_revealInSameBlockRejectedEvenIfTimeAdvanced() public {
        _commit(1, alice, ANSWER, SECRET);
        vm.warp(vm.getBlockTimestamp() + 30);
        vm.expectRevert(SorenVault.RevealTooEarly.selector);
        _reveal(1, alice, ANSWER, SECRET);
        _assertOpenAndUnpaid();
    }

    function test_revealInNextBlockWithSameTimestampSucceeds() public {
        _commit(1, alice, ANSWER, SECRET);
        vm.roll(vm.getBlockNumber() + 1);
        _reveal(1, alice, ANSWER, SECRET);
        assertEq(vault.getChapter(1).solver, alice);
    }

    function test_exact24HourDeadlineIsIncluded() public {
        _commit(1, alice, ANSWER, SECRET);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        _reveal(1, alice, ANSWER, SECRET);
        assertEq(vault.getChapter(1).solver, alice);
    }

    function test_revealAfter24HoursRejectedAndBurnIsNotRefunded() public {
        _commit(1, alice, ANSWER, SECRET);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 24 hours + 1);
        vm.expectRevert(SorenVault.RevealExpired.selector);
        _reveal(1, alice, ANSWER, SECRET);
        _assertOpenAndUnpaid();
        assertEq(token.balanceOf(alice), PLAYER_FUNDS - COST);
        assertEq(token.balanceOf(DEAD), COST);
        _assertStats(alice, 1, COST, 0);
    }

    function testFuzz_revealWindowBoundary(uint32 elapsed) public {
        elapsed = uint32(bound(elapsed, 0, 48 hours));
        _commit(1, alice, ANSWER, SECRET);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + elapsed);
        if (elapsed > 24 hours) {
            vm.expectRevert(SorenVault.RevealExpired.selector);
            _reveal(1, alice, ANSWER, SECRET);
            _assertOpenAndUnpaid();
        } else {
            _reveal(1, alice, ANSWER, SECRET);
            assertEq(vault.getChapter(1).solver, alice);
        }
        _assertConservation();
    }

    function test_frontRunnerWithoutCommitCannotCopyReveal() public {
        _commit(1, alice, ANSWER, SECRET);
        _nextBlock();
        vm.expectRevert(SorenVault.NoCommitment.selector);
        _reveal(1, bob, ANSWER, SECRET);
        _reveal(1, alice, ANSWER, SECRET);
        assertEq(vault.getChapter(1).solver, alice);
    }

    function test_copiedCommitHashDoesNotAuthorizeOtherWallet() public {
        bytes32 alicesHash = _hash(ANSWER, alice, SECRET);
        vm.prank(bob);
        vault.commit(1, alicesHash);
        _commit(1, alice, ANSWER, SECRET);
        _nextBlock();
        vm.expectRevert(SorenVault.CommitmentMismatch.selector);
        _reveal(1, bob, ANSWER, SECRET);
        _reveal(1, alice, ANSWER, SECRET);
        assertEq(vault.getChapter(1).solver, alice);
        assertEq(token.balanceOf(bob), PLAYER_FUNDS - COST);
        assertEq(vault.totalBurned(), 2 * COST);
    }

    function test_newCommitAfterSeeingRevealCannotRevealInSameBlock() public {
        _commit(1, alice, ANSWER, SECRET);
        _nextBlock();
        _commit(1, bob, ANSWER, SECRET);
        vm.expectRevert(SorenVault.RevealTooEarly.selector);
        _reveal(1, bob, ANSWER, SECRET);
        _reveal(1, alice, ANSWER, SECRET);
        assertEq(vault.getChapter(1).solver, alice);
    }

    function test_anEarlierUnrelatedCommitCannotBeChangedToStolenAnswer() public {
        _commit(1, bob, "wrong", SECRET);
        _commit(1, alice, ANSWER, SECRET);
        _nextBlock();
        vm.expectRevert(SorenVault.CommitmentMismatch.selector);
        _reveal(1, bob, ANSWER, SECRET);
        _reveal(1, alice, ANSWER, SECRET);
        assertEq(vault.getChapter(1).solver, alice);
    }

    function test_wrongSecretAndEncodingRejected() public {
        _commit(1, alice, ANSWER, SECRET);
        vm.prank(bob);
        vault.commit(1, keccak256(abi.encodePacked(ANSWER, bob, SECRET)));
        _nextBlock();
        vm.expectRevert(SorenVault.CommitmentMismatch.selector);
        _reveal(1, alice, ANSWER, keccak256("different secret"));
        vm.expectRevert(SorenVault.CommitmentMismatch.selector);
        _reveal(1, bob, ANSWER, SECRET);
        _assertOpenAndUnpaid();
    }

    function test_wrongAnswerFailsWithoutPayoutOrAdditionalBurn() public {
        _commit(1, alice, "wronganswer", SECRET);
        _nextBlock();
        vm.expectRevert(SorenVault.IncorrectAnswer.selector);
        _reveal(1, alice, "wronganswer", SECRET);
        _assertOpenAndUnpaid();
        _assertStats(alice, 1, COST, 0);
        assertEq(token.balanceOf(alice), PLAYER_FUNDS - COST);
        assertEq(vault.totalBurned(), COST);
        vm.expectRevert(SorenVault.CommitmentMismatch.selector);
        _reveal(1, alice, ANSWER, SECRET);
        _commit(1, alice, ANSWER, SECRET);
        _nextBlock();
        _reveal(1, alice, ANSWER, SECRET);
        _assertStats(alice, 2, COST * 2, 1);
        assertEq(token.balanceOf(alice), PLAYER_FUNDS - COST * 2 + PRIZE);
    }

    function test_newCommitReplacesOldAndResetsBothClocks() public {
        _commit(1, alice, "oldguess", SECRET);
        _nextBlock();
        bytes32 newSecret = keccak256("new secret");
        _commit(1, alice, ANSWER, newSecret);
        (bytes32 hash, uint256 committedBlock, uint256 committedTime) = vault.commitments(1, alice);
        assertEq(hash, _hash(ANSWER, alice, newSecret));
        assertEq(committedBlock, vm.getBlockNumber());
        assertEq(committedTime, vm.getBlockTimestamp());
        vm.expectRevert(SorenVault.RevealTooEarly.selector);
        _reveal(1, alice, ANSWER, newSecret);
        _nextBlock();
        vm.expectRevert(SorenVault.CommitmentMismatch.selector);
        _reveal(1, alice, "oldguess", SECRET);
        _reveal(1, alice, ANSWER, newSecret);
        assertEq(vault.totalBurned(), 2 * COST);
        _assertStats(alice, 2, 2 * COST, 1);
    }

    function test_duplicateCommitChargesAgainAndResetsClock() public {
        _commit(1, alice, ANSWER, SECRET);
        _nextBlock();
        _commit(1, alice, ANSWER, SECRET);
        vm.expectRevert(SorenVault.RevealTooEarly.selector);
        _reveal(1, alice, ANSWER, SECRET);
        _assertStats(alice, 2, COST * 2, 0);
        assertEq(vault.getChapter(1).commits, 2);
        assertEq(vault.getChapter(1).burned, 2 * COST);
    }

    function test_failedReplacementPreservesOriginalCommitAndTiming() public {
        _approve(alice, COST);
        _commit(1, alice, ANSWER, SECRET);
        (bytes32 hash, uint256 committedBlock, uint256 committedTime) = vault.commitments(1, alice);
        _nextBlock();
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(vault), 0, COST)
        );
        _commit(1, alice, "replacement", SECRET);
        (bytes32 afterHash, uint256 afterBlock, uint256 afterTime) = vault.commitments(1, alice);
        assertEq(afterHash, hash);
        assertEq(afterBlock, committedBlock);
        assertEq(afterTime, committedTime);
        _assertStats(alice, 1, COST, 0);
        _reveal(1, alice, ANSWER, SECRET);
        assertEq(vault.getChapter(1).solver, alice);
    }

    function test_expiredCommitCanBeReplacedWithNewPaidCommit() public {
        _commit(1, alice, ANSWER, SECRET);
        vm.warp(vm.getBlockTimestamp() + 24 hours + 1);
        _nextBlock();
        _commit(1, alice, ANSWER, SECRET);
        _nextBlock();
        _reveal(1, alice, ANSWER, SECRET);
        _assertStats(alice, 2, 2 * COST, 1);
    }

    function test_firstValidRevealWinsExactlyOnce() public {
        _commit(1, alice, ANSWER, SECRET);
        _commit(1, bob, ANSWER, SECRET);
        _nextBlock();
        vm.expectEmit(true, true, false, true, address(vault));
        emit SorenVault.Solved(1, bob, PRIZE);
        _reveal(1, bob, ANSWER, SECRET);

        SorenVault.Chapter memory chapter = vault.getChapter(1);
        assertEq(uint256(chapter.status), uint256(SorenVault.Status.Solved));
        assertEq(chapter.solver, bob);
        assertEq(chapter.solvedAt, vm.getBlockTimestamp());
        assertEq(chapter.prize, PRIZE);
        assertEq(chapter.commits, 2);
        assertEq(chapter.burned, 2 * COST);
        assertEq(vault.prizeBalance(), 9 * PRIZE);
        assertEq(vault.reservedPrizes(), 0);
        assertEq(vault.totalPrizesPaid(), PRIZE);
        assertEq(vault.chaptersSolved(), 1);
        assertEq(token.balanceOf(bob), PLAYER_FUNDS - COST + PRIZE);
        _assertStats(bob, 1, COST, 1);
        _assertStats(alice, 1, COST, 0);
        _assertNoCommit(bob);

        vm.expectRevert(SorenVault.ChapterNotOpen.selector);
        _reveal(1, alice, ANSWER, SECRET);
        vm.expectRevert(SorenVault.ChapterNotOpen.selector);
        _reveal(1, bob, ANSWER, SECRET);
        vm.expectRevert(SorenVault.ChapterNotOpen.selector);
        _commit(1, carol, ANSWER, SECRET);
        assertEq(token.balanceOf(carol), PLAYER_FUNDS);
        assertEq(vault.totalPrizesPaid(), PRIZE);
        _assertConservation();
    }

    function test_oldChapterCommitmentDoesNotAuthorizeNewChapter() public {
        _commit(1, bob, ANSWER, SECRET);
        _solve(1, alice, ANSWER);
        _publish(2, ANSWER, PRIZE);
        vm.expectRevert(SorenVault.NoCommitment.selector);
        _reveal(2, bob, ANSWER, SECRET);
        _commit(2, bob, ANSWER, SECRET);
        _nextBlock();
        _reveal(2, bob, ANSWER, SECRET);
        assertEq(vault.chaptersSolved(), 2);
        _assertStats(bob, 2, 2 * COST, 1);
    }

    function test_answersAreExactBytesAndNotNormalizedOnchain() public {
        _commit(1, alice, " SO REN ", SECRET);
        _nextBlock();
        vm.expectRevert(SorenVault.IncorrectAnswer.selector);
        _reveal(1, alice, " SO REN ", SECRET);
        _assertOpenAndUnpaid();
    }

    function test_sevenChapterLifecycleAndPersistentRecords() public {
        uint256 startBalance = token.balanceOf(alice);
        for (uint256 id = 1; id <= 7; ++id) {
            string memory answer = id == 1 ? ANSWER : string.concat("answer", vm.toString(id));
            if (id > 1) _publish(id, answer, PRIZE);
            vm.prank(owner);
            vault.setHint(id, "persistent hint");
            _solve(id, alice, answer);
            assertEq(vault.chaptersSolved(), id);
            assertEq(vault.totalPrizesPaid(), id * PRIZE);
            assertEq(vault.prizeBalance(), (10 - id) * PRIZE);
            _assertConservation();
        }
        SorenVault.Chapter[7] memory all = vault.getAllChapters();
        for (uint256 i; i < 7; ++i) {
            assertEq(uint256(all[i].status), uint256(SorenVault.Status.Solved));
            assertEq(all[i].solver, alice);
            assertGt(all[i].solvedAt, 0);
            assertEq(all[i].prize, PRIZE);
            assertEq(all[i].commits, 1);
            assertEq(all[i].burned, COST);
            assertEq(all[i].hint, "persistent hint");
            assertEq(all[i].transmission, string.concat("Transmission ", vm.toString(i + 1)));
        }
        assertEq(token.balanceOf(alice), startBalance + 7 * (PRIZE - COST));
        assertEq(vault.lastPublishedChapter(), 7);
        assertEq(vault.totalBurned(), 7 * COST);
        assertEq(vault.availablePrizes(), 3 * PRIZE);
        _assertStats(alice, 7, 7 * COST, 7);
        vm.expectRevert(SorenVault.InvalidChapter.selector);
        _publish(8, ANSWER, PRIZE);
    }

    function test_unpublishedChaptersRemainLockedAndViewsHaveStableOrder() public view {
        SorenVault.Chapter[7] memory all = vault.getAllChapters();
        assertEq(uint256(all[0].status), uint256(SorenVault.Status.Open));
        for (uint256 i = 1; i < 7; ++i) {
            assertEq(uint256(all[i].status), uint256(SorenVault.Status.Locked));
            assertEq(all[i].solver, address(0));
            assertEq(all[i].prize, 0);
            assertEq(all[i].transmission, "");
            assertEq(all[i].hint, "");
        }
    }

    function test_ownerCanParticipateButMustPayAndFollowRevealRules() public {
        uint256 beforeBalance = token.balanceOf(owner);
        _commit(1, owner, ANSWER, SECRET);
        vm.expectRevert(SorenVault.RevealTooEarly.selector);
        _reveal(1, owner, ANSWER, SECRET);
        _nextBlock();
        _reveal(1, owner, ANSWER, SECRET);
        assertEq(token.balanceOf(owner), beforeBalance - COST + PRIZE);
        _assertStats(owner, 1, COST, 1);
        _assertConservation();
    }

    function testFuzz_multipleGuessesConserveAllFunds(uint8 guesses) public {
        guesses = uint8(bound(guesses, 1, 50));
        for (uint256 i; i < guesses; ++i) {
            _commit(1, alice, ANSWER, bytes32(i));
        }
        _nextBlock();
        _reveal(1, alice, ANSWER, bytes32(uint256(guesses) - 1));
        assertEq(vault.totalBurned(), uint256(guesses) * COST);
        assertEq(token.balanceOf(DEAD), uint256(guesses) * COST);
        assertEq(token.balanceOf(alice), PLAYER_FUNDS - uint256(guesses) * COST + PRIZE);
        _assertStats(alice, guesses, uint256(guesses) * COST, 1);
        _assertConservation();
    }

    function testFuzz_arbitraryAnswerAndSecretUseAbiEncoding(string memory answer, bytes32 secret) public {
        _solve(1, bob, ANSWER);
        _publish(2, answer, PRIZE);
        _commit(2, alice, answer, secret);
        _nextBlock();
        _reveal(2, alice, answer, secret);
        assertEq(vault.getChapter(2).solver, alice);
        _assertConservation();
    }

    function _assertNoCommit(address player) private view {
        (bytes32 hash, uint256 committedBlock, uint256 committedTime) = vault.commitments(1, player);
        assertEq(hash, bytes32(0));
        assertEq(committedBlock, 0);
        assertEq(committedTime, 0);
    }

    function _assertOpenAndUnpaid() private view {
        SorenVault.Chapter memory chapter = vault.getChapter(1);
        assertEq(uint256(chapter.status), uint256(SorenVault.Status.Open));
        assertEq(chapter.solver, address(0));
        assertEq(chapter.solvedAt, 0);
        assertEq(vault.chaptersSolved(), 0);
        assertEq(vault.totalPrizesPaid(), 0);
        assertEq(vault.reservedPrizes(), PRIZE);
        assertEq(vault.prizeBalance(), 10 * PRIZE);
    }
}
