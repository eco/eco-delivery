//! # `deliver` — an outcome verifier for SVM
//!
//! This program is the Solana encoding of a deliberately tiny primitive: it **delivers tokens it is
//! already holding** to a recipient, and fails unless the amount it holds meets a caller-supplied
//! minimum. It performs no swap. It pulls no funds in. Callers fund the vault first, then call.
//!
//! Its EVM twin is the same primitive in a different token model. The two are meant to be reasoned
//! about together, so argument order and semantics are kept aligned.
//!
//! ## Why this exists
//!
//! This is the **last step of a swap route**. A route is a chain of components nobody here wrote —
//! an aggregator, a bridge, an AMM hop, an RFQ filler — each with its own notion of slippage, its
//! own `minOut` semantics, and sometimes no guarantee at all. Rather than trust each provider's
//! promise, every route ends by depositing its output into the vault, and the floor is enforced
//! once, at the end, on the amount that actually arrived.
//!
//! That is why it knows nothing about swaps: the guarantee has to hold *regardless* of what ran in
//! front of it. And because the check happens once on the real output, the intermediate hops' own
//! slippage settings stop being a safety property — if the route under-delivers, this step fails
//! and the user keeps their input.
//!
//! **The guarantee, stated exactly:** if the instruction succeeds, the recipient was sent the
//! entire balance the vault held of that asset, and that balance was at least `min`. The WARNINGs
//! below are what that does not cover.
//!
//! **It only holds if funding and delivery are in the SAME TRANSACTION.** A balance sitting in the
//! vault between transactions does not merely sit at risk; it *belongs* to whoever calls next, for
//! a recipient of their choosing, and that is a valid in-spec use of this program by anyone. Put
//! the route's swap instruction and `deliver_token` in one transaction, with the swap's destination
//! set to the vault ATA. See `docs/INTEGRATING.md`.
//!
//! ## The primitive
//!
//! - **Sweep, not amount.** There is no `amount` argument. Every instruction sends the *entire*
//!   balance it finds. Whatever arrived is what gets delivered.
//! - **`min` is a floor on what arrived.** This program knows nothing about how the balance got
//!   there; it asserts a lower bound and forwards. In the route, though, `min` *is* the route's
//!   final `minOut` — enforced once, at the end, on the real output.
//! - **Stateless and permissionless.** No owner, no admin, no allowlist, no pause, and no program
//!   state beyond the vault PDA itself (which stores no data — it is only ever a signing authority).
//!   Any signer may call. Safety comes entirely from the caller binding `(mint, recipient, min)`
//!   upstream — typically an intent/settlement system. A wrong recipient is the caller's bug.
//! - **Holds no funds between calls.** The vault is a pass-through, never a treasury. Any balance
//!   sitting in it is unconditionally claimable by whoever calls next, and pre-existing dust is
//!   swept along with the current delivery. That is intended.
//! - **Verification is post-hoc.** The check reads a balance the vault already has.
//!
//! ## WARNING — `min` is checked PRE-TRANSFER against the HELD balance
//!
//! `deliver_token` reads the vault token account's `amount`, requires `amount >= min`, and only then
//! performs the transfer. It does **not** measure the recipient's balance delta.
//!
//! **Consequence, accepted deliberately:** for any mint that does not deliver exactly what was sent
//! — a Token-2022 mint with a `TransferFee` extension, a `TransferHook` that skims, a rebasing
//! design — the check can pass while **the recipient receives strictly less than `min`**. A
//! delivery of exactly `min` on a 5% fee mint credits the recipient `0.95 * min` and still succeeds.
//!
//! This is a known, tested hole (see the test
//! `deliver_token_token2022_transfer_fee_recipient_gets_less_than_min`), not an oversight. It is the price of the cheap form. If you route fee-bearing mints through this
//! program, `min` must be chosen with the fee already priced in, or you must not use this program.
//! The EVM side carries the identical caveat for fee-on-transfer ERC-20s.
//!
//! ## WARNING — the recipient is whatever the caller says it is
//!
//! `recipient` is an arbitrary caller-supplied account and is never validated. Passing
//! `Pubkey::default()` (the all-zero key, which is the System Program's address) is accepted like
//! any other key: `deliver_token` will create and fund an associated token account owned by it, and
//! `deliver_sol` will send the vault's entire lamport balance to it. There is no recovery path.
//! This mirrors the EVM side, where `address(0)` is an accepted (sentinel) input rather than a
//! revert. Bind the recipient upstream; this program will not catch an uninitialized one for you.
//!
//! ## Interface difference from EVM: the recipient token account
//!
//! On EVM the recipient is an address and `transfer` always lands. On SVM the recipient needs an
//! associated token account for the mint, and it may not exist. This program **creates it when
//! missing (`init_if_needed`), with the permissionless caller as the rent payer.** So calling
//! `deliver_token` can cost the caller rent (~0.002 SOL) that nobody refunds, and any caller can
//! force ATA creation for an arbitrary recipient at their own expense. This is a real interface
//! difference with no EVM counterpart; it is documented rather than hidden.
//!
//! ## Other deliberate choices
//!
//! - **No events.** On `deliver_token` that costs nothing: the SPL Token `TransferChecked` CPI and
//!   the resulting balance change are already the outcome record, so a program event would be
//!   redundant. The EVM side omits events for the same reason.
//!
//!   The rationale does **not** extend to `deliver_sol`. A System Program lamport transfer emits no
//!   program event, so a native delivery leaves nothing an indexer can subscribe to — it is visible
//!   only in the transaction's account balance deltas. EVM's `deliverNative` has the identical gap.
//! - **Zero balance with `min == 0` succeeds as a no-op.** The transfer is still issued, for exactly
//!   zero, matching the EVM reference which calls `safeTransfer(recipient, 0)`.
//! - **The vault token account is NOT closed after a sweep.** Its rent stays locked so the same
//!   vault ATA can be reused by the next flow without a re-creation cost. The vault authority PDA
//!   itself, by contrast, *is* reaped by `deliver_sol` (a full lamport drain leaves zero).
//! - **Token-2022 `TransferHook` mints are NOT supported.** The CPI passes exactly the four accounts
//!   `transfer_checked` needs and forwards nothing else, so a mint whose hook program requires
//!   extra accounts cannot be delivered — the transaction fails rather than silently misbehaving.
//!   Supporting them would mean resolving and forwarding the hook's account list. If a hook mint is
//!   ever in scope, that is the change to make. (`TransferFee` mints, by contrast, work — they just
//!   expose the `min` hole above, which is why the fee case is the one that is tested.)
//! - **Token-2022 `DefaultAccountState::Frozen` mints are NOT deliverable unaided.** Every token
//!   account for such a mint is created frozen, so `init_if_needed` produces a frozen recipient ATA
//!   and `transfer_checked` fails with `AccountFrozen`. The obstruction starts earlier than that:
//!   even the *vault* ATA is created frozen, so the vault cannot be funded until someone thaws it.
//!   This program holds no freeze authority and does not take one — a mint whose accounts default to
//!   frozen is a permissioned asset, and whoever holds that authority can re-freeze at any moment,
//!   so it is fundamentally incompatible with permissionless push-delivery.
//!
//!   Unlike `MemoTransfer`, this needs no program support: a caller holding the freeze authority can
//!   create and thaw the recipient ATA with ordinary **top-level** instructions in the same
//!   transaction, and delivery then succeeds unmodified. Pinned by
//!   `deliver_token_token2022_default_frozen_recipient_ata_is_rejected` and
//!   `deliver_token_token2022_default_frozen_succeeds_with_a_top_level_thaw`.
//! - **Re-entrancy.** Were a hook ever wired up, it could call back into this program. It would find
//!   a vault token account that has already been debited, so a nested `deliver_token` sweeps zero
//!   and either no-ops (`min == 0`) or fails the `min` check. There is no program state to corrupt.
//!
//! ## Vault layout
//!
//! One vault-authority PDA, seeds `[b"vault"]`, for the whole program. It holds **one associated
//! token account per mint** (the canonical ATA for `(vault_authority, mint, token_program)`), and it
//! may also hold bare lamports for `deliver_sol`. The PDA is never allocated any data — that is a
//! load-bearing property, because the System Program refuses to transfer lamports out of an account
//! that carries data, which would make `deliver_sol`'s full drain impossible. It is asserted in
//! `deliver_sol_fails_when_vault_pda_carries_data`.

pub mod constants;
pub mod error;
pub mod instructions;

use anchor_lang::prelude::*;

pub use constants::*;
pub use instructions::*;

declare_id!("EcoyzRRwsSsFz6i4YU6r28WGD9mamCtRi4Zc8w78FNjw");

#[program]
pub mod deliver {
    use super::*;

    /// Sweep the vault's entire balance of `mint` to `recipient`, failing unless the vault holds at
    /// least `min`.
    ///
    /// `min` is compared against the balance held **before** the transfer. See the module-level
    /// WARNING: on a fee-bearing mint the recipient can end up with less than `min`.
    pub fn deliver_token(ctx: Context<DeliverToken>, min: u64) -> Result<()> {
        instructions::deliver_token::handle_deliver_token(ctx, min)
    }

    /// Sweep the vault authority PDA's entire lamport balance to `recipient`, failing unless the
    /// PDA holds at least `min`. The SVM counterpart to EVM's `deliverNative`.
    ///
    /// The drain is total: the PDA is left with zero lamports and is reaped by the runtime. It is
    /// recreated for free the next time anyone sends lamports to it.
    pub fn deliver_sol(ctx: Context<DeliverSol>, min: u64) -> Result<()> {
        instructions::deliver_sol::handle_deliver_sol(ctx, min)
    }
}
