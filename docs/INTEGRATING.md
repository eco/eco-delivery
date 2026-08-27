# Integrating EcoDelivery

How to put EcoDelivery at the end of a route so the delivery guarantee actually holds.

If you read one section, read [The one rule](#1-the-one-rule-one-transaction). Every way this
integration goes wrong is a variation of getting that wrong.

- [The mental model](#0-the-mental-model)
- [1. The one rule: one transaction](#1-the-one-rule-one-transaction)
- [2. EVM integration](#2-evm-integration)
- [3. Solana integration](#3-solana-integration)
- [4. Choosing `min`](#4-choosing-min)
- [5. Failure modes and what they mean](#5-failure-modes-and-what-they-mean)
- [6. Pre-integration checklist](#6-pre-integration-checklist)

---

## 0. The mental model

EcoDelivery is not a step *in* your route. It is the thing your route **ends by paying into**.

You point the final hop's output at the EcoDelivery address instead of at the user, then call
`deliverToken` in the same transaction. The contract checks the floor once, on the real output, and
forwards everything.

What you get for that: you stop caring what the route was made of. Providers can be added, removed
or reordered, each with whatever slippage settings they like, and the delivery guarantee is
unchanged — because it is enforced after all of them, on the actual number.

What you take on: the two responsibilities in this document. Atomicity, and choosing `min`.

## 1. The one rule: one transaction

The contract is permissionless, holds no state, and sweeps its **entire** balance to a
**caller-chosen** recipient. Those properties are what make it trustless. They also mean:

> A balance sitting in EcoDelivery between transactions belongs to whoever calls next.

Not "is at risk from". *Belongs to.* Calling `deliverToken(token, myOwnAddress, 0)` against a funded
contract is a completely valid, in-spec use of the contract by anyone who wants to. There is no bug
to report and no privileged party who can stop it. This is pinned by
`test_AnyoneCanDivertAStrandedBalance`.

So:

```
❌  tx 1:  route swaps, output lands in EcoDelivery
    tx 2:  deliverToken(...)          ← anyone can front-run this and take everything

✅  tx 1:  route swaps → output lands in EcoDelivery → deliverToken(...)
           all in one atomic transaction
```

If your architecture cannot make the funding and the delivery atomic, EcoDelivery is the wrong
component — you need something that escrows, and this contract explicitly does not.

### What a revert actually does

The same atomicity that protects the delivery is what makes failure safe. A revert here is **not** a
failed last step that strands a half-finished route:

> It unwinds the **entire transaction** — every swap, hop and fill in it — not just this step.

The user does not end up holding an intermediate asset, and does not end up with output stranded
somewhere they have to go rescue. Their input tokens never left their wallet.

| On a revert | What happens to it |
|---|---|
| Every swap in this transaction | Undone, as if never submitted |
| The user's input tokens | Never left the wallet |
| The output deposited into EcoDelivery | Unwound with everything else — the deposit itself is rolled back, so there is no stranded balance to clean up |
| Gas / transaction fee | **Spent.** The only real cost of a failed delivery |
| A cross-chain leg already settled in a *different* transaction | **Not undone.** Atomicity is per-transaction and per-chain; a bridge that already paid out elsewhere stays paid out |

**Do not swallow the revert.** On EVM, all of the above holds only if the revert propagates out of
your transaction. If you wrap the delivery in `try/catch`, or make a low-level `call` and ignore the
returned success flag, you have caught it — the route still ran, and its output is now sitting in
EcoDelivery for whoever calls next. This is the same failure as splitting the flow across two
transactions, arrived at from a different direction.

On Solana this cannot happen: a failed CPI aborts the entire transaction and the calling program has
no way to catch it.

## 2. EVM integration

The route's final hop must send its output **to the EcoDelivery address**, and your settlement
contract calls `deliverToken` in the same transaction.

```solidity
interface IDeliver {
    function deliverToken(IERC20 token, address recipient, uint256 min) external;
    function deliverNative(address recipient, uint256 min) external;
}

contract Settlement {
    IDeliver public immutable deliver;

    /// @param route      the aggregator/bridge/AMM call to execute
    /// @param out        the asset the user is owed
    /// @param recipient  who the user wants paid — bind this upstream, it is never validated
    /// @param min        the floor, in `out`'s smallest unit
    function settle(
        Call calldata route,
        IERC20 out,
        address recipient,
        uint256 min
    ) external {
        // 1. Run the route. Its output destination MUST be address(deliver), not address(this).
        (bool ok, bytes memory err) = route.target.call{value: route.value}(route.data);
        if (!ok) _bubble(err);

        // 2. Same transaction. Floor is enforced here, on whatever actually arrived.
        deliver.deliverToken(out, recipient, min);
    }
}
```

Notes specific to EVM:

- **Point the route at `address(deliver)`.** Most aggregators take a `receiver` / `destination`
  parameter. If a provider can only pay your own contract, forward to EcoDelivery yourself within
  the same call — but then you are the one holding funds mid-transaction, which is fine atomically.
- **Native ETH** uses `deliverNative(recipient, min)`, or `deliverToken` with either sentinel
  (`address(0)` or `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE`). Fund via a plain transfer;
  `receive()` accepts it.
- **`address(0)` is live.** If your `token` field can ever be unset, validate it before the call —
  a zero address here sweeps ETH rather than reverting. See the README's security note (b).
- **Dust is a feature, not a leak.** Anything already in the contract is swept along with your
  delivery. Since you must be atomic anyway, treat any pre-existing balance as a bonus to your
  recipient, never as something you can leave for later.
- **Deployment.** The contract is stateless with no constructor arguments, so `CREATE2` gives the
  same address on every chain — worth doing if your callers hardcode it. `evm_version = "paris"`
  keeps the bytecode deployable on L2s that lag the EVM spec.

## 3. Solana integration

Same shape, different plumbing. The route's output must land in the **vault ATA** — the associated
token account of the vault-authority PDA at seeds `[b"vault"]` for that mint — and `deliver_token`
must be an instruction in the same transaction.

```
Transaction
  ix[0]  route swap        destination = vault ATA  (PDA authority, mint)
  ix[1]  deliver_token     min = <floor>            → sweeps to recipient's ATA
```

```rust
let (vault_authority, _) = Pubkey::find_program_address(&[b"vault"], &deliver::ID);
let vault_ata = get_associated_token_address_with_program_id(
    &vault_authority, &mint, &token_program,
);
// point the swap's destination at `vault_ata`, then append the deliver_token instruction
```

Notes specific to Solana:

- **The vault ATA must already exist.** The program never creates it — it pulls no funds in, so a
  vault ATA that was never initialised means there is nothing to deliver, and the transaction fails
  at account resolution with Anchor `3012 AccountNotInitialized`. Create it once per mint, or
  include a `create_associated_token_account_idempotent` instruction ahead of the swap.
- **The recipient's ATA is created for you**, with the caller paying rent (~0.002 SOL, unrefunded).
  This has no EVM analogue and it is a real cost your caller absorbs.
- **Transaction limits are the practical constraint.** A large route plus the delivery must fit in
  one transaction's size and compute budget. Use address lookup tables, and raise the CU limit with
  a `ComputeBudget` instruction if needed. This is usually the thing that actually bites.
- **Token-2022 `TransferHook` mints are not supported.** The CPI forwards only the four accounts
  `transfer_checked` needs, so a hook mint fails outright. It fails closed, but it fails.
- **Native SOL** uses `deliver_sol(min)`, sweeping the PDA's bare lamports. There is no sentinel
  encoding — SVM has no token-address argument to overload, so native has its own instruction and
  `deliver_token` can never be steered into a lamport sweep.

## 4. Choosing `min`

`min` is denominated in the **output asset's smallest unit** — wei, or the mint's base units. It is
not decimals-adjusted for you.

For a normal asset, `min` is simply the floor you quoted the user, minus whatever tolerance your
product allows.

**For an asset that takes a fee on transfer, subtracting is wrong.** The check runs against the
balance held *before* the outbound transfer, so if the asset skims `f` on the way out and you need
the recipient to end up with at least `Q`:

```
min  ≥  Q / (1 − f)          ← divide, do not subtract
```

A 1% fee token and a target of 1,000 units needs `min ≥ 1010.1…`, not `990`. Setting `min = Q`
guarantees the recipient gets `Q × (1 − f)`, which is less than you promised — this is the accepted
hole described in the README's security note (a), and it is pinned by tests on both VMs rather than
left as a claim.

If you cannot model the fee, enforce the received amount yourself by measuring the recipient's
balance delta in your own contract, or keep that asset off this path.

## 5. Failure modes and what they mean

| Failure | VM | What actually happened |
|---|---|---|
| `BalanceBelowMin(balance, min)` | EVM | The route under-delivered — **or** the funds were never deposited, **or** someone already swept them because the flow was not atomic. The error carries the observed `balance`; `balance == 0` almost always means one of the latter two. |
| Anchor `6000` `"deliver: balance below min"` | SVM | Same condition. Note the Anchor error carries **only** the code and message — the observed balance is not in the payload, so you cannot distinguish "under-delivered" from "empty" off the error alone. |
| `NativeTransferFailed(recipient, amount)` | EVM | The recipient rejected the ETH — a contract with no `receive()`, or one that reverts. Fails closed; nothing moved. |
| `SafeERC20FailedOperation(token)` | EVM | The token returned `false`, or the address has no code. A non-token address that is not a sentinel lands here. |
| Anchor `3012 AccountNotInitialized` | SVM | The vault ATA for that mint does not exist. Nobody funded the vault. |
| Transaction too large / CU exhausted | SVM | Route + delivery did not fit. Lookup tables, `ComputeBudget`, or split the route (**never** split the delivery off — see [rule 1](#1-the-one-rule-one-transaction)). |

The diagnostic worth internalising: **"I definitely swapped, but I got `BalanceBelowMin` with
`balance == 0`"** is nearly always a broken atomicity assumption, not a broken route. Someone else
called first.

## 6. Pre-integration checklist

- [ ] The route's final hop pays **the EcoDelivery address / vault ATA**, not your contract and not
      the user.
- [ ] Funding and `deliverToken` are in **one transaction**. No exceptions.
- [ ] `recipient` is bound upstream and validated before the call — it is never validated here, and
      a wrong one burns the funds irrecoverably.
- [ ] `min` is in the output asset's smallest unit, and for fee-bearing assets it is **divided** by
      `(1 − fee)`, not reduced by the fee.
- [ ] On EVM, `token` can never arrive as `address(0)` unless you mean ETH.
- [ ] On SVM, the vault ATA for the mint exists, and the transaction fits in size and compute.
- [ ] You have read the README's [security notes](../README.md#security-notes) and accepted both
      documented hazards, and [`PARITY.md`](../PARITY.md) if you rely on both VMs behaving alike.
- [ ] You are not treating this contract as an escrow, a vault, or a place to park funds. It is
      none of those.
