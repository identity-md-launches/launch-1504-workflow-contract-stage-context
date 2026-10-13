// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "src/LaunchToken.sol";

/// @dev All movement uses the real fixed supply. The two sink accounts never act as senders.
contract LaunchTokenLedgerHandler is Test {
    LaunchToken public immutable token;
    address[6] public accounts;
    mapping(address => uint256) public balances;
    mapping(address => mapping(address => uint256)) public allowances;

    constructor(LaunchToken token_, address[4] memory actors) {
        token = token_;
        for (uint256 i; i < actors.length; ++i) {
            accounts[i] = actors[i];
            balances[actors[i]] = 250_000_000 ether;
        }
        accounts[4] = 0x000000000000000000000000000000000000dEaD;
        accounts[5] = address(token_);
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = accounts[fromSeed % 4];
        address to = accounts[toSeed % 6];
        uint256 amount = bound(amountSeed, 0, balances[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        balances[from] -= amount;
        balances[to] += amount;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        _approve(accounts[ownerSeed % 4], accounts[spenderSeed % 4], amount);
    }

    function transferFrom(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address spender = accounts[spenderSeed % 4];
        address from = accounts[fromSeed % 4];
        address to = accounts[toSeed % 6];
        uint256 allowance = allowances[from][spender];
        uint256 limit = balances[from] < allowance ? balances[from] : allowance;
        uint256 amount = bound(amountSeed, 0, limit);
        vm.prank(spender);
        assertTrue(token.transferFrom(from, to, amount));
        if (allowance != type(uint256).max) allowances[from][spender] -= amount;
        balances[from] -= amount;
        balances[to] += amount;
    }

    function rejectedTransfer(uint256 fromSeed, uint256 toSeed) external {
        address from = accounts[fromSeed % 4];
        address to = accounts[toSeed % 6];
        uint256 balance = balances[from];
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, balance + 1)
        );
        vm.prank(from);
        token.transfer(to, balance + 1);
    }

    function rejectedTransferFrom(uint256 fromSeed, uint256 spenderSeed, bool missingAllowance) external {
        address from = accounts[fromSeed % 4];
        address spender = accounts[spenderSeed % 4];
        uint256 amount;
        if (missingAllowance) {
            _approve(from, spender, 0);
            amount = 1;
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        } else {
            // A finite allowance is spent before ERC20 checks the balance. It must roll back.
            amount = balances[from] + 1;
            _approve(from, spender, amount);
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balances[from], amount)
            );
        }
        vm.prank(spender);
        token.transferFrom(from, accounts[4], amount);
    }

    function approveAndSpend(uint256 fromSeed, uint256 spenderSeed, uint256 toSeed, uint256 seed, bool infinite)
        external
    {
        address from = accounts[fromSeed % 4];
        address spender = accounts[spenderSeed % 4];
        address to = accounts[toSeed % 6];
        uint256 amount = bound(seed, 0, balances[from]);
        _approve(from, spender, infinite ? type(uint256).max : amount);
        vm.prank(spender);
        assertTrue(token.transferFrom(from, to, amount));
        if (!infinite) allowances[from][spender] = 0;
        balances[from] -= amount;
        balances[to] += amount;
    }

    function _approve(address from, address spender, uint256 amount) private {
        vm.prank(from);
        assertTrue(token.approve(spender, amount));
        allowances[from][spender] = amount;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract LaunchTokenInvariantTest is Test {
    LaunchToken internal token;
    LaunchTokenLedgerHandler internal handler;
    uint256 private constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        token = new LaunchToken();
        address[4] memory actors =
            [address(this), makeAddr("token-alice"), makeAddr("token-bob"), makeAddr("token-carol")];
        for (uint256 i = 1; i < actors.length; ++i) {
            token.transfer(actors[i], SUPPLY / 4);
        }
        handler = new LaunchTokenLedgerHandler(token, actors);
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.rejectedTransfer.selector;
        selectors[4] = handler.rejectedTransferFrom.selector;
        selectors[5] = handler.approveAndSpend.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_fixedSupplyAndEveryAccountBalanceMatchLedger() public view {
        uint256 total;
        for (uint256 i; i < 6; ++i) {
            address account = handler.accounts(i);
            uint256 actual = token.balanceOf(account);
            assertEq(actual, handler.balances(account), "unexplained account balance change");
            total += actual;
        }
        assertEq(total, SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
    }

    function invariant_allowancesChangeOnlyByApprovalOrSuccessfulSpend() public view {
        for (uint256 i; i < 4; ++i) {
            for (uint256 j; j < 4; ++j) {
                address from = handler.accounts(i);
                address spender = handler.accounts(j);
                assertEq(token.allowance(from, spender), handler.allowances(from, spender));
            }
        }
    }
}

contract LaunchTokenBoundaryTest is Test {
    LaunchToken internal token;
    address internal alice;
    address internal bob;
    uint256 private constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        token = new LaunchToken();
        alice = makeAddr("boundary-alice");
        bob = makeAddr("boundary-bob");
    }

    function test_entireSupplyRoundTripAndSelfTransfer() public {
        token.transfer(alice, SUPPLY);
        vm.startPrank(alice);
        token.transfer(alice, SUPPLY);
        assertEq(token.balanceOf(alice), SUPPLY);
        token.transfer(address(this), SUPPLY);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroTransfersNeedNoBalanceOrAllowance() public {
        vm.startPrank(alice);
        assertTrue(token.transfer(bob, 0));
        assertTrue(token.transferFrom(bob, alice, 0));
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.allowance(bob, alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_infiniteAllowanceSurvivesFullSupplySpendAndCanBeRevoked() public {
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(address(this), bob, SUPPLY);
        assertEq(token.allowance(address(this), alice), type(uint256).max);
        vm.prank(bob);
        token.transfer(address(this), SUPPLY);
        token.approve(alice, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transferFrom(address(this), bob, 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_selfTransferFromSpendsFiniteAllowanceWithoutMovingBalance() public {
        token.approve(alice, SUPPLY);
        vm.prank(alice);
        token.transferFrom(address(this), address(this), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.allowance(address(this), alice), 0);
    }

    function test_failedOverspendRestoresFiniteAllowance() public {
        token.approve(alice, type(uint256).max - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, SUPPLY + 1)
        );
        vm.prank(alice);
        token.transferFrom(address(this), bob, SUPPLY + 1);
        assertEq(token.allowance(address(this), alice), type(uint256).max - 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_zeroReceiverAndSpenderRejectWithoutUsingAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
        token.approve(alice, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(alice);
        token.transferFrom(address(this), address(0), 1);
        assertEq(token.allowance(address(this), alice), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
    }
}
