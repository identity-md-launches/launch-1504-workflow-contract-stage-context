// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SorenTestBase} from "./helpers/SorenTestBase.sol";
import {SorenVault} from "../src/SorenVault.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract WrongDecimals {
    function decimals() external pure returns (uint8) {
        return 6;
    }
}

contract NoMetadata {}

contract SorenVaultAdminTest is SorenTestBase {
    function test_constructorRequiresExplicitNonzeroOwner() public {
        vm.expectRevert(SorenVault.InvalidOwner.selector);
        new SorenVault(address(0));
        SorenVault unconfigured = new SorenVault(owner);
        assertEq(unconfigured.owner(), owner);
        assertEq(address(unconfigured.token()), address(0));
        assertNotEq(unconfigured.owner(), address(this));
    }

    function test_unconfiguredTokenOperationsRevertClearly() public {
        SorenVault unconfigured = new SorenVault(owner);
        vm.startPrank(owner);
        vm.expectRevert(SorenVault.TokenNotConfigured.selector);
        unconfigured.fund(1);
        vm.expectRevert(SorenVault.TokenNotConfigured.selector);
        unconfigured.publishChapter(1, keccak256("answer"), PRIZE, "transmission");
        vm.stopPrank();
        vm.expectRevert(SorenVault.TokenNotConfigured.selector);
        unconfigured.commit(1, SECRET);
        vm.expectRevert(SorenVault.TokenNotConfigured.selector);
        unconfigured.reveal(1, ANSWER, SECRET);
        vm.expectRevert(SorenVault.TokenNotConfigured.selector);
        unconfigured.prizeBalance();
        vm.expectRevert(SorenVault.TokenNotConfigured.selector);
        unconfigured.availablePrizes();
        assertEq(uint256(unconfigured.getChapter(1).status), uint256(SorenVault.Status.Locked));
    }

    function test_onlyOwnerCanSetTokenAndOnlyOnce() public {
        SorenVault unconfigured = new SorenVault(owner);
        vm.expectRevert(SorenVault.Unauthorized.selector);
        unconfigured.setToken(address(token));
        vm.expectEmit(true, false, false, true, address(unconfigured));
        emit SorenVault.TokenSet(address(token));
        vm.prank(owner);
        unconfigured.setToken(address(token));
        assertEq(address(unconfigured.token()), address(token));
        vm.expectRevert(SorenVault.TokenAlreadySet.selector);
        vm.prank(owner);
        unconfigured.setToken(address(token));
    }

    function test_invalidTokenSettingsLeaveSetterAvailable() public {
        SorenVault unconfigured = new SorenVault(owner);
        WrongDecimals wrongDecimals = new WrongDecimals();
        NoMetadata noMetadata = new NoMetadata();
        address[5] memory invalid =
            [address(0), alice, address(unconfigured), address(wrongDecimals), address(noMetadata)];
        vm.startPrank(owner);
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(SorenVault.InvalidToken.selector);
            unconfigured.setToken(invalid[i]);
            assertEq(address(unconfigured.token()), address(0));
        }
        unconfigured.setToken(address(token));
        vm.stopPrank();
        assertEq(address(unconfigured.token()), address(token));
    }

    function test_onlyOwnerCanFundPublishAndHint() public {
        vm.startPrank(alice);
        vm.expectRevert(SorenVault.Unauthorized.selector);
        vault.fund(1);
        vm.expectRevert(SorenVault.Unauthorized.selector);
        vault.publishChapter(1, SECRET, 1, "text");
        vm.expectRevert(SorenVault.Unauthorized.selector);
        vault.setHint(1, "hint");
        vm.stopPrank();
    }

    function test_fundMovesExactTokensAndEmits() public {
        vm.expectEmit(true, false, false, true, address(vault));
        emit SorenVault.Funded(owner, PRIZE);
        _fund(PRIZE);
        assertEq(token.balanceOf(owner), OWNER_FUNDS - PRIZE);
        assertEq(vault.prizeBalance(), PRIZE);
        assertEq(vault.availablePrizes(), PRIZE);
        _assertConservation();
    }

    function test_zeroFundingRejected() public {
        vm.expectRevert(SorenVault.InvalidAmount.selector);
        _fund(0);
    }

    function test_fundingWithoutAllowanceOrBalanceReverts() public {
        vm.prank(owner);
        token.approve(address(vault), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(vault), 0, PRIZE)
        );
        _fund(PRIZE);
        assertEq(vault.prizeBalance(), 0);
        vm.prank(owner);
        token.approve(address(vault), OWNER_FUNDS + 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, OWNER_FUNDS, OWNER_FUNDS + 1)
        );
        _fund(OWNER_FUNDS + 1);
        assertEq(vault.prizeBalance(), 0);
    }

    function test_directSornDonationsCanFundPrizes() public {
        vm.prank(alice);
        token.transfer(address(vault), PRIZE);
        _publish(1, ANSWER, PRIZE);
        assertEq(vault.reservedPrizes(), PRIZE);
        assertEq(vault.availablePrizes(), 0);
        _solve(1, bob, ANSWER);
        assertEq(vault.prizeBalance(), 0);
        _assertConservation();
    }

    function test_prizeMustAlreadyBeFunded() public {
        vm.expectRevert(SorenVault.InsufficientFunding.selector);
        _publish(1, ANSWER, PRIZE);
        _fund(PRIZE - 1);
        vm.expectRevert(SorenVault.InsufficientFunding.selector);
        _publish(1, ANSWER, PRIZE);
        assertEq(vault.lastPublishedChapter(), 0);
        assertEq(vault.reservedPrizes(), 0);
        assertEq(uint256(vault.getChapter(1).status), uint256(SorenVault.Status.Locked));
        _fund(1);
        _publish(1, ANSWER, PRIZE);
        assertEq(vault.availablePrizes(), 0);
    }

    function test_publishReservesPrizeAndEmitsFullTransmission() public {
        _fund(2 * PRIZE);
        vm.expectEmit(true, false, false, true, address(vault));
        emit SorenVault.ChapterPublished(1, keccak256(bytes(ANSWER)), PRIZE, "Transmission 1");
        _publish(1, ANSWER, PRIZE);
        SorenVault.Chapter memory chapter = vault.getChapter(1);
        assertEq(uint256(chapter.status), uint256(SorenVault.Status.Open));
        assertEq(chapter.answerHash, keccak256(bytes(ANSWER)));
        assertEq(chapter.transmission, "Transmission 1");
        assertEq(chapter.prize, PRIZE);
        assertEq(chapter.solver, address(0));
        assertEq(chapter.solvedAt, 0);
        assertEq(chapter.commits, 0);
        assertEq(chapter.burned, 0);
        assertEq(chapter.hint, "");
        assertEq(vault.reservedPrizes(), PRIZE);
        assertEq(vault.availablePrizes(), PRIZE);
    }

    function test_chaptersMustBePublishedInOrderAfterPreviousSolve() public {
        _fund(3 * PRIZE);
        vm.expectRevert(SorenVault.ChapterOutOfOrder.selector);
        _publish(2, ANSWER, PRIZE);
        _publish(1, ANSWER, PRIZE);
        vm.expectRevert(SorenVault.PreviousChapterUnsolved.selector);
        _publish(2, ANSWER, PRIZE);
        vm.expectRevert(SorenVault.ChapterOutOfOrder.selector);
        _publish(1, "changed answer", PRIZE * 2);
        vm.expectRevert(SorenVault.ChapterOutOfOrder.selector);
        _publish(3, ANSWER, PRIZE);
        _solve(1, alice, ANSWER);
        _publish(2, ANSWER, PRIZE);
        assertEq(vault.lastPublishedChapter(), 2);
        assertEq(uint256(vault.getChapter(3).status), uint256(SorenVault.Status.Locked));
    }

    function test_invalidChapterIdsRejectedByReadsAndWrites() public {
        uint256[3] memory ids = [uint256(0), uint256(8), type(uint256).max];
        for (uint256 i; i < ids.length; ++i) {
            vm.expectRevert(SorenVault.InvalidChapter.selector);
            vault.getChapter(ids[i]);
            vm.expectRevert(SorenVault.InvalidChapter.selector);
            _publish(ids[i], ANSWER, PRIZE);
            vm.expectRevert(SorenVault.InvalidChapter.selector);
            vm.prank(owner);
            vault.setHint(ids[i], "text");
            vm.expectRevert(SorenVault.InvalidChapter.selector);
            vault.commit(ids[i], SECRET);
            vm.expectRevert(SorenVault.InvalidChapter.selector);
            vault.reveal(ids[i], ANSWER, SECRET);
        }
    }

    function test_zeroPrizeAndZeroHashRejected() public {
        _fund(PRIZE);
        vm.startPrank(owner);
        vm.expectRevert(SorenVault.InvalidAmount.selector);
        vault.publishChapter(1, SECRET, 0, "");
        vm.expectRevert(SorenVault.InvalidHash.selector);
        vault.publishChapter(1, bytes32(0), PRIZE, "");
        vm.stopPrank();
    }

    function test_transmissionLimitCountsBytesAndAllowsExactLimit() public {
        _fund(PRIZE);
        vm.startPrank(owner);
        vm.expectRevert(SorenVault.TransmissionTooLong.selector);
        vault.publishChapter(1, SECRET, PRIZE, string(new bytes(2_001)));
        bytes memory text = new bytes(2_000);
        for (uint256 i; i < text.length; i += 2) {
            text[i] = 0xc3;
            text[i + 1] = 0xa9;
        }
        vault.publishChapter(1, SECRET, PRIZE, string(text));
        vm.stopPrank();
        assertEq(bytes(vault.getChapter(1).transmission).length, 2_000);
        assertEq(vault.getChapter(1).transmission, string(text));
    }

    function test_hintOnlyForOpenChapterCanReplaceOrClear() public {
        _fund(PRIZE);
        vm.expectRevert(SorenVault.ChapterNotOpen.selector);
        vm.prank(owner);
        vault.setHint(1, "locked");
        _publish(1, ANSWER, PRIZE);
        vm.startPrank(owner);
        vm.expectEmit(true, false, false, true, address(vault));
        emit SorenVault.HintPosted(1, "a hint");
        vault.setHint(1, "a hint");
        assertEq(vault.getChapter(1).hint, "a hint");
        vault.setHint(1, "replacement");
        assertEq(vault.getChapter(1).hint, "replacement");
        vault.setHint(1, "");
        assertEq(vault.getChapter(1).hint, "");
        vm.stopPrank();
        _solve(1, alice, ANSWER);
        vm.expectRevert(SorenVault.ChapterNotOpen.selector);
        vm.prank(owner);
        vault.setHint(1, "solved");
    }

    function test_hintLengthBoundary() public {
        _fund(PRIZE);
        _publish(1, ANSWER, PRIZE);
        vm.startPrank(owner);
        vm.expectRevert(SorenVault.HintTooLong.selector);
        vault.setHint(1, string(new bytes(501)));
        vault.setHint(1, string(new bytes(500)));
        vm.stopPrank();
        assertEq(bytes(vault.getChapter(1).hint).length, 500);
    }

    function test_ownerCannotWithdrawApproveSweepOrUpgradeFundedPrizes() public {
        _fund(2 * PRIZE);
        _publish(1, ANSWER, PRIZE);
        string[10] memory selectors = [
            "withdraw(uint256)",
            "withdraw(address,uint256)",
            "emergencyWithdraw()",
            "sweep(address)",
            "rescueTokens(address,address,uint256)",
            "approve(address,uint256)",
            "transfer(address,uint256)",
            "upgradeTo(address)",
            "cancelChapter(uint256)",
            "transferOwnership(address)"
        ];
        vm.startPrank(owner);
        for (uint256 i; i < selectors.length; ++i) {
            (bool ok,) = address(vault).call(abi.encodeWithSignature(selectors[i], owner, PRIZE, PRIZE));
            assertFalse(ok);
        }
        vm.stopPrank();
        assertEq(vault.prizeBalance(), 2 * PRIZE);
        assertEq(vault.reservedPrizes(), PRIZE);
        assertEq(token.allowance(address(vault), owner), 0);
        _assertConservation();
    }

    function test_nativeEthRejected() public {
        vm.deal(owner, 1 ether);
        vm.prank(owner);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(vault).balance, 0);
    }
}
