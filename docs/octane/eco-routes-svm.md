# Octane linked-repo context — `eco/eco-routes-svm`

Paste into the Octane linked-repository fields for a scan of **`eco/eco-delivery`**.
Observed at `eco-routes-svm` branch `feat/intent-chainer` (`6089c82`).

---

## General codebase description

`eco-routes-svm` is the Solana/SVM encoding of Eco's intent settlement protocol — the counterpart to
the EVM contracts in `eco-routes`. It is an Anchor workspace (anchor-lang 1.1.2) whose programs are
`portal` (publish, fund, fulfil, withdraw, refund), `intent-chainer`, `hyper-prover`,
`local-prover`, `flash-fulfiller`, and `proof-helper`, alongside deliberately hostile test programs
(`malicious-prover`, `malicious-proof-closer`, `dummy-ism`) used to exercise the trust boundaries.
Program ids are ground vanity keys beginning `Eco…` (for example `portal` at
`EcooswwC1NggsckZyF5SeAL9WsgJs3UhPbrqY1apV73F`), carried identically across the `[programs.localnet]`,
`[programs.devnet]` and `[programs.mainnet]` tables in `Anchor.toml`. A `mainnet` feature flag is
**required** for mainnet builds because it switches network-specific configuration such as the
Hyperlane mailbox address. Program keypairs are gitignored (`/target`, `/keys`) rather than
committed.

The mechanism that matters for `eco-delivery` is how destination-chain calls cross the wire. Solana
instruction size limits mean a route call is split: `Calldata { data: Vec<u8>, account_count: u8 }`
travels in the intent, and the matching `Vec<SerializableAccountMeta>` is supplied in the fulfilling
transaction, recombined into `CalldataWithAccounts` on the destination chain, and used both to
compute the intent hash and to drive the CPI. Everything in a fulfilling transaction executes
atomically: a failed CPI aborts the entire transaction and the calling program has no way to catch it.

## Review relevance

`eco-routes-svm` is the **intended caller** of `eco-delivery`'s Solana program (`deliver`, program id
`EcoyzRRwsSsFz6i4YU6r28WGD9mamCtRi4Zc8w78FNjw`). It is in scope as the source of the properties
`eco-delivery` depends on and cannot enforce itself, and for nothing else.

The `deliver` program is stateless and permissionless: no admin, no allowlist, and no program state
beyond a vault-authority PDA at seeds `[b"vault"]` that is never allocated data and exists only to
sign outbound transfers. `deliver_token(min)` reads the vault ATA's `amount`, requires it to be
`>= min`, and sweeps the whole balance to the recipient's ATA via a `transfer_checked` CPI signed
with the PDA seeds. `deliver_sol(min)` does the same for the PDA's bare lamports via a System Program
transfer. As on EVM, all safety comes from the caller binding `(mint, recipient, min)` and from
funding and delivery sharing one transaction.

Two things make the SVM side **structurally safer** than its EVM twin, and the review should not
attempt to port EVM findings across:

- There is **no token-address argument to overload**, so no `address(0)` / `0xEeee…` sentinel exists
  and `deliver_token` can never be steered into a lamport sweep. Native value is reachable only
  through the separate `deliver_sol` instruction.
- Re-entrancy is structurally absent: SPL Token has no recipient hook, a System transfer executes no
  recipient code, and the runtime forbids non-self re-entrant CPI.

What the review should test is the caller side: whether a `eco-routes-svm` route can leave the vault
ATA funded across transaction boundaries, whether caller-supplied `SerializableAccountMeta` entries
can substitute the mint, the vault ATA, the recipient ATA, or the token program in a `deliver_token`
CPI, and whether the recipient account reaching `deliver_sol` can be attacker-chosen.

The review should **not** look for cross-repository IDL, discriminator, Borsh layout, PDA seed, or
version agreement between these two repos. There is none to check — see below.

## Integration assumptions

Evaluate with the following assumptions and trust boundaries.

- **There is no code dependency in either direction, today.** `eco-delivery`'s Solana program depends
  only on `anchor-lang` and `anchor-spl`; it imports nothing from `eco-routes-svm`, defines its own
  PDA seeds, and shares no Borsh types, no discriminators, and no hashing. `eco-routes-svm` contains
  no reference to the `deliver` program id. Nothing is deployed to devnet or mainnet.
  **Findings that assume a shared IDL, shared instruction discriminators, shared account layouts,
  cross-repo version drift, or agreement on hashing or address encoding are not applicable.** What
  `eco-delivery` borrows is convention only — the `Eco…` vanity id, per-cluster `[programs.*]` tables,
  and gitignored keypairs — all copied, not imported. Note one deliberate divergence:
  `eco-delivery` has **no `mainnet` feature flag**, because the program has no network-specific
  configuration at all, so a single build is correct on every cluster.
- **The intended composition** is the route's swap instruction depositing into the vault ATA — the
  associated token account of the `[b"vault"]` PDA for that mint — with `deliver_token` appended as a
  later instruction in the *same transaction*. `deliver` never pulls funds in.
- **The vault ATA must already exist.** The program never creates it; a route that has not funded it
  fails at account resolution with Anchor `3012 AccountNotInitialized`. That is fail-closed and
  intended.
- **The following are deliberate, documented decisions in `eco-delivery`, not defects.** They are
  stated in its `README.md`, in the module docs of
  `solana/programs/deliver/src/lib.rs`, and pinned by tests:
  - permissionless entry — any signer may invoke, no admin, no pause;
  - the recipient is never validated, `Pubkey::default()` included, with no recovery path;
  - the entire vault balance is swept, pre-existing dust included, with no `amount` argument;
  - `init_if_needed` creates the recipient ATA with the **permissionless caller** paying unrefunded
    rent (~0.002 SOL); any caller can impose that cost on themselves for an arbitrary recipient. The
    ATA constraints pin mint, authority and token program, so the usual re-initialization concern
    does not apply here;
  - no events; the `TransferChecked` CPI and the balance change are the record on the token path, and
    `deliver_sol` emits nothing at all, making native deliveries visible only in balance deltas;
  - `deliver_sol` drains the PDA to zero and lets the runtime reap it; it springs back when refunded.
- **Token-2022 scope.** `transfer_checked` forwards only its four accounts and drops
  `remaining_accounts`, so mints carrying a `TransferHook` extension **fail outright**. This is
  fail-closed and documented as out of scope, not a silent mishandling. `TransferFee` mints *are*
  supported and tested.
- **One genuine, documented hole, shared with the EVM side.** `min` is checked against the balance
  held **before** the transfer. A Token-2022 mint with a transfer fee can pass the check while the
  recipient is credited strictly less than `min`, and the instruction still succeeds. Pinned by
  `deliver_token_token2022_transfer_fee_recipient_gets_less_than_min`. Worth reporting only as
  "a `eco-routes-svm` route sends such a mint through `deliver` and relies on `min` as a user-facing
  guarantee".
- **Rent-exemption on a fresh recipient.** `deliver_sol` into an account that does not yet exist must
  leave it rent-exempt or the runtime rejects the transaction. This is documented and currently
  **untested** — the `deliver_sol` tests pre-fund their recipients. A route that sweeps a small
  lamport balance to a brand-new recipient is a legitimate thing to probe.
- **Caller-supplied account metadata is adversarial.** `eco-routes-svm` reconstructs
  `CalldataWithAccounts` from accounts supplied in the fulfilling transaction. `deliver`'s own Anchor
  constraints pin the vault authority by seeds, the vault ATA and recipient ATA by
  `associated_token::{mint, authority, token_program}`, and the token program by `Interface`, so
  substitution is rejected at account resolution. Verifying that those constraints hold under
  attacker-chosen account ordering and flags is in scope; assuming they are absent is not.
