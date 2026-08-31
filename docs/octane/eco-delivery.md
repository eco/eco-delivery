# Octane context — `eco/eco-delivery` (the scan target itself)

Context for the primary repository, in the same three fields as a linked repo. This is the one that
does the work of suppressing false positives: nearly every static-analysis heuristic that fires on
this contract fires on something deliberate.

---

## General codebase description

`eco-delivery` is a single-purpose **outcome verifier**, implemented twice: once for EVM
(Foundry/Solidity, `evm/src/Deliver.sol`, 38 lines of code) and once for SVM/Solana (Anchor/Rust,
`solana/programs/deliver`, 118 lines). The two are intended to be behaviourally identical and their
divergences are enumerated in `PARITY.md`.

The primitive is: deliver tokens the contract is **already holding** to a recipient, and revert
unless the amount held meets a caller-supplied minimum.

```solidity
function deliverToken(IERC20 token, address recipient, uint256 min) external {
    uint256 balance = token.balanceOf(address(this));
    require(balance >= min, "deliver: balance below min");
    token.safeTransfer(recipient, balance);
}
```

It is designed as the **last step of a swap route**: any number of untrusted providers (aggregator,
AMM hop, RFQ fill) produce output into this contract, and the floor is enforced once, at the end, on
whatever actually arrived. The contract performs no swap, pulls no funds in, and knows nothing about
how the balance got there. `deliverNative` / `deliver_sol` do the same for native value. A
TypeScript SDK (`ts/`, `@eco-foundation/delivery`, unpublished) ships call builders whose ABI and IDL
are generated from the contract build output.

The EVM contract is deployed, unaudited, to 12 mainnets at
`0xAd8a3c3745633280FaFb0f44D0C2cc2c48475673` (identical address on every chain, via CreateX CREATE2
with an unguarded salt, so anyone can reproduce it on a new chain). The Solana program is deployed to
mainnet-beta as `EcoyzRRwsSsFz6i4YU6r28WGD9mamCtRi4Zc8w78FNjw` and is currently **upgradeable** —
unlike the EVM contract, which has no upgrade path. Nothing is audited.

## Review relevance

The entire contract is three operations — read own balance, compare to a floor, forward everything —
so the interesting questions are not about the arithmetic. They are about whether the trust model
holds:

- Can `min` be bypassed, or the balance moved to an address the caller did not name?
- Can the native path be reached unintentionally, or made to strand value rather than revert?
- On SVM, can a caller substitute the mint, the vault ATA, the recipient ATA, or the token program?
  Is the PDA seed derivation and signing correct?
- Does anything persist between calls that shouldn't — storage, approvals, delegates, authorities?

Test coverage is 57 EVM tests (including 4096-run fuzzing), 23 SVM tests (including 768 proptest
cases), and 10 SDK tests. The security-relevant behaviours are pinned by name in the README.

## Integration assumptions

**Read this before filing findings.** This contract deliberately violates a long list of common
static-analysis expectations. Each item below is an intentional, documented design decision, stated
in `README.md` (`## Security notes`) and in the NatSpec of `evm/src/Deliver.sol` /
`solana/programs/deliver/src/lib.rs`, and pinned by tests. **None of them is a defect.**

- **No access control.** No owner, no admin, no allowlist, no pause, no upgrade path. Anyone may
  call. This is the point: safety comes entirely from the caller binding `(token, recipient, min)`
  upstream — typically an intent/settlement system. Access control here would not add safety, only
  relocate the trust assumption.
- **No storage.** The contract is a pass-through, not a vault.
- **The recipient is never validated**, `address(0)` / `Pubkey::default()` included. A wrong
  recipient burns the funds with no recovery path. That is the caller's bug by design.
- **The entire balance is swept.** There is deliberately no `amount` parameter, and pre-existing
  dust is included. "Whatever arrived is what gets delivered" is the primitive.
- **A stranded balance is claimable by anyone**, for a recipient of their choosing. Not a
  vulnerability — the intended consequence of being stateless and permissionless, and the reason
  funding and delivery **must** be in one transaction. Pinned by
  `test_AnyoneCanDivertAStrandedBalance`.
- **`address(0)` is a native-ETH sentinel on EVM**, alongside
  `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE`. An unset `token` field therefore sweeps ETH instead
  of reverting. This is a knowingly accepted hazard, pinned by
  `test_Hazard_UninitializedTokenSweepsEthInsteadOfReverting`. It is accepted for compatibility with
  protocols that encode native ETH as the zero address rather than as `0xEeee...`, so the same
  `(token, recipient, min)` tuple works from either convention. Flag it only if you find a *caller*
  path where an attacker-influenced field reaches it. There is no SVM analogue — `deliver_token`
  takes a mint account and cannot be steered into a lamport sweep.
- **The native send forwards all remaining gas** via a raw `call` and reverts on failure. Fail-closed
  is intended; a swallowed failure would report a delivery that did not happen.
- **No reentrancy guard.** The transfer is the last action, no storage is written, and a re-entrant
  hook or recipient finds a zero balance — so it either no-ops (`min == 0`) or reverts. Six tests
  exercise this rather than asserting it. On SVM the class is structurally absent.
- **No events.** On the ERC-20 path the token's own `Transfer` log carries `(recipient, amount)`.
  On the **native** path nothing is emitted at all, so native deliveries are trace-only — a known
  asymmetry, documented, not an oversight.
- **A zero balance with `min == 0` succeeds as a no-op** on both VMs rather than reverting.
- **SVM `init_if_needed`** on the recipient ATA charges the permissionless caller unrefunded rent.
  The ATA constraints pin mint, authority and token program, so the usual re-initialization concern
  does not apply.
- **SVM Token-2022 `TransferHook` mints fail outright** — `transfer_checked` forwards only its four
  accounts. Fail-closed and documented as out of scope. `TransferFee` mints are supported and tested.

**The one genuine, known hole**, which does not need rediscovering: `min` is checked against the
balance held **before** the transfer, never against what the recipient receives. A fee-on-transfer,
rebasing, or Token-2022 `TransferFee` asset can pass the check while the recipient is credited
strictly less than `min`, and the call succeeds. Accepted deliberately, documented beside the
headline guarantee in the README, and pinned on both VMs by
`test_Hole_FeeOnTransferTokenCanDeliverLessThanMin` and
`deliver_token_token2022_transfer_fee_recipient_gets_less_than_min`. The SDK's `minForTarget`
divides by `(1 − fee)` to compensate. A finding here is only useful if it identifies a *new*
consequence, not the hole itself.

**Genuinely in scope**, and where a real finding would live: any path that moves funds to an address
the caller did not name; any way to satisfy the floor check without the balance actually being
present; incorrect PDA derivation, bump handling, or signer seeds on SVM; account substitution that
survives the Anchor constraints; a native send that strands value instead of reverting; and any
state or authority that outlives a call on either VM.
