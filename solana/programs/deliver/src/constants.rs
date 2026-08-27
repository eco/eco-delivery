use anchor_lang::prelude::*;

/// Seed of the single vault-authority PDA: `[b"vault"]`.
///
/// The PDA signs every outbound transfer. It owns one associated token account per mint and may
/// hold bare lamports for `deliver_sol`. It is never allocated data — see the module docs.
#[constant]
pub const VAULT_SEED: &[u8] = b"vault";
