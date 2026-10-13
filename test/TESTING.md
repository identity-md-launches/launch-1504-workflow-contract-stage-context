# Contract test coverage

Run `forge build` and `forge test` from the repository root. Tests use the vendored
dependencies and local EVM; they need no network, environment changes, forks, or keys.
Only files under `test/` are changed by this contribution.

The existing administration, game, adversarial-token, and deployment suites remain
in place. The added coverage is:

| Suite | Properties checked |
| --- | --- |
| `SorenVaultBoundaries.t.sol` | One-wei prizes through all seven chapters; exhaustion and refill; the whole supply less one commit fee as a prize; maximum integer rejection; allowance rollback when funding or a replacement commit fails; reveal with zero remaining player balance/allowance; stale commitments after the next chapter opens; exact payout and rejected-hint fuzzing. |
| `LaunchTokenInvariant.t.sol` | A separate balance and allowance ledger across four actors and two passive sinks. Random approval, transfer, delegated transfer, revocation, and rejected spends must preserve the fixed supply, each balance, and each allowance. Explicit examples pin zero, full supply, self-transfer, infinite approval, and failed allowance consumption. |
| `SorenVaultInvariant.t.sol` | Extends the existing handler with failed replacements, mismatched reveals, unauthorized administration, attempts to reopen settled chapters, and successful settlement. Adds per-player balance equations, commitment hash/block/time checks, agreement between chapter views, and immutable settled records. |

Both invariant campaigns use 256 runs of 96 calls, with unexpected reverts treated
as failures. Expected rejection paths check their exact error. The vault boundary
properties use 1,000 fuzz cases each. Settings are inline in the test files.

The vault handler maintains an independent ledger of actual funding, donations,
paid guesses, and successful prizes. It checks that holdings plus paid prizes equal
deposits; that each player's balance is explained by their own actions; that burn
and win records agree with the ledger; and that a failed call cannot change an
earlier commitment or settled chapter. These follow the approved funding,
100-SORN-per-commit, first-solver, and sequential-chapter requirements.

After each random vault sequence, `afterInvariant` supplies the first player with
enough existing tokens for seven new guesses and, if needed, seven one-wei prize
donations. It then completes all remaining chapters using fresh commits and later
blocks and rechecks every invariant. This tests recovery and completion after the
adversarial sequence. The top-up is a transfer from the deployment supply and is
recorded in the ledger; token balances are never fabricated. A deterministic test
also pins the failed-replacement sequence before this completion check.

The token supply invariant uses passive sink balances as part of total supply:
sending SORN to the burn address does not reduce ERC-20 `totalSupply`. The vault's
`totalBurned` tracks only its paid guesses, not unrelated token transfers.

The custody invariants use the actual `LaunchToken`. The existing adversarial-token
suite separately checks SafeERC20 conventions, rejected transfer fees, rollback,
and reentrancy. Passing these tests does not establish that an arbitrary
owner-selected token is safe, that puzzle answers are difficult to guess offline,
or that a launch manifest is valid. Those are outside these test properties.
