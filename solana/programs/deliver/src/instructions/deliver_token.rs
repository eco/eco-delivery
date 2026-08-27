use {
    crate::{constants::VAULT_SEED, error::DeliverError},
    anchor_lang::prelude::*,
    anchor_spl::{
        associated_token::AssociatedToken,
        token_interface::{transfer_checked, Mint, TokenAccount, TokenInterface, TransferChecked},
    },
};

/// Accounts for [`handle_deliver_token`].
///
/// Nothing here is privileged. `payer` is any signer at all; it exists only to pay the transaction
/// fee and, when the recipient's associated token account does not yet exist, its rent.
#[derive(Accounts)]
pub struct DeliverToken<'info> {
    /// The caller. Permissionless: any signer may invoke this, and the program does not care who.
    ///
    /// Pays rent if `recipient_token_account` has to be created. Nothing refunds that rent.
    #[account(mut)]
    pub payer: Signer<'info>,

    /// CHECK: The vault authority PDA, seeds `[b"vault"]`. Never read, never written, never
    /// allocated data — it exists only to sign the outbound transfer. Address is fully constrained
    /// by the seeds, so an unchecked account is safe here.
    #[account(seeds = [VAULT_SEED], bump)]
    pub vault_authority: UncheckedAccount<'info>,

    /// The mint being delivered. Works for both SPL Token and Token-2022 mints.
    pub mint: InterfaceAccount<'info, Mint>,

    /// The vault's associated token account for `mint`. This is the balance that gets swept.
    ///
    /// It must already exist — this program never pulls funds in, so a caller that has not funded
    /// the vault has nothing to deliver and the transaction fails at account resolution.
    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = vault_authority,
        associated_token::token_program = token_program,
    )]
    pub vault_token_account: InterfaceAccount<'info, TokenAccount>,

    /// CHECK: Caller-supplied recipient, never validated — see the WARNING in the module docs. Any
    /// key is accepted, including `Pubkey::default()`. It is only used as the ATA authority.
    pub recipient: UncheckedAccount<'info>,

    /// The recipient's associated token account for `mint`.
    ///
    /// Created here if it does not exist, with `payer` funding the rent. This is the interface
    /// difference from EVM called out in the module docs.
    #[account(
        init_if_needed,
        payer = payer,
        associated_token::mint = mint,
        associated_token::authority = recipient,
        associated_token::token_program = token_program,
    )]
    pub recipient_token_account: InterfaceAccount<'info, TokenAccount>,

    /// SPL Token or Token-2022, whichever owns `mint`.
    ///
    /// Only the four accounts `transfer_checked` needs are forwarded to it, so Token-2022 mints
    /// carrying a `TransferHook` extension are out of scope — see the module docs.
    pub token_program: Interface<'info, TokenInterface>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub system_program: Program<'info, System>,
}

/// Sweep the vault's entire balance of `mint` to `recipient`, requiring at least `min`.
///
/// Mirrors the EVM reference line for line:
///
/// ```solidity
/// uint256 balance = token.balanceOf(address(this));
/// require(balance >= min, "deliver: balance below min");
/// token.safeTransfer(recipient, balance);
/// ```
///
/// The `require` reads the balance **held**, before the transfer. On a mint that takes a cut in
/// transit the recipient can be credited less than `min` while this still succeeds; that hole is
/// accepted and tested, not fixed. See the module docs.
///
/// `amount == 0` is not special-cased: a zero-balance vault with `min == 0` still issues a
/// zero-amount transfer and succeeds, exactly as `safeTransfer(recipient, 0)` does on EVM.
pub fn handle_deliver_token(ctx: Context<DeliverToken>, min: u64) -> Result<()> {
    // The balance the vault already holds. Includes any dust left behind by a previous flow —
    // sweeping that too is intended, not a leak.
    let amount = ctx.accounts.vault_token_account.amount;

    require!(amount >= min, DeliverError::BalanceBelowMin);

    let bump = ctx.bumps.vault_authority;
    let vault_seeds: &[&[u8]] = &[VAULT_SEED, &[bump]];

    transfer_checked(
        CpiContext::new_with_signer(
            ctx.accounts.token_program.key(),
            TransferChecked {
                from: ctx.accounts.vault_token_account.to_account_info(),
                mint: ctx.accounts.mint.to_account_info(),
                to: ctx.accounts.recipient_token_account.to_account_info(),
                authority: ctx.accounts.vault_authority.to_account_info(),
            },
            &[vault_seeds],
        ),
        amount,
        ctx.accounts.mint.decimals,
    )
}
