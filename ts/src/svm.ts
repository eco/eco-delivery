/**
 * Solana instruction builders. Requires `@solana/web3.js` and `@solana/spl-token`.
 *
 * Instruction data is an 8-byte Anchor discriminator (read from the generated IDL, so it
 * cannot drift) followed by a little-endian `u64`. No Anchor runtime is needed.
 */

import {PublicKey, SystemProgram, TransactionInstruction} from "@solana/web3.js";
import {
  ASSOCIATED_TOKEN_PROGRAM_ID,
  TOKEN_PROGRAM_ID,
  getAssociatedTokenAddressSync,
} from "@solana/spl-token";
import {deliverIdl, DELIVER_PROGRAM_ID} from "./generated/idl.js";
import {VAULT_SEED_STRING} from "./constants.js";

export {deliverIdl};

/** The default program id, from the IDL the contracts were built with. */
export const DELIVER_PROGRAM = new PublicKey(DELIVER_PROGRAM_ID);

/** SPL Memo (v3) — the program the optional memo account must be, when supplied. */
export const MEMO_PROGRAM = new PublicKey("MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr");

const VAULT_SEED = Buffer.from(VAULT_SEED_STRING, "utf8");
const U64_MAX = (1n << 64n) - 1n;

function discriminator(name: "deliver_token" | "deliver_sol"): readonly number[] {
  const ix = deliverIdl.instructions.find((i) => i.name === name);
  if (!ix) throw new Error(`instruction ${name} is not in the IDL`);
  return ix.discriminator;
}

function encodeIxData(disc: readonly number[], min: bigint): Buffer {
  if (min < 0n || min > U64_MAX) {
    throw new RangeError(`min must fit in a u64, got ${min}`);
  }
  const data = new Uint8Array(16);
  data.set(disc, 0);
  new DataView(data.buffer).setBigUint64(8, min, true);
  return Buffer.from(data);
}

/** The single vault-authority PDA at seeds `[b"vault"]`. */
export function vaultAuthority(programId: PublicKey = DELIVER_PROGRAM): PublicKey {
  return PublicKey.findProgramAddressSync([VAULT_SEED], programId)[0];
}

/**
 * The vault's associated token account for a mint — the account your route must deposit
 * into. It must already exist; the program never creates it.
 */
export function vaultTokenAccount(
  mint: PublicKey,
  tokenProgram: PublicKey = TOKEN_PROGRAM_ID,
  programId: PublicKey = DELIVER_PROGRAM,
): PublicKey {
  // allowOwnerOffCurve: the authority is a PDA and is off the ed25519 curve by construction.
  return getAssociatedTokenAddressSync(
    mint,
    vaultAuthority(programId),
    true,
    tokenProgram,
    ASSOCIATED_TOKEN_PROGRAM_ID,
  );
}

/** The recipient's associated token account, created by the instruction if absent. */
export function recipientTokenAccount(
  mint: PublicKey,
  recipient: PublicKey,
  tokenProgram: PublicKey = TOKEN_PROGRAM_ID,
): PublicKey {
  return getAssociatedTokenAddressSync(
    mint,
    recipient,
    true,
    tokenProgram,
    ASSOCIATED_TOKEN_PROGRAM_ID,
  );
}

export interface DeliverTokenIxArgs {
  /** Any signer. Pays the fee, and the recipient ATA rent if it has to be created. */
  payer: PublicKey;
  mint: PublicKey;
  /** Never validated by the program — bind it upstream. */
  recipient: PublicKey;
  /** Floor on the vault's held balance, in the mint's base units. */
  min: bigint;
  /** `TOKEN_PROGRAM_ID` or `TOKEN_2022_PROGRAM_ID`, whichever owns the mint. */
  tokenProgram?: PublicKey;
  /**
   * Set when the recipient's token account carries Token-2022's `MemoTransfer` extension with
   * memos required. The program then emits a memo immediately before the transfer, which is the
   * only place that requirement can be satisfied — Token-2022 checks the preceding *sibling*
   * instruction, so a memo you add to the transaction yourself does not count.
   *
   * Leaving it `false` costs nothing; the account slot is still sent, holding the program id,
   * which is how Anchor encodes an absent optional account.
   */
  requireMemo?: boolean;
  programId?: PublicKey;
}

/**
 * Sweep the vault's balance of `mint` to `recipient`.
 *
 * Put this in the **same transaction** as the swap that funds the vault ATA. On its own in
 * a later transaction, the balance is claimable by anyone.
 */
export function deliverTokenIx({
  payer,
  mint,
  recipient,
  min,
  tokenProgram = TOKEN_PROGRAM_ID,
  requireMemo = false,
  programId = DELIVER_PROGRAM,
}: DeliverTokenIxArgs): TransactionInstruction {
  return new TransactionInstruction({
    programId,
    data: encodeIxData(discriminator("deliver_token"), min),
    keys: [
      {pubkey: payer, isSigner: true, isWritable: true},
      {pubkey: vaultAuthority(programId), isSigner: false, isWritable: false},
      {pubkey: mint, isSigner: false, isWritable: false},
      {pubkey: vaultTokenAccount(mint, tokenProgram, programId), isSigner: false, isWritable: true},
      {pubkey: recipient, isSigner: false, isWritable: false},
      {
        pubkey: recipientTokenAccount(mint, recipient, tokenProgram),
        isSigner: false,
        isWritable: true,
      },
      {pubkey: tokenProgram, isSigner: false, isWritable: false},
      {pubkey: ASSOCIATED_TOKEN_PROGRAM_ID, isSigner: false, isWritable: false},
      {pubkey: SystemProgram.programId, isSigner: false, isWritable: false},
      // The optional memo account. Anchor encodes "absent" as the program's own id rather than by
      // omitting the slot, so this entry is always present — sending nine accounts is rejected
      // with `AccountNotEnoughKeys`.
      {pubkey: requireMemo ? MEMO_PROGRAM : programId, isSigner: false, isWritable: false},
    ],
  });
}

export interface DeliverSolIxArgs {
  caller: PublicKey;
  recipient: PublicKey;
  /** Floor on the vault PDA's lamports. */
  min: bigint;
  programId?: PublicKey;
}

/**
 * Sweep the vault PDA's lamports to `recipient` — the counterpart to EVM `deliverNative`.
 *
 * If `recipient` does not exist yet, the swept amount must leave it rent-exempt or the
 * runtime rejects the transaction. There is no EVM analogue to that rule.
 */
export function deliverSolIx({
  caller,
  recipient,
  min,
  programId = DELIVER_PROGRAM,
}: DeliverSolIxArgs): TransactionInstruction {
  return new TransactionInstruction({
    programId,
    data: encodeIxData(discriminator("deliver_sol"), min),
    keys: [
      {pubkey: caller, isSigner: true, isWritable: false},
      {pubkey: vaultAuthority(programId), isSigner: false, isWritable: true},
      {pubkey: recipient, isSigner: false, isWritable: true},
      {pubkey: SystemProgram.programId, isSigner: false, isWritable: false},
    ],
  });
}

/** True if a failed transaction failed on the `min` floor rather than anything else. */
export function isBalanceBelowMin(logs: readonly string[] | null | undefined): boolean {
  return !!logs?.some((l) => l.includes("deliver: balance below min"));
}
