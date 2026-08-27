# eco-delivery — a dual-VM outcome verifier

A minimal contract that **delivers tokens it is already holding** to a recipient, and reverts unless
the delivered amount meets a caller-supplied minimum. One implementation for EVM
(Foundry/Solidity), one for SVM/Solana (Anchor/Rust). They are two encodings of the same primitive
and are meant to be reasoned about together.

> **Not audited, not deployed.** Nothing here claims otherwise.

---

## The primitive

```solidity
function deliverToken(IERC20 token, address recipient, uint256 min) external {
    uint256 balance = token.balanceOf(address(this));
    require(balance >= min, "deliver: balance below min");
    token.safeTransfer(recipient, balance);
}
```

Five properties define it. All five hold on both VMs.

- **Sweep, not amount.** There is no `amount` parameter. The contract sends its *entire* balance of
  the asset. Whatever arrived is what gets delivered — that is the point, not an oversight.
- **`min` is a floor on what arrived**, not slippage on a swap. Nothing here swaps. The contract
  knows nothing about how the balance got there; it asserts a lower bound and forwards.
- **Stateless and permissionless.** No owner, no storage, no allowlist, no pause. Anyone may call,
  and the caller chooses the recipient. Safety comes entirely from the caller binding
  `(asset, recipient, min)` upstream — typically an intent or settlement system. Access control here
  would not add safety, only relocate the trust assumption.
- **Holds no funds between calls.** It is a pass-through, never a vault. Any balance sitting in it is
  unconditionally claimable by the next caller, for a recipient of that caller's choosing. That is
  intended, and it means **you must never park funds here**.
- **Verification is post-hoc.** The check reads a balance already held. The contract never pulls
  funds in. Callers fund it first, then call.

## The two implementations

| | EVM | SVM / Solana |
|---|---|---|
| Path | `evm/` | `solana/` |
| Stack | Foundry, Solidity 0.8.28, OpenZeppelin 5.7.0 | Anchor 1.1.2, Rust 1.89, litesvm |
| Token entry point | `deliverToken(IERC20 token, address recipient, uint256 min)` | `deliver_token(ctx, min: u64)` |
| Native entry point | `deliverNative(address recipient, uint256 min)` | `deliver_sol(ctx, min: u64)` |
| Where the balance lives | The contract's own address | A PDA at seeds `[b"vault"]` — one ATA per mint, plus bare lamports |
| Transfer | `SafeERC20.safeTransfer` | `transfer_checked` CPI signed with the PDA seeds |
| Failure on the floor | `error BalanceBelowMin(uint256 balance, uint256 min)` | Anchor `6000`, message `"deliver: balance below min"` |
| Token programs | Any ERC-20, including USDT-style non-standard ones | SPL Token and Token-2022 (**not** `TransferHook` mints) |
| Tests | 50, `forge test` | 21, `cargo test` |

The error *message* is deliberately the same string on both sides so the two read identically.

**`PARITY.md` is the authoritative map** of what matches, what cannot match, and which EVM test
cases have a Solana counterpart. Read it before assuming the two are interchangeable.

## Build and test

Toolchain verified on this machine: forge/cast/anvil 1.5.1, anchor-cli 1.1.2, solana-cli 3.1.14,
cargo/rustc 1.89.0 (pinned by `solana/rust-toolchain.toml`).

### EVM

```bash
cd evm
forge build
forge test -vv                        # all 50 tests
forge fmt --check                     # formatting gate
forge test --match-contract Deliver   # one suite
forge coverage
```

`foundry.toml` pins solc 0.8.28 and `evm_version = "paris"` (no `PUSH0`), so the same bytecode
deploys on L2s that lag the EVM spec. Fuzz runs are set to 4096.

Dependencies are git submodules — clone with `--recurse-submodules`, or run
`git submodule update --init --recursive`.

### Solana

```bash
cd solana
anchor build                          # REQUIRED before cargo test
cargo test                            # 21 tests
cargo fmt --check && cargo clippy --all-targets
```

**`anchor build` must run first.** The tests execute a real BPF build of the program inside litesvm
and pull the ELF in with `include_bytes!(…/deploy/deliver.so)`; a stale or missing artifact means
you are not testing what you think you are. `Anchor.toml` sets `test = "cargo test"`, so
`anchor test` runs the same suite without needing a local validator.

## Layout

```
evm/src/Deliver.sol                       the contract
evm/test/Deliver.t.sol                    ERC-20 path: sweep, min boundaries, dust, permissionless, stateless, fuzz
evm/test/DeliverNative.t.sol              native path: same coverage, plus fail-closed on a rejecting recipient
evm/test/DeliverSentinels.t.sol           both native sentinels route to the native path; the address(0) hazard
evm/test/DeliverNonStandardTokens.t.sol   USDT-style no-return, false-returning, and fee-on-transfer tokens
evm/test/DeliverReentrancy.t.sol          hook-token and native recipient re-entry
evm/test/mocks/                           token and recipient mocks

solana/programs/deliver/src/lib.rs                        program docs + entry points
solana/programs/deliver/src/instructions/deliver_token.rs  the SPL / Token-2022 sweep
solana/programs/deliver/src/instructions/deliver_sol.rs    the lamport sweep
solana/programs/deliver/tests/deliver.rs                   the litesvm suite

PARITY.md                                 EVM ↔ SVM behaviour and test map
```

---

## SECURITY NOTES

Read these before integrating. Both are **deliberate design choices**, both are pinned by tests so
they cannot regress silently, and both can move funds in ways a careless caller will not expect.

### (a) The pre-transfer check means fee-taking tokens can under-deliver relative to `min`

`min` is checked against the balance the contract **holds before the transfer** — never against the
amount the recipient actually ends up with. There is no post-transfer balance-delta assertion on
either VM.

**Consequence: for any asset that moves less than it was asked to move, the check can pass while the
recipient receives strictly less than `min`, and the call still succeeds.** Nothing detects it, and
no revert is raised.

This covers fee-on-transfer ERC-20s, rebasing tokens, tokens with skimming hooks, and Token-2022
mints carrying a `TransferFee` extension. It is not a theoretical edge:

- EVM — `test_Hole_FeeOnTransferTokenCanDeliverLessThanMin`: 1% fee token, balance exactly `min`,
  recipient credited `0.99 * min`. No revert.
- SVM — `deliver_token_token2022_transfer_fee_recipient_gets_less_than_min`: 5% fee mint,
  `min = 1_000_000`, recipient credited `950_000`. No revert.

If you route fee-bearing assets through this contract, **`min` must be chosen with the fee already
priced in**, or you must enforce the received amount yourself by measuring the recipient's balance
delta in your calling contract. If you need a hard guarantee on the received amount, do not use this
contract for those assets.

Related, and asymmetric: on SVM, Token-2022 **`TransferHook` mints are not supported at all**. The
CPI forwards only the four accounts `transfer_checked` needs, so a hook mint fails outright rather
than misbehaving. The EVM side has no such restriction. Do not assume the SVM side inherits the EVM
side's breadth of non-standard-token coverage.

### (b) `address(0)` is a native-ETH sentinel, so an unset token variable sweeps ETH instead of reverting

On EVM, `deliverToken` treats **both** `address(0)` and
`0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE` as meaning "native ETH", and routes them to the native
path.

The classic caller bug — a struct field or storage variable that was never assigned, so `token`
arrives as the zero address — normally produces a harmless revert. **Here it does not revert. It
sweeps this contract's entire native ETH balance to whatever `recipient` that buggy caller
supplied.** A bug that would elsewhere be a failed transaction becomes an irreversible ETH transfer.

Pinned by `test_Hazard_UninitializedTokenSweepsEthInsteadOfReverting`.

Callers must treat a zero token address as a **live, funds-moving input** and validate it upstream.
This contract will not catch it for you.

This hazard is EVM-only. SVM has no token-address argument to overload — `deliver_token` takes a
mint *account*, and native value is reachable only through the separate `deliver_sol` instruction —
so `deliver_token` can never be tricked into a lamport sweep.

### Also worth knowing

- **The recipient is never validated on either VM**, including `address(0)` on EVM and
  `Pubkey::default()` on SVM. Passing a wrong recipient burns the funds with no recovery path. That
  is the caller's bug by design; binding the recipient upstream is the caller's job.
- **Any balance left in the contract is claimable by the next caller, for any recipient they
  choose.** Pinned by `test_AnyoneCanDivertAStrandedBalance`. Never leave funds here between flows.
- **A zero balance with `min == 0` succeeds as a no-op** on both VMs and both asset paths, rather
  than reverting. It is a deliberate choice, matched across the two, and tested.
- **On SVM, `deliver_token` can cost the caller ATA rent** (~0.002 SOL, unrefunded) when the
  recipient's associated token account does not yet exist. There is no EVM analogue. Any caller can
  force that cost on themselves for an arbitrary recipient.
- **Re-entrancy is unguarded on EVM because there is nothing to guard.** The transfer is the last
  action and no storage is written, so a re-entrant hook or recipient finds a zero balance and
  either no-ops (`min == 0`) or reverts (`min > 0`). Six tests exercise it rather than asserting it.
