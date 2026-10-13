// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SorenTestBase} from "./helpers/SorenTestBase.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {SorenVault} from "src/SorenVault.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// forge-config: default.fuzz.runs = 1000
contract SorenVaultBoundariesTest is SorenTestBase {
    function test_oneWeiPrizesCanExhaustThenRefillTheVault() public {
        for (uint256 id = 1; id <= 7; ++id) {
            bytes32 previousRecord;
            if (id > 1) previousRecord = keccak256(abi.encode(vault.getChapter(id - 1)));
            vm.expectRevert(SorenVault.InsufficientFunding.selector);
            _publish(id, ANSWER, 1);
            assertEq(vault.lastPublishedChapter(), id - 1);
            assertEq(vault.reservedPrizes(), 0);
            assertEq(uint256(vault.getChapter(id).status), uint256(SorenVault.Status.Locked));
            if (id > 1) assertEq(keccak256(abi.encode(vault.getChapter(id - 1))), previousRecord);

            _fund(1);
            _publish(id, ANSWER, 1);
            assertEq(vault.availablePrizes(), 0);
            _solve(id, alice, ANSWER);
            assertEq(vault.prizeBalance(), 0);
            assertEq(vault.availablePrizes(), 0);
            assertEq(vault.totalPrizesPaid(), id);
            assertEq(vault.chaptersSolved(), id);
        }
        assertEq(token.balanceOf(alice), PLAYER_FUNDS - 7 * COST + 7);
        _assertConservation();
    }

    function test_largestPrizeReachableWithOnePaidGuessSettlesExactly() public {
        LaunchToken wholeSupplyToken = new LaunchToken();
        SorenVault wholeSupplyVault = new SorenVault(address(this));
        wholeSupplyVault.setToken(address(wholeSupplyToken));
        uint256 supply = 1_000_000_000 ether;
        uint256 prize = supply - COST;
        wholeSupplyToken.transfer(alice, COST);
        wholeSupplyToken.approve(address(wholeSupplyVault), prize);
        wholeSupplyVault.fund(prize);
        wholeSupplyVault.publishChapter(1, keccak256(bytes(ANSWER)), prize, "whole supply less the commit fee");
        assertEq(wholeSupplyToken.balanceOf(address(this)), 0);
        assertEq(wholeSupplyVault.reservedPrizes(), prize);
        assertEq(wholeSupplyVault.availablePrizes(), 0);
        vm.startPrank(alice);
        wholeSupplyToken.approve(address(wholeSupplyVault), COST);
        wholeSupplyVault.commit(1, _hash(ANSWER, alice, SECRET));
        vm.roll(vm.getBlockNumber() + 1);
        wholeSupplyVault.reveal(1, ANSWER, SECRET);
        vm.stopPrank();
        assertEq(wholeSupplyToken.balanceOf(alice), prize);
        assertEq(wholeSupplyToken.balanceOf(DEAD), COST);
        assertEq(wholeSupplyToken.totalSupply(), supply);
        assertEq(wholeSupplyVault.totalPrizesPaid(), prize);
        assertEq(wholeSupplyVault.prizeBalance(), 0);
        assertEq(wholeSupplyVault.reservedPrizes(), 0);
        assertEq(wholeSupplyVault.getChapter(1).solver, alice);
    }

    function test_uint256MaximumPrizeFailsWithoutConsumingChapterId() public {
        _fund(PRIZE);
        vm.expectRevert(SorenVault.InsufficientFunding.selector);
        _publish(1, ANSWER, type(uint256).max);
        assertEq(vault.lastPublishedChapter(), 0);
        assertEq(vault.reservedPrizes(), 0);
        assertEq(vault.availablePrizes(), PRIZE);
        _publish(1, ANSWER, PRIZE);
        _solve(1, alice, ANSWER);
        assertEq(vault.totalPrizesPaid(), PRIZE);
        _assertConservation();
    }

    function test_uint256MaximumFundingFailsWithoutConsumingInfiniteAllowance() public {
        vm.prank(owner);
        token.approve(address(vault), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, owner, OWNER_FUNDS, type(uint256).max
            )
        );
        _fund(type(uint256).max);
        assertEq(token.allowance(owner, address(vault)), type(uint256).max);
        assertEq(token.balanceOf(owner), OWNER_FUNDS);
        assertEq(vault.prizeBalance(), 0);
        _fund(1);
        assertEq(vault.prizeBalance(), 1);
        _assertConservation();
    }

    function test_failedFundingRestoresFiniteAllowance() public {
        vm.prank(owner);
        token.approve(address(vault), OWNER_FUNDS + 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, OWNER_FUNDS, OWNER_FUNDS + 1)
        );
        _fund(OWNER_FUNDS + 1);
        assertEq(token.allowance(owner, address(vault)), OWNER_FUNDS + 1);
        assertEq(token.balanceOf(owner), OWNER_FUNDS);
        assertEq(vault.prizeBalance(), 0);
        _fund(OWNER_FUNDS);
        assertEq(token.allowance(owner, address(vault)), 1);
        assertEq(vault.prizeBalance(), OWNER_FUNDS);
        _assertConservation();
    }

    function test_revealNeedsNeitherRemainingBalanceNorAllowance() public {
        _fund(PRIZE);
        _publish(1, ANSWER, PRIZE);
        vm.prank(alice);
        token.transfer(bob, PLAYER_FUNDS - COST);
        _approve(alice, COST);
        _commit(1, alice, ANSWER, SECRET);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.allowance(alice, address(vault)), 0);
        _nextBlock();
        _reveal(1, alice, ANSWER, SECRET);
        assertEq(token.balanceOf(alice), PRIZE);
        assertEq(token.allowance(alice, address(vault)), 0);
        _assertStats(alice, 1, COST, 1);
        _assertConservation();
    }

    function test_underfundedReplacementPreservesOriginalCommitAndFiniteAllowance() public {
        _fund(PRIZE);
        _publish(1, ANSWER, PRIZE);
        _commit(1, alice, ANSWER, SECRET);
        (bytes32 oldHash, uint256 oldBlock, uint256 oldTime) = vault.commitments(1, alice);
        bytes32 oldChapter = keccak256(abi.encode(vault.getChapter(1)));
        vm.prank(alice);
        token.transfer(bob, PLAYER_FUNDS - 2 * COST + 1);
        _approve(alice, COST);
        _nextBlock();
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, COST - 1, COST));
        _commit(1, alice, "replacement", keccak256("new secret"));
        (bytes32 newHash, uint256 newBlock, uint256 newTime) = vault.commitments(1, alice);
        assertEq(newHash, oldHash);
        assertEq(newBlock, oldBlock);
        assertEq(newTime, oldTime);
        assertEq(keccak256(abi.encode(vault.getChapter(1))), oldChapter);
        assertEq(token.allowance(alice, address(vault)), COST);
        assertEq(vault.totalBurned(), COST);
        assertEq(token.balanceOf(DEAD), COST);
        _assertStats(alice, 1, COST, 0);
        _reveal(1, alice, ANSWER, SECRET);
        assertEq(token.balanceOf(alice), COST - 1 + PRIZE);
        _assertStats(alice, 1, COST, 1);
        _assertConservation();
    }

    function test_openingNextChapterDoesNotReviveLosingCommitments() public {
        _fund(2 * PRIZE);
        _publish(1, ANSWER, PRIZE);
        _commit(1, bob, ANSWER, SECRET);
        _solve(1, alice, ANSWER);
        bytes32 settled = keccak256(abi.encode(vault.getChapter(1)));
        _publish(2, ANSWER, PRIZE);
        uint256 allowance = token.allowance(bob, address(vault));
        vm.expectRevert(SorenVault.ChapterNotOpen.selector);
        _reveal(1, bob, ANSWER, SECRET);
        vm.expectRevert(SorenVault.ChapterNotOpen.selector);
        _commit(1, bob, ANSWER, SECRET);
        vm.expectRevert(SorenVault.NoCommitment.selector);
        _reveal(2, bob, ANSWER, SECRET);
        assertEq(keccak256(abi.encode(vault.getChapter(1))), settled);
        assertEq(token.allowance(bob, address(vault)), allowance);
        assertEq(vault.reservedPrizes(), PRIZE);
        assertEq(vault.totalPrizesPaid(), PRIZE);
        _solve(2, bob, ANSWER);
        _assertStats(bob, 2, 2 * COST, 1);
        _assertConservation();
    }

    function testFuzz_anyFundedPrizePaysExactlyAndDoesNotSpendRevealAllowance(uint256 prize) public {
        prize = bound(prize, 1, OWNER_FUNDS);
        _fund(prize);
        _publish(1, ANSWER, prize);
        _commit(1, alice, ANSWER, SECRET);
        _approve(alice, 0);
        _nextBlock();
        _reveal(1, alice, ANSWER, SECRET);
        assertEq(token.balanceOf(alice), PLAYER_FUNDS - COST + prize);
        assertEq(token.balanceOf(owner), OWNER_FUNDS - prize);
        assertEq(token.allowance(alice, address(vault)), 0);
        assertEq(vault.totalPrizesPaid(), prize);
        assertEq(vault.prizeBalance(), 0);
        assertEq(vault.reservedPrizes(), 0);
        _assertConservation();
    }

    function testFuzz_rejectedHintKeepsExistingChapterAndCanBeRetried(uint256 length) public {
        length = bound(length, 501, 2_001);
        _fund(PRIZE);
        _publish(1, ANSWER, PRIZE);
        vm.prank(owner);
        vault.setHint(1, "keep this hint");
        bytes32 beforeChapter = keccak256(abi.encode(vault.getChapter(1)));
        vm.expectRevert(SorenVault.HintTooLong.selector);
        vm.prank(owner);
        vault.setHint(1, string(new bytes(length)));
        assertEq(keccak256(abi.encode(vault.getChapter(1))), beforeChapter);
        vm.prank(owner);
        vault.setHint(1, "valid replacement");
        assertEq(vault.getChapter(1).hint, "valid replacement");
        assertEq(vault.reservedPrizes(), PRIZE);
        _assertConservation();
    }
}
