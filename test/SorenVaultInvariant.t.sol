// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SorenTestBase} from "./helpers/SorenTestBase.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {SorenVault} from "../src/SorenVault.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

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
    uint256 public ownerFunding;
    address public immutable treasury;
    mapping(uint256 id => uint256) public prizes;
    mapping(uint256 id => uint256) public chapterCommits;
    mapping(uint256 id => address) public solvers;
    mapping(address player => uint256) public guesses;
    mapping(address player => uint256) public wins;
    mapping(address player => uint256) public donations;
    mapping(address player => uint256) public rewards;
    mapping(address player => uint256) public topUps;
    mapping(uint256 id => bytes32) public settledRecords;
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
        ownerFunding = initialFunding;
        treasury = msg.sender;
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
        ownerFunding += amount;
    }

    function donate(uint256 playerSeed, uint256 amountSeed) external {
        address player = players[playerSeed % players.length];
        uint256 balance = token.balanceOf(player);
        if (balance == 0) return;
        uint256 amount = bound(amountSeed, 1, balance);
        vm.prank(player);
        token.transfer(address(vault), amount);
        deposits += amount;
        donations[player] += amount;
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
            _recordWin(player);
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

    /// @dev Keep settlement reachable even when randomly separated commits have expired.
    function solveCurrent(uint256 playerSeed, bytes32 secret) external {
        if (published == solved) return;
        address player = players[playerSeed % players.length];
        if (token.balanceOf(player) < 100 ether) return;
        string memory answer = _answer(published);
        vm.startPrank(player);
        token.approve(address(vault), 100 ether);
        vault.commit(published, keccak256(abi.encode(answer, player, secret)));
        guesses[player] += 1;
        chapterCommits[published] += 1;
        burns += 100 ether;
        vm.roll(vm.getBlockNumber() + 1);
        vault.reveal(published, answer, secret);
        vm.stopPrank();
        _recordWin(player);
    }

    /// @dev Failed replacements must leave any earlier commitment and its clocks intact.
    function rejectedCommit(uint256 playerSeed, bytes32 secret, bool zeroHash) external {
        if (published == solved) return;
        address player = players[playerSeed % players.length];
        vm.startPrank(player);
        if (zeroHash) {
            vm.expectRevert(SorenVault.InvalidHash.selector);
            vault.commit(published, bytes32(0));
        } else {
            token.approve(address(vault), 100 ether - 1);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IERC20Errors.ERC20InsufficientAllowance.selector, address(vault), 100 ether - 1, 100 ether
                )
            );
            vault.commit(published, keccak256(abi.encode(_answer(published), player, secret)));
            assertEq(token.allowance(player, address(vault)), 100 ether - 1);
        }
        vm.stopPrank();
    }

    function mismatchedReveal(uint256 playerSeed) external {
        if (published == solved) return;
        address player = players[playerSeed % players.length];
        Guess memory guess = _guesses[published][player];
        if (!guess.exists) return;
        // Advance only the block; never move time backwards to revive an expired guess.
        vm.roll(vm.getBlockNumber() + 1);
        bytes4 expected = vm.getBlockTimestamp() > guess.timestamp + 24 hours
            ? SorenVault.RevealExpired.selector
            : SorenVault.CommitmentMismatch.selector;
        vm.expectRevert(expected);
        vm.prank(player);
        vault.reveal(published, guess.correct ? _answer(published) : "incorrect", guess.secret ^ bytes32(uint256(1)));
    }

    function unauthorizedAdmin(uint256 playerSeed, uint256 actionSeed) external {
        address player = players[playerSeed % players.length];
        uint256 action = actionSeed % 4;
        vm.startPrank(player);
        vm.expectRevert(SorenVault.Unauthorized.selector);
        if (action == 0) vault.setToken(address(token));
        else if (action == 1) vault.fund(1);
        else if (action == 2) vault.publishChapter(published + 1, keccak256("unauthorized"), 1, "changed");
        else vault.setHint(published, "changed");
        vm.stopPrank();
    }

    function probeSolvedChapter(uint256 chapterSeed, uint256 playerSeed) external {
        if (solved == 0) return;
        uint256 id = bound(chapterSeed, 1, solved);
        address player = players[playerSeed % players.length];
        vm.startPrank(player);
        vm.expectRevert(SorenVault.ChapterNotOpen.selector);
        vault.commit(id, keccak256("late commit"));
        vm.expectRevert(SorenVault.ChapterNotOpen.selector);
        vault.reveal(id, _answer(id), bytes32(0));
        vm.stopPrank();
        vm.startPrank(owner);
        vm.expectRevert(SorenVault.ChapterNotOpen.selector);
        vault.setHint(id, "rewrite solved history");
        vm.expectRevert(SorenVault.ChapterOutOfOrder.selector);
        vault.publishChapter(id, keccak256("replacement"), 1, "rewrite");
        vm.stopPrank();
    }

    /// @dev Only used by the terminal liveness check; transfers existing supply, never mints/deals.
    function topUpForCompletion(uint256 amount) external {
        require(msg.sender == treasury, "test treasury only");
        vm.prank(treasury);
        token.transfer(players[0], amount);
        topUps[players[0]] += amount;
    }

    function expectedCommitment(uint256 id, address player) external view returns (bytes32, uint256, uint256) {
        Guess memory guess = _guesses[id][player];
        if (!guess.exists) return (bytes32(0), 0, 0);
        string memory answer = guess.correct ? _answer(id) : "incorrect";
        return (keccak256(abi.encode(answer, player, guess.secret)), guess.blockNumber, guess.timestamp);
    }

    function _recordWin(address player) private {
        solved += 1;
        wins[player] += 1;
        paid += prizes[published];
        rewards[player] += prizes[published];
        solvers[published] = player;
        delete _guesses[published][player];
        settledRecords[published] = keccak256(abi.encode(vault.getChapter(published)));
    }

    function _answer(uint256 id) private pure returns (string memory) {
        return string(abi.encodePacked("chapter-answer-", id));
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract SorenVaultInvariantTest is SorenTestBase {
    SorenHandler internal handler;

    function setUp() public override {
        super.setUp();
        _fund(10 * PRIZE);
        handler = new SorenHandler(token, vault, owner, [alice, bob, carol], 10 * PRIZE);
        handler.publishNext(PRIZE);

        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = handler.fund.selector;
        selectors[1] = handler.donate.selector;
        selectors[2] = handler.publishNext.selector;
        selectors[3] = handler.commitGuess.selector;
        selectors[4] = handler.revealGuess.selector;
        selectors[5] = handler.advance.selector;
        selectors[6] = handler.updateHint.selector;
        selectors[7] = handler.solveCurrent.selector;
        selectors[8] = handler.rejectedCommit.selector;
        selectors[9] = handler.mismatchedReveal.selector;
        selectors[10] = handler.unauthorizedAdmin.selector;
        selectors[11] = handler.probeSolvedChapter.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    /// @dev Pin the failure-heavy path so coverage does not depend on random selector ordering.
    function test_sequenceFailuresKeepEarlierPaidGuessUsable() public {
        handler.commitGuess(0, true, SECRET);
        handler.advance(1, 0);
        handler.rejectedCommit(0, keccak256("replacement"), false);
        handler.rejectedCommit(0, keccak256("replacement"), true);
        handler.mismatchedReveal(0);
        for (uint256 action; action < 4; ++action) {
            handler.unauthorizedAdmin(0, action);
        }
        invariant_fundsConservedAndPrizesAlwaysSolvent();
        invariant_individualBalancesMatchTheirOwnActions();
        invariant_commitmentsAndSettledHistorySurviveUnrelatedCalls();
        handler.revealGuess(0);
        assertEq(vault.getChapter(1).solver, alice);
        handler.probeSolvedChapter(1, 0);
        handler.publishNext(PRIZE);
        handler.probeSolvedChapter(1, 1);
        afterInvariant();
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

    /// @dev A burn can only debit the guessing wallet, and only a winning reveal credits a prize.
    function invariant_individualBalancesMatchTheirOwnActions() public view {
        assertEq(token.balanceOf(owner) + handler.ownerFunding(), OWNER_FUNDS);
        address[3] memory players = [alice, bob, carol];
        for (uint256 i; i < players.length; ++i) {
            address player = players[i];
            assertEq(
                token.balanceOf(player) + handler.donations(player) + handler.guesses(player) * COST,
                PLAYER_FUNDS + handler.rewards(player) + handler.topUps(player),
                "player balance is not explained by their deposits, paid guesses and prizes"
            );
        }
        assertEq(vault.owner(), owner);
        assertEq(address(vault.token()), address(token));
    }

    function invariant_commitmentsAndSettledHistorySurviveUnrelatedCalls() public view {
        address[3] memory players = [alice, bob, carol];
        SorenVault.Chapter[7] memory all = vault.getAllChapters();
        for (uint256 id = 1; id <= 7; ++id) {
            assertEq(keccak256(abi.encode(vault.getChapter(id))), keccak256(abi.encode(all[id - 1])));
            if (id <= handler.solved()) {
                assertEq(keccak256(abi.encode(vault.getChapter(id))), handler.settledRecords(id));
            }
            for (uint256 i; i < players.length; ++i) {
                (bytes32 hash, uint256 committedBlock, uint256 timestamp) = vault.commitments(id, players[i]);
                (bytes32 expectedHash, uint256 expectedBlock, uint256 expectedTime) =
                    handler.expectedCommitment(id, players[i]);
                assertEq(hash, expectedHash, "commitment changed without a paid commit or successful reveal");
                assertEq(committedBlock, expectedBlock);
                assertEq(timestamp, expectedTime);
            }
        }
    }

    /// @dev After EVERY random sequence, valid fresh guesses can still finish all seven chapters.
    function afterInvariant() public {
        handler.topUpForCompletion(7 * COST + 7);
        while (handler.solved() < 7) {
            if (handler.published() == handler.solved()) {
                if (handler.deposits() == handler.paid()) handler.donate(0, 1);
                handler.publishNext(PRIZE);
            }
            handler.solveCurrent(0, keccak256(abi.encode("completion", handler.published())));
        }
        assertEq(vault.chaptersSolved(), 7);
        assertEq(vault.reservedPrizes(), 0);
        invariant_fundsConservedAndPrizesAlwaysSolvent();
        invariant_onlyOneOpenChapterAndSequentialWinners();
        invariant_playerRecordsMatchPaidGuessesAndWins();
        invariant_individualBalancesMatchTheirOwnActions();
        invariant_commitmentsAndSettledHistorySurviveUnrelatedCalls();
    }
}
