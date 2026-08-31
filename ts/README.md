# `@eco-foundation/delivery`

TypeScript SDK for **EcoDelivery** — the outcome verifier that sits at the end of a swap route.
Call builders for both VMs, plus the `min` arithmetic that is easy to get wrong.

See the [root README](../README.md) for what the contract is and
[`docs/INTEGRATING.md`](../docs/INTEGRATING.md) for how to wire it into a route.

> **Not published.** The package is marked `"private": true` so `npm publish` refuses it.
> The contracts are unaudited; remove that field when there is a release to make.

```bash
npm install @eco-foundation/delivery   # once published
```

`viem`, `@solana/web3.js` and `@solana/spl-token` are **optional** peer dependencies. The root
entry point has no runtime dependencies at all, so an EVM-only consumer never installs the
Solana packages.

| Import | Needs |
|---|---|
| `@eco-foundation/delivery` | nothing — constants, `min` math, the raw ABI and IDL |
| `@eco-foundation/delivery/evm` | `viem` |
| `@eco-foundation/delivery/svm` | `@solana/web3.js`, `@solana/spl-token` |

## Choosing `min`

The floor is checked against the balance held **before** the transfer, so on a fee-taking asset
you have to divide by what survives the fee — subtracting it under-delivers.

```ts
import {minForTarget, receivedFor, shortfallIfMinEqualsTarget} from "@eco-foundation/delivery";

minForTarget(1000n, 100);              // 1011n  — 1% fee, recipient ends up with ≥ 1000
receivedFor(1000n, 100);               //  990n  — what passing 1000n actually delivers
shortfallIfMinEqualsTarget(1000n, 100) //   10n  — the gap that mistake opens
```

## EVM

```ts
import {deliverTokenCall, decodeDeliverError, isNativeSentinel} from "@eco-foundation/delivery/evm";

const call = deliverTokenCall(DELIVER_ADDRESS, {
  token: USDC,
  recipient: user,      // never validated by the contract — bind it upstream
  min: 1_000_000n,
});
// append `call` to the SAME transaction as the route that funds the contract
```

`isNativeSentinel(token)` is worth calling on any token address that came from config or a
user: **both** `address(0)` and `0xEeee…` route into the native ETH path, so an unset token
field sweeps ETH rather than reverting.

`decodeDeliverError(data)` turns revert data into a typed result. A `BalanceBelowMin` with
`balance === 0n` almost always means the funds were never deposited or were already swept by
someone else — not that the route under-delivered.

## Solana

```ts
import {deliverTokenIx, vaultTokenAccount} from "@eco-foundation/delivery/svm";

// point the route's swap at this account
const vaultAta = vaultTokenAccount(mint);

// then append, in the SAME transaction
const ix = deliverTokenIx({payer, mint, recipient, min: 1_000_000n});
```

Instruction data is the 8-byte Anchor discriminator read from the generated IDL plus a
little-endian `u64`, so no Anchor runtime is pulled in. Pass `tokenProgram:
TOKEN_2022_PROGRAM_ID` for Token-2022 mints. `TransferHook` mints are not supported.

## The rule the SDK cannot enforce

Fund and deliver in **one transaction**. A balance left in the contract between transactions
belongs to whoever calls next — that is in-spec behaviour by anyone, not a bug. No helper here
can protect you from splitting the flow.

## Development

The ABI and IDL in `src/generated/` are produced from the real contract build output, so they
cannot drift from the contracts:

```bash
cd ../evm && forge build          # produces the ABI
cd ../solana && anchor build      # produces the IDL
cd ../ts
npm run generate                  # regenerate src/generated/
npm run check:drift               # fail if stale (CI + prepublish)
npm run typecheck && npm run build && npm test
```

Tests check the encoders against values derived independently of the SDK: EVM selectors
against `cast sig`, Anchor discriminators against `sha256("global:<name>")[..8]`.
