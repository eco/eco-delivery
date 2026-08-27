/**
 * The `0xEeee…` pseudo-address meaning "native ETH", the widely used convention.
 */
export const NATIVE_SENTINEL = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE" as const;

/**
 * The zero address, which `deliverToken` **also** treats as native ETH.
 *
 * This is a deliberate choice with a sharp edge: a caller whose `token` field was never
 * assigned does not get a revert, it gets its entire ETH balance swept to whatever
 * `recipient` it passed. Validate `token` upstream — see {@link isNativeSentinel}.
 */
export const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000" as const;

/** Both addresses that route `deliverToken` into the native path. */
export const NATIVE_SENTINELS = [ZERO_ADDRESS, NATIVE_SENTINEL] as const;

/** Seed of the Solana vault-authority PDA: `[b"vault"]`. */
export const VAULT_SEED_STRING = "vault" as const;

/** Anchor's first custom error code; `BalanceBelowMin` is `6000`. */
export const ANCHOR_ERROR_BALANCE_BELOW_MIN = 6000 as const;

/** The revert/abort message, deliberately identical on both VMs. */
export const BALANCE_BELOW_MIN_MESSAGE = "deliver: balance below min" as const;
