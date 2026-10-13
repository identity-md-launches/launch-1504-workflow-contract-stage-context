# Security assumptions and local validation

This is the implementer's handoff for independent review. It is not an independent audit, launch admission, or signed attestation. Review must inspect the accepted source and final manifest, including the owner argument and deployed token identity.

## Trust and fairness

**Owner trust is part of this hunt.** The immutable owner chooses the token once, all correct-answer hashes, prizes, puzzle texts, publication times, and hints. The owner can stall publication or publish an impossible answer and cannot repair a published chapter. Key loss can halt future chapters. There is no administrative recovery or upgrade. A wrong token setting cannot be corrected; code/18-decimal checks are not an identity check.

The owner already knows the answers and is not barred from guessing. The owner, another wallet they control, or someone they tell can make a paid commitment and win. Excluding the owner address would not prevent collaborators. The contract provides no owner withdrawal function, but cannot guarantee that payouts go to independent solvers. This is explicitly covered by a participation test, not hidden behind the “no withdrawal” description.

The public `answerHash = keccak256(bytes(answer))` is an **unsalted answer hash**, as specified. It permits free offline dictionary/brute-force testing. It does not encrypt the answer or enforce a fee on offchain guesses. Easy answers may be discovered before a player commits. The transmission string itself is public; any puzzle encryption happens within the owner's authored content.

Sender binding prevents a different wallet from copying a commitment/reveal and using its preimage in the same transaction/block to win. A copied commitment hash is still bound to the original sender, and a newly constructed attacker commitment must wait for another block. **This is not protection against censorship, delayed inclusion, or all cross-block MEV.** After a plaintext reveal becomes visible, an attacker could commit their own guess and reveal in a later block if the honest reveal is kept pending. Both known-answer commitments also race under ordinary transaction ordering. A public one-block commit/reveal rule cannot promise an uncensorable first solver. Players should minimize reveal delay; the frontend must not describe this as absolute front-running immunity.

## Custody and accounting

- Standard immutable SORN is the supported asset. ERC-20 balances and allowance checks come from that token, not an oracle. A malicious or mutable alternative can lie about balances or confiscate funds despite SafeERC20 and balance checks; the owner must select the verified launch token.
- A positive, already-funded prize is reserved when a chapter opens. Only the first valid reveal transfers that prize. The next chapter cannot open until the previous settlement succeeds. After each successful payout, the reserve falls to zero.
- Every paid commit pulls 100 SORN directly from its caller to the specified dead address. The vault never burns prize funds, forwards burns to the owner, or approves a spender on its own balance. The burn metric counts transfers made by this vault, not all token transfers to that address. The launch token's supply remains fixed.
- SafeERC20 accepts successful empty-return token operations and rejects false-return operations. Sender and recipient balance deltas must equal the requested amount. The tests use unsupported token variants solely to exercise those failure paths.
- All mutating entry points are guarded. Commit and settlement accounting is updated before token transfer calls; any failed transfer or balance check reverts the whole transaction. A payout failure leaves the chapter open and commitment reusable until its original expiry. With standard SORN, holders cannot block incoming transfers.
- Wrong, expired, replaced, and losing guesses have no refunds. A chapter has no global timeout. Excess funding and unsolved prizes can be permanently locked. There is no native ETH receiver, rescue, arbitrary call, token approval, cancellation, withdrawal, pause, ownership transfer, or upgrade entry point. Forced ETH or unrelated ERC-20 transfers cannot be recovered.

## Local evidence

| Suite | Coverage |
| --- | --- |
| `LaunchToken.t.sol` | Fixed supply/metadata, exact transfers, allowance/balance failures, no common administrative entry points, supply unchanged by dead-address transfers. |
| `SorenVaultAdmin.t.sol` | Explicit owner, unset/set-once token, invalid token/decimals, funding, donations, chapter order, immutable published fields, byte limits, hints, withdrawal/approval/upgrade absence, native ETH rejection. |
| `SorenVaultGame.t.sol` | Burn records, insufficient funds/allowance, replacement rollback, timing/expiry boundaries, copied commitments and reveals, wrong guesses/secrets/encoding, single winner, seven chapters, owner participation, exact-byte answers, fund conservation. |
| `SorenVaultAdversarial.t.sol` | False/reverting/no-return/no-movement/fee transfers, payout retry, reentrant callbacks into every mutation, atomic rollback. |
| `LaunchCompatibility.t.sol` | Factory-style deployment, untouched factory supply, explicit owner without code, unset token dependency, EIP-170 runtime size, scan for forbidden opcodes while skipping PUSH data. |
| `SorenVaultInvariant.t.sol` | Independent deposit/payout/burn ledger, token conservation, reserved-prize solvency, one open chapter, sequential permanent winners, exact per-player and chapter statistics. |

Four parameterized fuzz tests run 256 cases each by default. The stateful suite runs 128 sequences of up to 64 actions, interleaving owner funding, player donations, publication, correct/wrong guesses, hints, reveals, and independent time/block advancement. Handler expectations distinguish same-block, expired, wrong-answer, and missing-commit failures. Unexpected action reverts fail the invariant run. A deterministic seven-chapter unit test also covers completion, regardless of random sequence reachability.

The supplied protected tests were read as the deployment/token baseline. They require verifier-controlled environment values and are not copied into local environment-dependent tests. Local compatibility tests exercise their constructor, supply, runtime size, and opcode constraints directly. The actual protected run, signed artifact/policy linkage, manifest review, source publication, and deployment are the services' responsibilities.

Foundry build/test/format and ABI parity checks are the local checks for this contribution. Slither, Mythril, live-chain integration tests, external publication, and a separate adversarial contributor review are not claimed. No keys, broadcasts, fork RPCs, FFI, filesystem permissions, or environment mutations are used by project tests.
