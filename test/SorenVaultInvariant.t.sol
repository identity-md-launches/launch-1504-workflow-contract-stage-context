// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SorenTestBase} from "./helpers/SorenTestBase.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {SorenVault} from "../src/SorenVault.sol";

/// @dev A separate ledger tracks inputs/payouts while the fuzzer interleaves actions and time.
contract SorenHandler is Test {
    struct Guess {
        bool exists;
        bool correct;
        bytes32 secret;
        uint256 blockNumber;
        uint256 timestamp;
    }

    LaunchToken public token;
    SorenVault public vault;
    address public owner;
    address[3] public players;
    uint256 public deposits;
    uint256 public paid;
    uint256 public burns;
    uint256 public published;
    uint256 public solved;
    mapping(uint256 id => uint256) public prizes;
    mapping(uint256 id => uint256) public chapterCommits;
    mapping(uint256 id => address) public solvers;
    mapping(address player => uint256) public guesses;
    mapping(address player => uint256) public wins;
    mapping(uint256 id => mapping(address player => Guess)) internal _guesses;

    constructor(
        LaunchToken token_,
        SorenVault vault_,
        address owner_,
        address[3] memory players_,
        uint256 initialFunding
    ) {
        token = token_;
        vault = vault_;
        owner = owner_;
        players = players_;
        deposits = initialFunding;
    }

    function fund(uint256 seed) external {
        uint256 balance = token.balanceOf(owner);
        if (balance == 0) return;
        uint256 amount = bound(seed, 1, balance);
        vm.startPrank(owner);
        token.approve(address(vault), amount);
        vault.fund(amount);
        vm.stopPrank();
        deposits += amount;
    }

    function donate(uint256 playerSeed, uint256 amountSeed) external {
        address player = players[playerSeed % players.length];
        uint256 balance = token.balanceOf(player);
        if (balance == 0) return;
        uint256 amount = bound(amountSeed, 1, balance);
        vm.prank(player);
        token.transfer(address(vault), amount);
        deposits += amount;
    }

    function publishNext(uint256 prizeSeed) external {
        if (published != solved || published == 7 || deposits == paid) return;
        uint256 id = published + 1;
        uint256 prize = bound(prizeSeed, 1, deposits - paid);
        vm.prank(owner);
        vault.publishChapter(id, keccak256(bytes(_answer(id))), prize, "invariant transmission");
        prizes[id] = prize;
        published = id;
    }

    function commitGuess(uint256 playerSeed, bool correct, bytes32 secret) external {
        if (published == solved) return;
        address player = players[playerSeed % players.length];
        if (token.balanceOf(player) < 100 ether) return;
        string memory answer = correct ? _answer(published) : "incorrect";
        vm.startPrank(player);
        token.approve(address(vault), 100 ether);
        vault.commit(published, keccak256(abi.encode(answer, player, secret)));
        vm.stopPrank();
        _guesses[published][player] = Guess(true, correct, secret, vm.getBlockNumber(), vm.getBlockTimestamp());
        guesses[player] += 1;
        chapterCommits[published] += 1;
        burns += 100 ether;
    }

    function revealGuess(uint256 playerSeed) external {
        if (published == solved) return;
        address player = players[playerSeed % players.length];
        Guess memory guess = _guesses[published][player];
        string memory answer = guess.correct ? _answer(published) : "incorrect";

        if (!guess.exists) {
            vm.expectRevert(SorenVault.NoCommitment.selector);
        } else if (vm.getBlockNumber() <= guess.blockNumber) {
            vm.expectRevert(SorenVault.RevealTooEarly.selector);
        } else if (vm.getBlockTimestamp() > guess.timestamp + 24 hours) {
            vm.expectRevert(SorenVault.RevealExpired.selector);
        } else if (!guess.correct) {
            vm.expectRevert(SorenVault.IncorrectAnswer.selector);
        } else {
            vm.prank(player);
            vault.reveal(published, answer, guess.secret);
            solved += 1;
            wins[player] += 1;
            paid += prizes[published];
            solvers[published] = player;
            delete _guesses[published][player];
            return;
        }
        vm.prank(player);
        vault.reveal(published, answer, guess.secret);
    }

    function advance(uint256 blocksSeed, uint256 secondsSeed) external {
        vm.roll(vm.getBlockNumber() + bound(blocksSeed, 0, 10));
        vm.warp(vm.getBlockTimestamp() + bound(secondsSeed, 0, 25 hours));
    }

    function updateHint(string calldata hint) external {
        if (published == solved) return;
        vm.prank(owner);
        if (bytes(hint).length > 500) {
            vm.expectRevert(SorenVault.HintTooLong.selector);
        }
        vault.setHint(published, hint);
    }

    function _answer(uint256 id) private pure returns (string memory) {
        return string(abi.encodePacked("chapter-answer-", id));
    }
}

contract SorenVaultInvariantTest is SorenTestBase {
    SorenHandler internal handler;

    function setUp() public override {
        super.setUp();
        _fund(10 * PRIZE);
        handler = new SorenHandler(token, vault, owner, [alice, bob, carol], 10 * PRIZE);
        handler.publishNext(PRIZE);

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.fund.selector;
        selectors[1] = handler.donate.selector;
        selectors[2] = handler.publishNext.selector;
        selectors[3] = handler.commitGuess.selector;
        selectors[4] = handler.revealGuess.selector;
        selectors[5] = handler.advance.selector;
        selectors[6] = handler.updateHint.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_fundsConservedAndPrizesAlwaysSolvent() public view {
        _assertConservation();
        assertEq(vault.prizeBalance() + handler.paid(), handler.deposits());
        assertEq(vault.totalPrizesPaid(), handler.paid());
        assertEq(vault.totalBurned(), handler.burns());
        assertEq(token.balanceOf(DEAD), handler.burns());
        uint256 expectedReserved = handler.published() == handler.solved() ? 0 : handler.prizes(handler.published());
        assertEq(vault.reservedPrizes(), expectedReserved);
        assertEq(vault.availablePrizes() + expectedReserved, vault.prizeBalance());
    }

    function invariant_onlyOneOpenChapterAndSequentialWinners() public view {
        assertEq(vault.lastPublishedChapter(), handler.published());
        assertEq(vault.chaptersSolved(), handler.solved());
        assertLe(handler.published(), 7);
        assertLe(handler.solved(), handler.published());
        assertLe(handler.published() - handler.solved(), 1);
        SorenVault.Chapter[7] memory all = vault.getAllChapters();
        for (uint256 id = 1; id <= 7; ++id) {
            SorenVault.Chapter memory chapter = all[id - 1];
            if (id <= handler.solved()) {
                assertEq(uint256(chapter.status), uint256(SorenVault.Status.Solved));
                assertEq(chapter.solver, handler.solvers(id));
                assertGt(chapter.solvedAt, 0);
            } else if (id == handler.published()) {
                assertEq(uint256(chapter.status), uint256(SorenVault.Status.Open));
                assertEq(chapter.solver, address(0));
                assertEq(chapter.solvedAt, 0);
            } else {
                assertEq(uint256(chapter.status), uint256(SorenVault.Status.Locked));
                assertEq(chapter.prize, 0);
            }
            assertEq(chapter.prize, handler.prizes(id));
            assertEq(chapter.commits, handler.chapterCommits(id));
            assertEq(chapter.burned, handler.chapterCommits(id) * COST);
        }
    }

    function invariant_playerRecordsMatchPaidGuessesAndWins() public view {
        address[3] memory players = [alice, bob, carol];
        uint256 sumGuesses;
        uint256 sumWins;
        for (uint256 i; i < players.length; ++i) {
            uint256 expectedGuesses = handler.guesses(players[i]);
            uint256 expectedWins = handler.wins(players[i]);
            _assertStats(players[i], expectedGuesses, expectedGuesses * COST, expectedWins);
            sumGuesses += expectedGuesses;
            sumWins += expectedWins;
        }
        assertEq(sumGuesses * COST, vault.totalBurned());
        assertEq(sumWins, vault.chaptersSolved());
    }
}
