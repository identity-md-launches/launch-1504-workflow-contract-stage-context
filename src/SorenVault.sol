// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Seven sequential, funded puzzles with paid, sender-bound commit/reveal guesses.
/// @dev Only the standard 18-decimal SORN launch token is supported. No withdrawal, upgrade,
///      ownership transfer, chapter cancellation, or modification of a published answer/prize exists.
contract SorenVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant CHAPTER_COUNT = 7;
    uint256 public constant COMMIT_COST = 100 * 10 ** 18;
    uint256 public constant REVEAL_WINDOW = 24 hours;
    uint256 public constant MAX_TRANSMISSION_BYTES = 2_000;
    uint256 public constant MAX_HINT_BYTES = 500;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    enum Status {
        Locked,
        Open,
        Solved
    }

    struct Chapter {
        Status status;
        address solver;
        uint256 solvedAt;
        uint256 prize;
        uint256 commits;
        uint256 burned;
        bytes32 answerHash;
        string transmission;
        string hint;
    }

    struct PlayerStats {
        uint256 guesses;
        uint256 burned;
        uint256 chaptersSolved;
    }

    struct Commitment {
        bytes32 commitHash;
        uint256 blockNumber;
        uint256 timestamp;
    }

    address public immutable owner;
    IERC20 public token;
    uint256 public lastPublishedChapter;
    uint256 public chaptersSolved;
    uint256 public reservedPrizes;
    uint256 public totalPrizesPaid;
    uint256 public totalBurned;

    mapping(uint256 id => Chapter) private _chapters;
    mapping(address player => PlayerStats) public playerStats;
    mapping(uint256 id => mapping(address player => Commitment)) public commitments;

    error Unauthorized();
    error InvalidOwner();
    error TokenNotConfigured();
    error TokenAlreadySet();
    error InvalidToken();
    error InvalidAmount();
    error InvalidChapter();
    error ChapterOutOfOrder();
    error PreviousChapterUnsolved();
    error ChapterNotOpen();
    error InvalidHash();
    error TransmissionTooLong();
    error HintTooLong();
    error InsufficientFunding();
    error NoCommitment();
    error RevealTooEarly();
    error RevealExpired();
    error CommitmentMismatch();
    error IncorrectAnswer();
    error UnexpectedTokenAmount();

    event TokenSet(address indexed token);
    event Funded(address indexed funder, uint256 amount);
    event ChapterPublished(uint256 indexed id, bytes32 answerHash, uint256 prize, string transmission);
    event HintPosted(uint256 indexed id, string text);
    event Committed(
        uint256 indexed id,
        address indexed player,
        bytes32 commitHash,
        uint256 blockNumber,
        uint256 timestamp,
        uint256 burned
    );
    event Solved(uint256 indexed id, address indexed solver, uint256 prize);

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    /// @param initialOwner The launch's explicit $owner, never implicitly the deploying factory.
    /// @dev Performs no external calls and requires no previously deployed dependency.
    constructor(address initialOwner) {
        if (initialOwner == address(0) || initialOwner == address(this)) revert InvalidOwner();
        owner = initialOwner;
    }

    /// @notice Permanently select the deployed SORN token. Verify its address before calling.
    /// @dev Code/decimals validation is a sanity check, not proof of token identity or behavior.
    function setToken(address tokenAddress) external nonReentrant onlyOwner {
        if (address(token) != address(0)) revert TokenAlreadySet();
        if (tokenAddress.code.length == 0 || tokenAddress == address(this)) revert InvalidToken();
        try IERC20Metadata(tokenAddress).decimals() returns (uint8 decimals) {
            if (decimals != 18) revert InvalidToken();
        } catch {
            revert InvalidToken();
        }
        token = IERC20(tokenAddress);
        emit TokenSet(tokenAddress);
    }

    /// @notice Irrevocably fund prizes from the owner's approved SORN balance.
    function fund(uint256 amount) external nonReentrant onlyOwner {
        _requireToken();
        if (amount == 0) revert InvalidAmount();
        _transferFromExact(msg.sender, address(this), amount);
        emit Funded(msg.sender, amount);
    }

    /// @notice Publish the next chapter after its predecessor has been solved.
    /// @param answerHash keccak256(bytes(answer)), using the frontend's normalized answer.
    /// @param prize Amount of SORN in minor units, already in the vault and not reserved.
    function publishChapter(uint256 id, bytes32 answerHash, uint256 prize, string calldata transmission)
        external
        nonReentrant
        onlyOwner
    {
        _requireToken();
        _requireChapter(id);
        if (id != lastPublishedChapter + 1) revert ChapterOutOfOrder();
        if (id > 1 && _chapters[id - 1].status != Status.Solved) revert PreviousChapterUnsolved();
        if (answerHash == bytes32(0)) revert InvalidHash();
        if (prize == 0) revert InvalidAmount();
        if (bytes(transmission).length > MAX_TRANSMISSION_BYTES) revert TransmissionTooLong();
        if (token.balanceOf(address(this)) < reservedPrizes + prize) revert InsufficientFunding();

        Chapter storage chapter = _chapters[id];
        chapter.status = Status.Open;
        chapter.answerHash = answerHash;
        chapter.prize = prize;
        chapter.transmission = transmission;
        reservedPrizes += prize;
        lastPublishedChapter = id;

        emit ChapterPublished(id, answerHash, prize, transmission);
    }

    /// @notice Set, replace, or clear the hint for the currently open chapter.
    function setHint(uint256 id, string calldata text) external nonReentrant onlyOwner {
        _requireOpen(id);
        if (bytes(text).length > MAX_HINT_BYTES) revert HintTooLong();
        _chapters[id].hint = text;
        emit HintPosted(id, text);
    }

    /// @notice Burn 100 SORN and commit to keccak256(abi.encode(answer, msg.sender, secret)).
    /// @dev A new commit replaces this wallet's prior commit for this chapter, charges again,
    ///      and restarts both timing limits. Burns are never taken from the prize pool.
    function commit(uint256 id, bytes32 commitHash) external nonReentrant {
        _requireToken();
        _requireOpen(id);
        if (commitHash == bytes32(0)) revert InvalidHash();

        commitments[id][msg.sender] = Commitment(commitHash, block.number, block.timestamp);
        Chapter storage chapter = _chapters[id];
        chapter.commits += 1;
        chapter.burned += COMMIT_COST;
        PlayerStats storage player = playerStats[msg.sender];
        player.guesses += 1;
        player.burned += COMMIT_COST;
        totalBurned += COMMIT_COST;

        _transferFromExact(msg.sender, BURN_ADDRESS, COMMIT_COST);
        emit Committed(id, msg.sender, commitHash, block.number, block.timestamp, COMMIT_COST);
    }

    /// @notice Reveal in a later block, at or before commitment.timestamp + 24 hours.
    /// @dev A wrong answer reverts without a refund; the commit binds a single guess. The first
    ///      successful reveal settles atomically. Failed payouts revert every settlement effect.
    function reveal(uint256 id, string calldata answer, bytes32 secret) external nonReentrant {
        _requireToken();
        _requireOpen(id);
        Commitment memory commitment = commitments[id][msg.sender];
        if (commitment.commitHash == bytes32(0)) revert NoCommitment();
        if (block.number <= commitment.blockNumber) revert RevealTooEarly();
        // The workflow deliberately defines expiry using elapsed wall-clock time.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > commitment.timestamp + REVEAL_WINDOW) revert RevealExpired();
        if (keccak256(abi.encode(answer, msg.sender, secret)) != commitment.commitHash) revert CommitmentMismatch();

        Chapter storage chapter = _chapters[id];
        if (keccak256(bytes(answer)) != chapter.answerHash) revert IncorrectAnswer();

        uint256 prize = chapter.prize;
        chapter.status = Status.Solved;
        chapter.solver = msg.sender;
        chapter.solvedAt = block.timestamp;
        delete commitments[id][msg.sender];
        playerStats[msg.sender].chaptersSolved += 1;
        chaptersSolved += 1;
        reservedPrizes -= prize;
        totalPrizesPaid += prize;

        _transferPrizeExact(msg.sender, prize);
        emit Solved(id, msg.sender, prize);
    }

    function getChapter(uint256 id) external view returns (Chapter memory) {
        _requireChapter(id);
        return _chapters[id];
    }

    /// @notice Index 0 is chapter 1; unpublished chapters have Locked status and empty fields.
    function getAllChapters() external view returns (Chapter[7] memory chapters) {
        for (uint256 i; i < CHAPTER_COUNT; ++i) {
            chapters[i] = _chapters[i + 1];
        }
    }

    /// @notice All SORN currently in the vault, including direct donations and reserved prizes.
    function prizeBalance() public view returns (uint256) {
        _requireToken();
        return token.balanceOf(address(this));
    }

    /// @notice Funding available for future chapters. No one can withdraw this amount.
    function availablePrizes() external view returns (uint256) {
        return prizeBalance() - reservedPrizes;
    }

    function _requireToken() private view {
        if (address(token) == address(0)) revert TokenNotConfigured();
    }

    function _requireChapter(uint256 id) private pure {
        if (id == 0 || id > CHAPTER_COUNT) revert InvalidChapter();
    }

    function _requireOpen(uint256 id) private view {
        _requireChapter(id);
        if (_chapters[id].status != Status.Open) revert ChapterNotOpen();
    }

    function _transferFromExact(address from, address to, uint256 amount) private {
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        token.safeTransferFrom(from, to, amount);
        uint256 fromAfter = token.balanceOf(from);
        uint256 toAfter = token.balanceOf(to);
        if (
            fromAfter > fromBefore || fromBefore - fromAfter != amount || toAfter < toBefore
                || toAfter - toBefore != amount
        ) {
            revert UnexpectedTokenAmount();
        }
    }

    function _transferPrizeExact(address to, uint256 amount) private {
        uint256 vaultBefore = token.balanceOf(address(this));
        uint256 toBefore = token.balanceOf(to);
        token.safeTransfer(to, amount);
        uint256 vaultAfter = token.balanceOf(address(this));
        uint256 toAfter = token.balanceOf(to);
        if (
            vaultAfter > vaultBefore || vaultBefore - vaultAfter != amount || toAfter < toBefore
                || toAfter - toBefore != amount
        ) revert UnexpectedTokenAmount();
    }
}
