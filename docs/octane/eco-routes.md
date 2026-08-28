# Octane linked-repo context — `eco/eco-routes`

Paste into the Octane linked-repository fields for a scan of **`eco/eco-delivery`**.
Observed at `eco-routes` branch `feat/intent-chainer` (`e354167`).

---

## General codebase description

`eco-routes` is Eco's on-chain intent settlement protocol for EVM chains. A user publishes and funds
an **intent** on a source chain; a solver fulfils it on the destination chain; a prover attests the
fulfilment back to the source chain; the solver withdraws the escrowed reward. The core contracts
are `Portal` (publish, fund, fulfil, withdraw, refund, with a status machine of
`Initial → Funded → Withdrawn/Refunded`), `Executor` (batch execution of an intent's destination-chain
calls, restricted to the Portal by an `onlyPortal` modifier set at construction), and a family of
provers — `BaseProver` and `MessageBridgeProver` as the roots, with `HyperProver`, `MetaProver`,
`LayerZeroProver`, `CCIPProver`, `PolymerProver`, `LocalProver`, and `AggregatorProver` (a stateless
1-of-N union that does not extend `BaseProver` and dispatches no messages). Bridges are addressed by
their own domain ids rather than chain ids, with per-bridge domain→chainId configuration supplied at
deploy time. Contracts are deployed with **CREATE3** through a shared deployer at
`0xC6BAd1EbAF366288dA6FB5689119eDd695a66814`, using a root `SALT` plus a per-contract version
discriminator, so a given contract lands at the same address on every chain.

The type that matters for `eco-delivery` is the destination-chain call list. `Route.calls` is a
`Call[]`, where `Call` is `{address target; bytes data; uint256 value}`. On fulfilment the `Portal`
hands that array to `Executor.execute(Call[])`, which iterates the batch in a single transaction,
rejects calls to EOAs that carry calldata, and reverts the whole batch if any call reverts.

## Review relevance

`eco-routes` is the **intended caller** of `eco-delivery`'s `Deliver.deliverToken` / `deliverNative`.
It is in scope as the source of the two properties `eco-delivery`'s security model depends on, and
for nothing else.

`Deliver` is deliberately stateless and permissionless: no owner, no allowlist, no pause, no
storage, and it does not validate the recipient. It reads its own balance of an asset, requires that
balance to be `>= min`, and forwards the entire balance. Every safety property therefore comes from
the caller, and specifically from two things `eco-routes` is supposed to supply:

1. **Binding of `(token, recipient, min)`.** `Route.calls` is covered by the intent hash, so the
   calldata naming the token, the recipient and the floor is committed to before anyone can execute
   it. `Deliver` trusts those three values completely; if they are wrong, that is the caller's bug
   by design.
2. **Atomicity of funding and delivery.** `Deliver` holds no funds between calls, and any balance
   left sitting in it is claimable by the next caller for a recipient of that caller's choosing —
   in-spec behaviour by anyone, not a bug. `Executor.execute` running the whole `Call[]` in one
   transaction and reverting the batch on any failure is exactly the atomic unit this requires.

So the review should use `eco-routes` to test whether that binding and that atomicity actually hold
in practice — whether a route can be constructed that funds `Deliver` in one transaction and
delivers in another, whether call ordering within a batch can expose a funded-but-undelivered state,
and whether an intent field an attacker can influence can reach `deliverToken`'s `token` argument as
a zero address (which `Deliver` treats as native ETH, see below).

The review should **not** look for cross-repository ABI, serialization, hashing, discriminator,
domain-id, or version agreement between these two repos. There is none to check — see below.

## Integration assumptions

Evaluate with the following assumptions and trust boundaries.

- **There is no code dependency in either direction, today.** `eco-delivery` imports nothing from
  `eco-routes`; its only dependencies are `forge-std` and OpenZeppelin. `eco-routes` contains no
  reference to any `Deliver` address, interface, or ABI. Nothing in `eco-delivery` is deployed to
  any network. The two repos share no types, no hashing, no serialization, and no version pin.
  **Findings that assume a shared ABI, a shared intent hash, cross-repo version drift, or agreement
  on address normalization or domain ids are not applicable.** The only thing `eco-delivery`
  borrows from `eco-routes` is a deployment convention (the same CREATE3 deployer, the same
  root-salt-plus-version-discriminator derivation), and that is copied, not imported.
- **The intended composition** is `Deliver` appearing as `route.calls[k].target` with
  `data = deliverToken(token, recipient, min)`, in the same `Call[]` batch as whatever produces the
  output — a swap, an aggregator call, an RFQ fill. `Deliver` never pulls funds in; the route funds
  it first and then calls it, within the one Executor batch.
- **A bridge cannot be the last hop before `Deliver`.** A bridge pays out on the destination chain
  in a *different* transaction, so its output would already be sitting in `Deliver` before the
  delivering transaction starts, and would belong to whoever calls first. Bridges belong upstream of
  the atomic unit. Treat any route shape that puts a cross-transaction payout immediately before
  `deliverToken` as a real finding.
- **The following are deliberate, documented design decisions in `eco-delivery`, not defects.** They
  are stated in its `README.md` (`## Security notes`), in the NatSpec of `evm/src/Deliver.sol`, and
  pinned by tests:
  - permissionless entry — any caller, no access control, no owner, no pause;
  - the recipient is never validated, `address(0)` included, and a wrong recipient burns funds;
  - the entire balance is swept, with no `amount` parameter, including pre-existing dust;
  - **both `address(0)` and `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE` are accepted as native-ETH
    sentinels**, so an unset `token` field sweeps ETH rather than reverting — a knowingly accepted
    hazard;
  - no events are emitted; on the ERC-20 path the token's own `Transfer` log is the record, and on
    the native path there is no log at all and deliveries are trace-only;
  - the native send forwards all remaining gas via a raw `call` and reverts on failure;
  - there is no reentrancy guard: the transfer is the last action, no storage is written, and a
    re-entrant caller finds a zero balance.
- **One genuine, documented hole.** `min` is checked against the balance held **before** the
  transfer, never against what the recipient receives. A fee-on-transfer, rebasing, or hook token
  can pass the check and credit the recipient strictly less than `min`, and the call still succeeds.
  This is accepted and pinned by `test_Hole_FeeOnTransferTokenCanDeliverLessThanMin`. It is worth
  reporting only in the form "a route in `eco-routes` sends such an asset through `Deliver` and
  relies on `min` as a user-facing guarantee".
- **Route calls are adversarial execution inputs.** The Executor's existing guarantees about not
  retaining approvals, delegates, or persistent control still apply. `Deliver` holds no approvals
  and grants none, so it adds no new persistent-control surface, but a route that leaves a balance
  in it between transactions has effectively donated that balance to any watcher.
