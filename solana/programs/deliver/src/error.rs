use anchor_lang::prelude::*;

#[error_code]
pub enum DeliverError {
    /// The balance the vault holds is below the caller-supplied floor. Mirrors the EVM revert
    /// string `"deliver: balance below min"` so the two sides read the same.
    #[msg("deliver: balance below min")]
    BalanceBelowMin,
}
