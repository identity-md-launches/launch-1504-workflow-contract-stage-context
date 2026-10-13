# SOREN contracts

SOREN is a seven-chapter onchain mystery hunt. Each paid guess sends 100 SORN to the specified burn address. The first wallet to reveal a correct, timely, sender-bound commitment receives that chapter's funded prize.

This contribution delivers the contracts, tests, vendored dependencies, and ABI documentation for the contract stage. The separate manifest assignment produces `launch.json`; independent review and the services' source publication, attestation, admission, deployment, and frontend work follow this contribution.

## Build and check

From the repository root, with Foundry and Solidity 0.8.26 installed:

```sh
forge build
forge test
forge fmt --check
python3 scripts/export_abi.py --check
```

`foundry.toml` pins Solidity **0.8.26**, Cancun EVM output, optimizer with 200 runs, and `bytecode_hash = "none"`. All Solidity dependencies are ordinary files under `lib/`; builds and tests require no network, RPC, environment values, wallets, FFI, or filesystem cheatcode permissions. No submodules or package installation are needed. The verifier supplies the pinned compiler; no compiler binary is included here.

OpenZeppelin Contracts **v5.0.2** (the required source subset) and forge-std **v1.9.7** are vendored with their licenses. [Dependency provenance](docs/dependencies.json) records download URLs and SHA-256 hashes for each unmodified file. Regenerate the ABIs after a source change with `python3 scripts/export_abi.py`.

## Contracts and launch parameters

| Contract | Source | Nonpayable constructor | Purpose |
| --- | --- | --- | --- |
| `LaunchToken` | [src/LaunchToken.sol](src/LaunchToken.sol) | No arguments | Standard Sorn / SORN ERC-20; 18 decimals; exactly `1000000000000000000000000000` minor units minted once to the deploying factory. |
| `SorenVault` | [src/SorenVault.sol](src/SorenVault.sol) | `address initialOwner` = `$owner` | Sequential prize vault; owner configures its token once after launch. |

For the separate manifest step, `$owner` resolves to the supplied owner **`0xee8a3066a7ffd68f902427058cf5dcf706ef6e95`** on **Ethereum, chain ID 1**. Neither the factory nor the launch service is an implicit vault owner. The owner is immutable; there is no ownership transfer or renunciation. Constructors make no external calls and do not require any address to have code. Both deployed Solidity names are below the 32-character limit. Neither contract has external library links, proxy behavior, upgrades, or deployment-time initialization calls.

The token has no mint function, admin role, pause, blocklist, transfer fee, or upgrade path. The factory handles the launch policy's supply split: **10%** to its MerkleDistributor, **88%** to pool liquidity, and **2%** to the paying wallet (or treasury under the supplied policy). **The vault receives no launch allocation.** Its prizes must be supplied later from acquired SORN.

The launch policy's pool pairs SORN with IMD at `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`, uses fee **12500 (1.25%)**, tick spacing **60**, and manifest `initialPrice` **`"79228162514264337593543950336"`**. The service derives the effective opening price from the policy's **2,500 IMD** opening market cap and actual token ordering. These are handoff parameters, not vault/token fee logic. The factory supplies the MerkleDistributor and initialization guard; this project does not implement them.

## After launch

1. **Owner: verify the deployment handoff and call `SorenVault.setToken(deployedLaunchTokenAddress)`.** Obtain this address from the services' verified launch/deployment record, then confirm it is this launch's `LaunchToken`. The setter is owner-only, emits `TokenSet`, and is permanently locked after success. It rejects an address without code, the vault itself, and a token without 18 decimals. Those checks cannot prove token identity. There is no guessed token constructor argument. Token-dependent actions revert `TokenNotConfigured` until this is done.
2. **Owner: acquire SORN, approve the vault for the desired funding amount, then call `fund(amount)`.** Amounts are in 18-decimal minor units. Funding is irrevocable. `fund` is owner-only; direct SORN transfers from anyone also become irrevocable prize funding. Burns do not add to funding.
3. **Owner: prepare chapter 1's normalized answer locally**, compute `keccak256(bytes(answer))`, and call `publishChapter(1, answerHash, prize, transmission)`. The positive prize must already be in the vault. The transmission may contain at most 2,000 UTF-8 bytes. Never send the plaintext answer in publication calldata or event text.
4. **Owner: publish chapters 2 through 7 one at a time after the prior chapter is solved.** An open chapter's answer, prize, and transmission cannot change. `setHint(id, text)` can set, replace, or clear its hint, up to 500 UTF-8 bytes. The owner controls chapter publication and hints; no automation is assumed.
5. **Players/frontend: follow the two-transaction flow below.** Read authoritative state and block timestamps from Ethereum. Index `Committed` and `Solved` events for leaderboard/discovery, and confirm totals using the views. Use the exact pool key and addresses from the deployment handoff for trading and links.

These are operational actions for the launch owner and users after service deployment. This contribution sends no transactions and requires no signer, key, subscription, oracle, or relayer.

## Game behavior and assumptions

- Chapters have IDs **1–7**, starting `Locked (0)`, becoming `Open (1)` when published, then `Solved (2)` after a successful reveal. There is at most one open chapter. Solving permits the owner to publish the next chapter; it does not publish it automatically.
- Every successful `commit(id, commitHash)` transfers exactly **`100000000000000000000`** minor units from the caller to **`0x000000000000000000000000000000000000dEaD`**, as explicitly required by the workflow. This is the designated burn destination, not a configuration placeholder. ERC-20 `totalSupply()` stays fixed; “burned” means sent to this address.
- A commitment is **`keccak256(abi.encode(answer, playerAddress, secret))`**, with `answer` a string and `secret` a `bytes32`. Use standard ABI encoding, not packed encoding. `playerAddress` must be the wallet that calls both `commit` and `reveal`.
- One active commitment exists per wallet per chapter. **Every replacement, including an identical commit, burns another 100 SORN and resets both clocks.** Old preimages are replaced. Expired commitments may be replaced while the chapter remains open.
- Reveal requires **`block.number > committedBlock`** and **`block.timestamp <= committedTimestamp + 86400`**. The deadline itself is valid. A successful reveal deletes the winner's active commitment, records the solver/time, and pays the entire prize atomically. Other commitments cannot win after settlement.
- A wrong answer reverts `IncorrectAnswer`; a preimage/address/secret mismatch reverts `CommitmentMismatch`. Failed reveals burn no additional tokens and return no previous burn. The stored wrong guess remains bound to that one answer; changing the guess requires a new paid commitment.
- Per-wallet `guesses` counts successful paid commits, including replacements, expired attempts, wrong guesses, and losing commitments. Per-chapter `commits` and all burned counters follow the same rule. Failed transactions change none of these counters.
- Frontend normalization is **lowercase, trim, remove whitespace**, performed identically for the owner and players before hashing. Onchain comparison uses the exact string bytes and does not normalize. Choose unambiguous answers; the ABI guide gives integration details.
- Funding, burning, and payouts use OpenZeppelin `SafeERC20`, balance-delta checks, and `ReentrancyGuard`. Failed token operations roll back all associated state. Only the supplied standard SORN token is supported; fee/rebasing/malicious alternatives are not supported configuration choices.

There is **no administrative withdrawal, rescue, cancellation, refund, pause, token replacement, or upgrade**. Unallocated excess, mistaken token transfers, and prizes for an unsolved/impossible chapter may remain locked forever, including excess after chapter 7. Fund deliberately. The owner knows the answers and may participate like any wallet; they or a collaborator can pay the commit cost and claim a prize. “No owner withdrawal” means no administrative withdrawal route, not that the owner is excluded from the game. See [security assumptions and limits](docs/SECURITY.md).

## Integration and validation

Machine-readable exports: [LaunchToken ABI](docs/abi/LaunchToken.json), [SorenVault ABI](docs/abi/SorenVault.json). [ABI and frontend guide](docs/ABI.md) documents structs, views, errors, events, and secret recovery.

The test suites cover token supply/transfers, owner and configuration restrictions, chapter ordering, text limits, all reveal timing boundaries, copied commitments/reveals, repeated and failed guesses, all seven settlements, withdrawal absence, failed/false/no-return/taxed token operations, reentrancy, constructor compatibility, runtime size, and forbidden opcodes. Fuzz tests exercise transfer amounts, arbitrary answers/secrets, paid guess counts, and timing. Three stateful invariants reconcile funding/payouts/burns, sequential chapter state, and player records over randomized action sequences.

Tests are local validation, not an independent audit or service attestation. Independent source/manifest review remains a separate stage before release. No Slither or Mythril analysis, mainnet transactions, publication, or independent launch-manifest review is claimed here.
