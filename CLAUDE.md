# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A minimal, dual-VM **outcome verifier**: a contract that delivers tokens it is already holding to a
recipient, and reverts unless the delivered amount meets a caller-supplied minimum. One
implementation for EVM (Foundry/Solidity), one for SVM/Solana (Anchor/Rust). They are two encodings
of the same primitive and must stay behaviorally identical.

Full design context lives in the Notion "Outcome Verifier — Partner Validation Guide"
(`app.notion.com/p/eco-corp/...3c7805b0f17f8188bbb1e63d91c1f67c`). It is access-gated — ask the user
to paste relevant sections rather than assuming its contents.

Status: greenfield. Nothing is implemented yet; treat the sections below as the contract the code
must satisfy, not a description of existing code.

## The core primitive

EVM reference shape:

```solidity
function deliverToken(IERC20 token, address recipient, uint256 min) external {
    uint256 balance = token.balanceOf(address(this));
    require(balance >= min, "deliver: balance below min");
    token.safeTransfer(recipient, balance);
}
```

Properties that define the design — preserve all of them:

- **Sweep, not amount.** There is no `amount` parameter. The contract sends its *entire* balance of
  `token`. Adding an amount argument breaks the primitive: the point is that whatever arrived is what
  gets delivered.
- **`min` is a floor on what arrived**, not slippage on a swap. The contract performs no swap and
  knows nothing about how the balance got there. It only asserts a lower bound and forwards.
- **Stateless and permissionless.** No owner, no storage, no allowlist. Anyone may call it. Safety
  comes entirely from the caller binding `(token, recipient, min)` — typically an intent/settlement
  system upstream. Do not add access control to "fix" this; if a caller passes a wrong recipient,
  that is the caller's bug.
- **Holds no funds between calls.** The contract is a pass-through. Any balance sitting in it is
  unconditionally claimable by the next caller, which is intended — but it means the contract must
  never be used as a vault, and any dust from a prior flow is swept to whoever calls next.
- **Verification is post-hoc.** The check reads the balance the contract already has; it does not
  pull funds in. Callers fund the contract first, then call.

## EVM implementation notes

- Use `SafeERC20.safeTransfer`. Non-standard tokens (USDT-style, missing return values) must work.
- **Fee-on-transfer / rebasing tokens break the naive form**: `balance >= min` is checked pre-transfer
  but the recipient may receive less. If these are in scope, verify the *recipient's* balance delta
  against `min` instead, and say so explicitly in the contract's NatSpec.
- Zero balance with `min == 0` should be decided deliberately: either reject empty deliveries or
  allow a no-op transfer. Pick one and test it.
- Reentrancy: the transfer is the last action and there is no state to corrupt, but a token with a
  transfer hook can re-enter and will find a zero balance. Confirm that's harmless rather than
  assuming it.
- Native ETH is a separate path if needed (`address(this).balance` + a call-based send); it cannot
  reuse the ERC-20 function.

## SVM/Solana implementation notes

The Solana side is the same primitive but the token model differs enough that parity is easy to lose:

- Balance lives in a **token account**, not on the program. The delivering account is typically a
  PDA-owned vault ATA; the transfer is a CPI to the token program signed with the PDA's seeds.
- The recipient's ATA may not exist. Decide whether the instruction creates it (and who pays rent)
  or requires it pre-initialized — this is a real interface difference from EVM, document it.
- **Token-2022 transfer fees and transfer hooks** are the SVM analogue of fee-on-transfer, with the
  same consequence for the `min` check. Use `transfer_checked` and account for the fee if
  Token-2022 mints are supported.
- Decide whether the vault token account is closed (rent reclaimed) after a full sweep.
- `min` and the recipient are instruction arguments/accounts, mirroring the EVM signature; keep the
  argument order and semantics aligned so the two can be reasoned about together.

## Commands

Toolchain present on this machine: forge/cast/anvil 1.5.1, anchor-cli 1.1.2, solana-cli 3.1.14,
cargo 1.97.

EVM (Foundry, from the Solidity package root):

```bash
forge build
forge test                          # all tests
forge test -vvv                     # with traces (use -vvvv for full stack)
forge test --match-test testDeliver # single test by name
forge test --match-contract Deliver # single test contract
forge test --match-path test/Deliver.t.sol
forge fmt                           # format; `forge fmt --check` in CI
forge coverage
forge snapshot                      # gas snapshots
anvil                               # local node for fork/integration work
```

Solana (Anchor, from the Anchor workspace root):

```bash
anchor build
anchor test                         # builds, starts a local validator, runs the test suite
cargo test                          # Rust unit tests only, no validator
cargo fmt && cargo clippy --all-targets
```

## Testing expectations

The behavior worth testing is small and specific — cover these on both VMs:

- delivers the full balance to the recipient, not a partial amount
- reverts when `balance < min`, including `balance == min - 1`
- succeeds at exactly `balance == min`
- pre-existing balance (dust) is included in the sweep
- non-standard ERC-20s / Token-2022 mints behave as documented
- an unrelated caller can invoke it (permissionless is intentional, so assert it)

Keep the EVM and SVM test suites structurally parallel — a case added on one side should have a
counterpart on the other, or a comment saying why it cannot exist.
