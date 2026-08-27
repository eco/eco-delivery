use {
    crate::{constants::VAULT_SEED, error::DeliverError},
    anchor_lang::{
        prelude::*,
        system_program::{transfer, Transfer},
    },
};

/// Accounts for [`handle_deliver_sol`].
#[derive(Accounts)]
pub struct DeliverSol<'info> {
    /// The caller. Permissionless: any signer may invoke this. Pays the transaction fee and nothing
    /// else — unlike `deliver_token`, no rent is ever charged here.
    pub caller: Signer<'info>,

    /// CHECK: The vault authority PDA, seeds `[b"vault"]`. Its entire lamport balance is the thing
    /// being swept. Address is fully constrained by the seeds.
    ///
    /// This account must carry **zero data** for the sweep to work: the System Program refuses to
    /// move lamports out of an account that carries data. This program never allocates data at the
    /// PDA, so the property holds — and it is asserted against real runtime behavior in
    /// `deliver_sol_fails_when_vault_pda_carries_data`.
    #[account(mut, seeds = [VAULT_SEED], bump)]
    pub vault_authority: UncheckedAccount<'info>,

    /// CHECK: Caller-supplied recipient, never validated — see the WARNING in the module docs.
    ///
    /// Note the runtime's rent rule: if the recipient does not exist yet, the swept amount must be
    /// enough to leave it rent-exempt, or the whole transaction is rejected. There is no EVM
    /// counterpart to that.
    #[account(mut)]
    pub recipient: UncheckedAccount<'info>,

    pub system_program: Program<'info, System>,
}

/// Sweep the vault authority PDA's entire lamport balance to `recipient`, requiring at least `min`.
///
/// The SVM counterpart to EVM's `deliverNative(address recipient, uint256 min)`; `address(this).
/// balance` becomes the PDA's lamports and the call-based send becomes a System Program transfer
/// signed with the PDA seeds.
///
/// The drain is total — the PDA is left at zero lamports and the runtime reaps it. That is safe
/// precisely because the PDA holds no data and no rent-exempt state worth preserving; it springs
/// back into existence the next time anyone funds it.
///
/// The EVM sentinel encoding (`address(0)` and `0xEeee…eEEeE` both meaning "native") has no SVM
/// counterpart: there is no token argument to overload, so native value gets its own instruction
/// and nothing else. `deliver_token` cannot be tricked into a lamport sweep.
pub fn handle_deliver_sol(ctx: Context<DeliverSol>, min: u64) -> Result<()> {
    // The full lamport balance the PDA already holds, dust from previous flows included.
    let amount = ctx.accounts.vault_authority.lamports();

    require!(amount >= min, DeliverError::BalanceBelowMin);

    let bump = ctx.bumps.vault_authority;
    let vault_seeds: &[&[u8]] = &[VAULT_SEED, &[bump]];

    transfer(
        CpiContext::new_with_signer(
            ctx.accounts.system_program.key(),
            Transfer {
                from: ctx.accounts.vault_authority.to_account_info(),
                to: ctx.accounts.recipient.to_account_info(),
            },
            &[vault_seeds],
        ),
        amount,
    )
}
