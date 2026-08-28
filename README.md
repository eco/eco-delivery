# EcoDelivery

**The last step of every swap route.** Whatever a route produces, EcoDelivery is where it lands —
and nothing leaves unless it clears the floor the user was promised.

One implementation for EVM (Foundry/Solidity), one for SVM/Solana (Anchor/Rust). Two encodings of
one primitive, kept behaviourally identical on purpose.

> **Not audited, not deployed.** Nothing here claims otherwise.

- [Why this exists](#why-this-exists) · [The guarantee](#the-guarantee) ·
  [**Integration guide →**](docs/INTEGRATING.md) · [**EVM ↔ SVM parity map →**](PARITY.md)

---

## Why this exists

A swap route is a chain of things you did not write. An aggregator, a bridge, an AMM hop, an RFQ
filler, a market maker's private endpoint. Each has its own notion of slippage, its own `minOut`
semantics, its own failure modes — and some have no guarantee at all. Auditing every provider's
promise, for every route, forever, does not scale.

So don't. Put the guarantee at the end instead.

```
  user is quoted:  "≥ 1000 USDC to 0xabc…"
        │
        ├──► provider A  (bridge)     ─┐
        ├──► provider B  (AMM hop)     ├── whatever these promise, we do not rely on it
        └──► provider C  (RFQ fill)   ─┘
                    │
                    ▼   every route ends by depositing its output here
        ┌─────────────────────────────────────────────┐
        │  EcoDelivery                                │
        │  deliverToken(USDC, 0xabc…, 1000e6)         │
        │                                             │
        │  held balance ≥ min ?                       │
        │    no  ──►  revert — the WHOLE transaction  │
        │             unwinds, every swap above with  │
        │             it; the user keeps their input  │
        │    yes ──►  sweep 100% of it to 0xabc…      │
        └─────────────────────────────────────────────┘
                    ▲
          all of it inside ONE transaction
```

The contract itself knows nothing about swaps. It reads a balance, checks a floor, forwards
everything. That ignorance is the feature: **it works the same regardless of what ran in front of
it**, so adding a new provider to the route changes nothing about how delivery is enforced.

One consequence worth internalising: because the check happens once, at the end, on the *actual*
output, the intermediate hops' own slippage settings stop being a safety property. Set them however
you like. If the route under-delivers, the last step reverts, [the whole transaction
unwinds](#what-a-revert-actually-does), and the user keeps their input.

## The guarantee

Stated precisely, because "guaranteed" is a word worth being exact about:

> **If the call does not revert, the recipient was sent the entire balance this contract held of
> that asset, and that balance was at least `min`.**

Two things that guarantee does *not* cover. Both are deliberate, both are pinned by tests, and both
are described in full under [Security notes](#security-notes):

1. **That the recipient *received* ≥ `min`.** The check reads the balance held *before* the
   transfer. An asset that takes a cut in transit — a fee-on-transfer ERC-20, a Token-2022
   `TransferFee` mint, a rebasing token — can pass the check and still credit the recipient less.
   Price the fee into `min`, or don't route that asset through here.
2. **Anything at all, if funding and delivery are separate transactions.** See below — this is the
   one integration rule that matters.

### The one rule: fund and deliver atomically

This contract is permissionless and sweeps its whole balance to a caller-chosen recipient. A balance
sitting in it between transactions belongs to **whoever calls next**, for a recipient of *their*
choosing. That is not a flaw; it is what makes the contract stateless and trust-free. But it means:

> **The swap and the delivery must be in the same transaction.** If your route deposits output in
> transaction 1 and calls `deliverToken` in transaction 2, anyone can take the funds in between.

Pinned by `test_AnyoneCanDivertAStrandedBalance`. The [integration guide](docs/INTEGRATING.md) shows
how to compose it correctly on both VMs.

### What a revert actually does

Atomicity is also what makes failure safe, so it is worth being exact about what "revert" means here.
It is **not** a failed delivery that leaves the route half-finished:

> A revert unwinds the **entire transaction** — every swap, hop and fill in it — not just this step.

The user does not end up holding some intermediate asset, and does not end up with output stranded
somewhere they have to go rescue. Their input tokens never left their wallet.

| On a revert | What happens to it |
|---|---|
| Every swap in this transaction | Undone, as if never submitted |
| The user's input tokens | Never left the wallet |
| The output deposited into EcoDelivery | Unwound with everything else — there is no stranded balance to clean up, because the deposit itself is rolled back |
| Gas / transaction fee | **Spent.** The only real cost of a failed delivery |
| A cross-chain leg already settled in a *different* transaction | **Not undone.** Atomicity is per-transaction and per-chain |

**EVM footgun:** all of this holds only if you let the revert propagate. A settlement contract that
wraps the delivery in `try/catch`, or makes a low-level `call` and ignores the returned success flag,
has *caught* the revert and broken the guarantee — the route still ran, and its output is now sitting
in the contract for whoever calls next. On Solana this failure mode does not exist: a failed CPI
aborts the whole transaction and the calling program cannot catch it.

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
  the asset. Whatever the route produced is what gets delivered — that is the point, not an
  oversight. It is also why upstream hops cannot silently retain a slice.
- **`min` is a floor on what arrived.** The contract performs no swap and cannot tell slippage from
  a bridge fee. In the route, though, `min` *is* the route's final `minOut` — enforced once, at the
  end, on the real output.
- **Stateless and permissionless.** No owner, no storage, no allowlist, no pause. Anyone may call,
  and the caller chooses the recipient. Safety comes entirely from the caller binding
  `(asset, recipient, min)` upstream. Access control here would not add safety, only relocate the
  trust assumption.
- **Holds no funds between calls.** A pass-through, never a vault. See [the one rule](#the-one-rule-fund-and-deliver-atomically).
- **Verification is post-hoc.** The check reads a balance already held. The contract never pulls
  funds in. Fund it first, then call.

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
| Tests | 50, `forge test` | 23, `cargo test` |

The error *message* is deliberately the same string on both sides so the two read identically.

**[`PARITY.md`](PARITY.md) is the authoritative map** of what matches, what cannot match, and which
EVM test cases have a Solana counterpart. Read it before assuming the two are interchangeable.

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
cargo test                            # 23 tests, incl. 768 proptest cases
cargo fmt --check && cargo clippy --all-targets
```

**`anchor build` must run first.** The tests execute a real BPF build of the program inside litesvm
and pull the ELF in with `include_bytes!(…/deploy/deliver.so)`; a stale or missing artifact means
you are not testing what you think you are. `Anchor.toml` sets `test = "cargo test"`, so
`anchor test` runs the same suite without needing a local validator.

## Documentation

| Document | What it is for |
|---|---|
| [`docs/INTEGRATING.md`](docs/INTEGRATING.md) | **Start here to build on it.** How to compose the delivery atomically, how to choose `min`, what each failure mode means. |
| [`ts/README.md`](ts/README.md) | The `@eco-foundation/delivery` SDK — call builders for both VMs and the `min` arithmetic. |
| [`docs/DEPLOYING.md`](docs/DEPLOYING.md) | CREATE3 deploys, the salt rule, the Solana program id and keypair custody. |
| [`PARITY.md`](PARITY.md) | EVM ↔ SVM behaviour and test map. Every divergence, stated as a divergence. |
| [`evm/README.md`](evm/README.md) | EVM interface reference. |
| [Security notes](#security-notes) | The two accepted hazards, in full. Read before integrating. |
| Doc comments | `evm/src/Deliver.sol` and `solana/programs/deliver/src/lib.rs` carry the same warnings inline. |

## Layout

```
evm/src/Deliver.sol                       the contract
evm/test/Deliver.t.sol                    ERC-20 path: sweep, min boundaries, dust, permissionless, stateless, fuzz
evm/test/DeliverNative.t.sol              native path: same coverage, plus fail-closed on a rejecting recipient
evm/test/DeliverSentinels.t.sol           both native sentinels route to the native path; the address(0) hazard
evm/test/DeliverNonStandardTokens.t.sol   USDT-style no-return, false-returning, and fee-on-transfer tokens
evm/test/DeliverReentrancy.t.sol          hook-token and native recipient re-entry
evm/test/mocks/                           token and recipient mocks

solana/programs/deliver/src/lib.rs                         program docs + entry points
solana/programs/deliver/src/instructions/deliver_token.rs  the SPL / Token-2022 sweep
solana/programs/deliver/src/instructions/deliver_sol.rs    the lamport sweep
solana/programs/deliver/tests/deliver.rs                   the litesvm suite, including proptest fuzzing

ts/src/evm.ts                             viem call builders + typed error decoding
ts/src/svm.ts                             Solana instruction builders (no Anchor runtime)
ts/src/min.ts                             the min ÷ (1 − fee) arithmetic
ts/src/generated/                         ABI + IDL, generated from the contract builds
ts/scripts/generate.mjs                   regenerator; `--check` fails CI on drift

evm/script/Deploy.s.sol                   CREATE3 deploy, idempotent, with predictAddress()

docs/INTEGRATING.md                       integration guide
docs/DEPLOYING.md                         deploy runbook for both VMs
PARITY.md                                 EVM ↔ SVM behaviour and test map
.github/workflows/ci.yml                  CI: forge, anchor, and SDK
```

## SDK

Not published yet — the package is marked `private` so `npm publish` refuses it, and the
contracts are unaudited and undeployed. Consume it from the repo until there is a release.

```bash
npm install @eco-foundation/delivery   # once published
```

```ts
import {minForTarget}       from "@eco-foundation/delivery";       // no runtime deps
import {deliverTokenCall}   from "@eco-foundation/delivery/evm";   // needs viem
import {deliverTokenIx}     from "@eco-foundation/delivery/svm";   // needs @solana/*
```

The ABI and IDL it ships are generated from the contract build output, and CI fails if they
drift. See [`ts/README.md`](ts/README.md).

---

## Security notes

Read these before integrating. Both are **deliberate design choices**, both are pinned by tests so
they cannot regress silently, and both can move funds in ways a careless caller will not expect.

### (a) The pre-transfer check means fee-taking assets can under-deliver relative to `min`

`min` is checked against the balance the contract **holds before the transfer** — never against the
amount the recipient actually ends up with. There is no post-transfer balance-delta assertion on
either VM.

**Consequence: for any asset that moves less than it was asked to move, the check can pass while the
recipient receives strictly less than `min`, and the call still succeeds.** Nothing detects it, and
no revert is raised.

This matters most in exactly the setting this contract is built for: a route whose last hop is an
asset with a transfer fee. The route-level guarantee is only as good as the asset's willingness to
move what it says it moves. It covers fee-on-transfer ERC-20s, rebasing tokens, tokens with skimming
hooks, and Token-2022 mints carrying a `TransferFee` extension. It is not a theoretical edge:

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
  choose.** Pinned by `test_AnyoneCanDivertAStrandedBalance`. This is
  [the one rule](#the-one-rule-fund-and-deliver-atomically).
- **A zero balance with `min == 0` succeeds as a no-op** on both VMs and both asset paths, rather
  than reverting. It is a deliberate choice, matched across the two, and tested.
- **On SVM, `deliver_token` can cost the caller ATA rent** (~0.002 SOL, unrefunded) when the
  recipient's associated token account does not yet exist. There is no EVM analogue. Any caller can
  force that cost on themselves for an arbitrary recipient.
- **Re-entrancy is unguarded on EVM because there is nothing to guard.** The transfer is the last
  action and no storage is written, so a re-entrant hook or recipient finds a zero balance and
  either no-ops (`min == 0`) or reverts (`min > 0`). Six tests exercise it rather than asserting it.
