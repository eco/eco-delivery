//! Behavioral tests for the `deliver` outcome verifier, run against a real BPF build of the program
//! inside litesvm.
//!
//! These mirror the EVM suite case for case. Where a case cannot exist on one side, there is a
//! comment saying why. SVM-only cases (vault ATA must pre-exist, recipient ATA
//! creation, the PDA-carries-data assertion) are grouped at the end and marked as such.
//!
//! `anchor build` must run before `cargo test` — the program ELF is pulled in with `include_bytes!`.

// litesvm's `FailedTransactionMetadata` is a large type we do not own, and every helper here
// forwards its `TransactionResult` verbatim so failing tests can print real logs.
#![allow(clippy::result_large_err)]

use {
    anchor_lang::{
        prelude::Pubkey,
        solana_program::{
            instruction::Instruction, program_pack::Pack, system_instruction, system_program,
        },
        InstructionData, ToAccountMetas,
    },
    anchor_spl::{
        associated_token::{
            get_associated_token_address_with_program_id,
            spl_associated_token_account::instruction::create_associated_token_account,
            ID as ASSOCIATED_TOKEN_PROGRAM_ID,
        },
        memo::ID as MEMO_PROGRAM_ID,
        token::spl_token,
        token_2022::spl_token_2022,
    },
    litesvm::{types::TransactionResult, LiteSVM},
    proptest::prelude::*,
    solana_account::Account,
    solana_keypair::Keypair,
    solana_message::{Message, VersionedMessage},
    solana_signer::Signer,
    solana_transaction::versioned::VersionedTransaction,
};

const LAMPORTS_PER_SOL: u64 = 1_000_000_000;
const DECIMALS: u8 = 6;
/// 5% transfer fee, used to pin the documented "recipient can get less than `min`" hole.
const FEE_BPS: u16 = 500;

/// Anchor numbers custom errors from 6000; `DeliverError::BalanceBelowMin` is the first.
const ERR_BALANCE_BELOW_MIN: &str = "Custom(6000)";

// ---------------------------------------------------------------------------------------------
// harness
// ---------------------------------------------------------------------------------------------

fn new_svm() -> LiteSVM {
    let mut svm = LiteSVM::new();
    svm.add_program(
        deliver::ID,
        include_bytes!(concat!(
            env!("CARGO_TARGET_TMPDIR"),
            "/../deploy/deliver.so"
        )),
    )
    .unwrap();
    svm
}

fn vault_authority() -> Pubkey {
    Pubkey::find_program_address(&[deliver::constants::VAULT_SEED], &deliver::ID).0
}

fn funded_keypair(svm: &mut LiteSVM, sol: u64) -> Keypair {
    let kp = Keypair::new();
    svm.airdrop(&kp.pubkey(), sol * LAMPORTS_PER_SOL).unwrap();
    kp
}

fn send(
    svm: &mut LiteSVM,
    ixs: &[Instruction],
    payer: &Keypair,
    extra: &[&Keypair],
) -> TransactionResult {
    let blockhash = svm.latest_blockhash();
    let msg = Message::new_with_blockhash(ixs, Some(&payer.pubkey()), &blockhash);
    let mut signers: Vec<&Keypair> = vec![payer];
    signers.extend_from_slice(extra);
    let tx = VersionedTransaction::try_new(VersionedMessage::Legacy(msg), &signers).unwrap();
    let res = svm.send_transaction(tx);
    // Keep signatures unique across otherwise-identical transactions in the same test.
    svm.expire_blockhash();
    res
}

fn send_ok(
    svm: &mut LiteSVM,
    ixs: &[Instruction],
    payer: &Keypair,
    extra: &[&Keypair],
) -> litesvm::types::TransactionMetadata {
    match send(svm, ixs, payer, extra) {
        Ok(meta) => meta,
        Err(e) => panic!(
            "expected success, got {:?}\nlogs: {:#?}",
            e.err, e.meta.logs
        ),
    }
}

/// Assert the transaction failed on the `min` floor specifically — not on some unrelated error that
/// happens to also fail.
fn assert_below_min(res: TransactionResult) {
    let e = res.expect_err("expected `deliver: balance below min` but the transaction succeeded");
    let rendered = format!("{:?}", e.err);
    assert!(
        rendered.contains(ERR_BALANCE_BELOW_MIN),
        "expected {ERR_BALANCE_BELOW_MIN}, got {rendered}\nlogs: {:#?}",
        e.meta.logs
    );
    assert!(
        e.meta
            .logs
            .iter()
            .any(|l| l.contains("deliver: balance below min")),
        "expected the EVM-parity message in the logs, got {:#?}",
        e.meta.logs
    );
}

fn account_exists(svm: &LiteSVM, key: &Pubkey) -> bool {
    svm.get_account(key)
        .map(|a| a.lamports > 0)
        .unwrap_or(false)
}

/// Token balance of a token account, for either token program. `StateWithExtensions` reads a plain
/// 165-byte SPL Token account just as happily as a Token-2022 one that carries extensions.
fn token_balance(svm: &LiteSVM, key: &Pubkey) -> u64 {
    let acct = svm.get_account(key).expect("token account does not exist");
    spl_token_2022::extension::StateWithExtensions::<spl_token_2022::state::Account>::unpack(
        &acct.data,
    )
    .expect("not a token account")
    .base
    .amount
}

// ---------------------------------------------------------------------------------------------
// token-program dispatch (each interface crate rejects the other program's id)
// ---------------------------------------------------------------------------------------------

fn ix_initialize_mint2(token_program: &Pubkey, mint: &Pubkey, authority: &Pubkey) -> Instruction {
    if *token_program == spl_token::ID {
        spl_token::instruction::initialize_mint2(token_program, mint, authority, None, DECIMALS)
            .unwrap()
    } else {
        spl_token_2022::instruction::initialize_mint2(
            token_program,
            mint,
            authority,
            None,
            DECIMALS,
        )
        .unwrap()
    }
}

fn ix_mint_to(
    token_program: &Pubkey,
    mint: &Pubkey,
    to: &Pubkey,
    authority: &Pubkey,
    amount: u64,
) -> Instruction {
    if *token_program == spl_token::ID {
        spl_token::instruction::mint_to(token_program, mint, to, authority, &[], amount).unwrap()
    } else {
        spl_token_2022::instruction::mint_to(token_program, mint, to, authority, &[], amount)
            .unwrap()
    }
}

// ---------------------------------------------------------------------------------------------
// scenario setup
// ---------------------------------------------------------------------------------------------

struct Fixture {
    svm: LiteSVM,
    payer: Keypair,
    mint_authority: Keypair,
    mint: Pubkey,
    token_program: Pubkey,
    vault: Pubkey,
    vault_ata: Pubkey,
}

/// Stand up a mint (optionally with a Token-2022 transfer fee) plus the vault's ATA for it.
///
/// The vault ATA is created but left empty; funding it is each test's business, because "the caller
/// funds the vault first, then calls" is the whole shape of the primitive.
fn fixture(token_program: Pubkey, fee_bps: Option<u16>) -> Fixture {
    let mut svm = new_svm();
    let payer = funded_keypair(&mut svm, 100);
    let mint_authority = funded_keypair(&mut svm, 10);
    let mint_kp = Keypair::new();
    let mint = mint_kp.pubkey();

    let space = match fee_bps {
        None => spl_token_2022::state::Mint::LEN,
        Some(_) => spl_token_2022::extension::ExtensionType::try_calculate_account_len::<
            spl_token_2022::state::Mint,
        >(&[spl_token_2022::extension::ExtensionType::TransferFeeConfig])
        .unwrap(),
    };

    let mut ixs = vec![system_instruction::create_account(
        &payer.pubkey(),
        &mint,
        svm.minimum_balance_for_rent_exemption(space),
        space as u64,
        &token_program,
    )];
    if let Some(bps) = fee_bps {
        assert_eq!(
            token_program,
            spl_token_2022::ID,
            "transfer fees only exist on Token-2022"
        );
        ixs.push(
            spl_token_2022::extension::transfer_fee::instruction::initialize_transfer_fee_config(
                &token_program,
                &mint,
                Some(&mint_authority.pubkey()),
                Some(&mint_authority.pubkey()),
                bps,
                u64::MAX, // no cap, so the fee is purely proportional
            )
            .unwrap(),
        );
    }
    ixs.push(ix_initialize_mint2(
        &token_program,
        &mint,
        &mint_authority.pubkey(),
    ));
    send_ok(&mut svm, &ixs, &payer, &[&mint_kp]);

    let vault = vault_authority();
    let vault_ata = get_associated_token_address_with_program_id(&vault, &mint, &token_program);
    send_ok(
        &mut svm,
        &[create_associated_token_account(
            &payer.pubkey(),
            &vault,
            &mint,
            &token_program,
        )],
        &payer,
        &[],
    );

    Fixture {
        svm,
        payer,
        mint_authority,
        mint,
        token_program,
        vault,
        vault_ata,
    }
}

fn spl_fixture() -> Fixture {
    fixture(spl_token::ID, None)
}

impl Fixture {
    /// Put tokens into the vault. This is the "caller funds the contract first" step; the program
    /// itself never pulls funds in.
    fn fund_vault(&mut self, amount: u64) {
        let ix = ix_mint_to(
            &self.token_program,
            &self.mint,
            &self.vault_ata,
            &self.mint_authority.pubkey(),
            amount,
        );
        let mint_authority = self.mint_authority.insecure_clone();
        send_ok(&mut self.svm, &[ix], &mint_authority, &[]);
    }

    fn recipient_ata(&self, recipient: &Pubkey) -> Pubkey {
        get_associated_token_address_with_program_id(recipient, &self.mint, &self.token_program)
    }

    fn deliver_token_ix(&self, caller: &Pubkey, recipient: &Pubkey, min: u64) -> Instruction {
        self.deliver_token_ix_inner(caller, recipient, min, None)
    }

    /// Same, but supplying the optional SPL Memo program so the handler emits a memo before the
    /// transfer — what a caller delivering into a memo-required Token-2022 account must do.
    fn deliver_token_ix_with_memo(
        &self,
        caller: &Pubkey,
        recipient: &Pubkey,
        min: u64,
    ) -> Instruction {
        self.deliver_token_ix_inner(caller, recipient, min, Some(MEMO_PROGRAM_ID))
    }

    fn deliver_token_ix_inner(
        &self,
        caller: &Pubkey,
        recipient: &Pubkey,
        min: u64,
        memo_program: Option<Pubkey>,
    ) -> Instruction {
        Instruction::new_with_bytes(
            deliver::ID,
            &deliver::instruction::DeliverToken { min }.data(),
            deliver::accounts::DeliverToken {
                payer: *caller,
                vault_authority: self.vault,
                mint: self.mint,
                vault_token_account: self.vault_ata,
                recipient: *recipient,
                recipient_token_account: self.recipient_ata(recipient),
                token_program: self.token_program,
                associated_token_program: ASSOCIATED_TOKEN_PROGRAM_ID,
                system_program: system_program::ID,
                memo_program,
            }
            .to_account_metas(None),
        )
    }

    fn deliver(&mut self, recipient: &Pubkey, min: u64) -> TransactionResult {
        let payer = self.payer.insecure_clone();
        let ix = self.deliver_token_ix(&payer.pubkey(), recipient, min);
        send(&mut self.svm, &[ix], &payer, &[])
    }
}

fn deliver_sol_ix(caller: &Pubkey, recipient: &Pubkey, min: u64) -> Instruction {
    Instruction::new_with_bytes(
        deliver::ID,
        &deliver::instruction::DeliverSol { min }.data(),
        deliver::accounts::DeliverSol {
            caller: *caller,
            vault_authority: vault_authority(),
            recipient: *recipient,
            system_program: system_program::ID,
        }
        .to_account_metas(None),
    )
}

// =============================================================================================
// deliver_token — mirrors the EVM `deliverToken` suite
// =============================================================================================

#[test]
fn deliver_token_sweeps_the_full_balance_not_a_partial_amount() {
    let mut f = spl_fixture();
    let recipient = Pubkey::new_unique();
    f.fund_vault(1_000_000);

    f.deliver(&recipient, 1).unwrap();

    // The whole balance moved. There is no amount parameter to ask for less.
    assert_eq!(
        token_balance(&f.svm, &f.recipient_ata(&recipient)),
        1_000_000
    );
    assert_eq!(token_balance(&f.svm, &f.vault_ata), 0);
}

#[test]
fn deliver_token_reverts_when_balance_is_below_min() {
    let mut f = spl_fixture();
    let recipient = Pubkey::new_unique();
    f.fund_vault(500_000);

    assert_below_min(f.deliver(&recipient, 1_000_000));

    // Nothing moved and no ATA was created for the recipient — the whole transaction rolled back.
    assert_eq!(token_balance(&f.svm, &f.vault_ata), 500_000);
    assert!(!account_exists(&f.svm, &f.recipient_ata(&recipient)));
}

#[test]
fn deliver_token_reverts_at_the_boundary_balance_equals_min_minus_one() {
    let mut f = spl_fixture();
    let recipient = Pubkey::new_unique();
    let min = 1_000_000;
    f.fund_vault(min - 1);

    assert_below_min(f.deliver(&recipient, min));
    assert_eq!(token_balance(&f.svm, &f.vault_ata), min - 1);
}

#[test]
fn deliver_token_succeeds_when_balance_equals_min_exactly() {
    let mut f = spl_fixture();
    let recipient = Pubkey::new_unique();
    let min = 1_000_000;
    f.fund_vault(min);

    f.deliver(&recipient, min).unwrap();

    assert_eq!(token_balance(&f.svm, &f.recipient_ata(&recipient)), min);
    assert_eq!(token_balance(&f.svm, &f.vault_ata), 0);
}

#[test]
fn deliver_token_sweeps_pre_existing_dust_along_with_the_delivery() {
    let mut f = spl_fixture();
    let recipient = Pubkey::new_unique();

    // Dust left behind by some earlier, unrelated flow.
    f.fund_vault(7);
    // The delivery this caller actually expects.
    f.fund_vault(1_000_000);

    // `min` is a floor on what arrived, so the caller can only bind the amount it knows about...
    f.deliver(&recipient, 1_000_000).unwrap();

    // ...and the dust rides along. Intended: the vault holds nothing between calls.
    assert_eq!(
        token_balance(&f.svm, &f.recipient_ata(&recipient)),
        1_000_007
    );
    assert_eq!(token_balance(&f.svm, &f.vault_ata), 0);
}

#[test]
fn deliver_token_is_permissionless_an_unrelated_caller_can_invoke_it() {
    let mut f = spl_fixture();
    let recipient = Pubkey::new_unique();
    f.fund_vault(1_000_000);

    // A signer with no relationship to the vault, the mint, the mint authority, or the recipient.
    let stranger = funded_keypair(&mut f.svm, 10);
    let ix = f.deliver_token_ix(&stranger.pubkey(), &recipient, 1_000_000);
    send_ok(&mut f.svm, &[ix], &stranger, &[]);

    assert_eq!(
        token_balance(&f.svm, &f.recipient_ata(&recipient)),
        1_000_000
    );
    assert_eq!(token_balance(&f.svm, &f.vault_ata), 0);
}

#[test]
fn deliver_token_zero_balance_with_min_zero_succeeds_as_a_noop() {
    let mut f = spl_fixture();
    let recipient = Pubkey::new_unique();
    // Vault ATA exists but holds nothing.
    assert_eq!(token_balance(&f.svm, &f.vault_ata), 0);

    let meta = f.deliver(&recipient, 0).unwrap();

    // A zero-amount transfer is still *issued* — not skipped — matching EVM's
    // `safeTransfer(recipient, 0)`. The token program logs the instruction it ran.
    assert!(
        meta.logs
            .iter()
            .any(|l| l.contains("Instruction: TransferChecked")),
        "expected a real zero-amount TransferChecked, got {:#?}",
        meta.logs
    );
    assert_eq!(token_balance(&f.svm, &f.recipient_ata(&recipient)), 0);
}

#[test]
fn deliver_token_zero_balance_with_nonzero_min_reverts() {
    let mut f = spl_fixture();
    let recipient = Pubkey::new_unique();

    assert_below_min(f.deliver(&recipient, 1));
}

#[test]
fn deliver_token_works_with_a_token_2022_mint() {
    let mut f = fixture(spl_token_2022::ID, None);
    let recipient = Pubkey::new_unique();
    f.fund_vault(1_000_000);

    f.deliver(&recipient, 1_000_000).unwrap();

    // No fee extension: `transfer_checked` delivers exactly what was held.
    assert_eq!(
        token_balance(&f.svm, &f.recipient_ata(&recipient)),
        1_000_000
    );
    assert_eq!(token_balance(&f.svm, &f.vault_ata), 0);
}

/// **This test pins the documented hole, it does not report a bug.**
///
/// `min` is checked against the balance the vault HOLDS, before the transfer. On a Token-2022 mint
/// with a `TransferFee`, the token program skims the fee in transit, so the recipient is credited
/// strictly less than `min` and the instruction still succeeds. That is the accepted cost of the
/// cheap pre-transfer form; the EVM side has the identical hole for fee-on-transfer ERC-20s.
#[test]
fn deliver_token_token2022_transfer_fee_recipient_gets_less_than_min() {
    let mut f = fixture(spl_token_2022::ID, Some(FEE_BPS));
    let recipient = Pubkey::new_unique();

    let held = 1_000_000u64;
    let fee = held * FEE_BPS as u64 / 10_000; // 5%, exact at this amount
    f.fund_vault(held);

    // The caller demands the full amount as a floor, and the check passes...
    f.deliver(&recipient, held).unwrap();

    // ...but the recipient is short by the fee.
    let received = token_balance(&f.svm, &f.recipient_ata(&recipient));
    assert_eq!(received, held - fee);
    assert!(
        received < held,
        "the documented hole: recipient received {received} against a floor of {held}"
    );
    // The vault is still fully drained — the fee is withheld on the recipient's account.
    assert_eq!(token_balance(&f.svm, &f.vault_ata), 0);
}

// =============================================================================================
// deliver_sol — mirrors the EVM `deliverNative` suite
// =============================================================================================
//
// The EVM side additionally tests that `address(0)` and `0xEeee…eEEeE` route `deliverToken` into
// the native path. Those cases cannot exist here: SVM has no token-address argument to overload,
// so native value is reachable only through its own instruction and `deliver_token` can never be
// tricked into a lamport sweep.

#[test]
fn deliver_sol_sweeps_the_full_lamport_balance() {
    let mut svm = new_svm();
    let caller = funded_keypair(&mut svm, 10);
    let recipient = funded_keypair(&mut svm, 1);
    let vault = vault_authority();
    svm.airdrop(&vault, 3 * LAMPORTS_PER_SOL).unwrap();

    let before = svm.get_balance(&recipient.pubkey()).unwrap();
    send_ok(
        &mut svm,
        &[deliver_sol_ix(&caller.pubkey(), &recipient.pubkey(), 1)],
        &caller,
        &[],
    );

    assert_eq!(
        svm.get_balance(&recipient.pubkey()).unwrap(),
        before + 3 * LAMPORTS_PER_SOL
    );
    // Full drain: the PDA is left at zero and reaped. This only works because it carries no data.
    assert_eq!(svm.get_balance(&vault).unwrap_or(0), 0);
}

#[test]
fn deliver_sol_reverts_at_the_boundary_balance_equals_min_minus_one() {
    let mut svm = new_svm();
    let caller = funded_keypair(&mut svm, 10);
    let recipient = funded_keypair(&mut svm, 1);
    let vault = vault_authority();
    let held = 2 * LAMPORTS_PER_SOL;
    svm.airdrop(&vault, held).unwrap();

    assert_below_min(send(
        &mut svm,
        &[deliver_sol_ix(
            &caller.pubkey(),
            &recipient.pubkey(),
            held + 1,
        )],
        &caller,
        &[],
    ));
    assert_eq!(svm.get_balance(&vault).unwrap(), held);
}

#[test]
fn deliver_sol_succeeds_when_balance_equals_min_exactly() {
    let mut svm = new_svm();
    let caller = funded_keypair(&mut svm, 10);
    let recipient = funded_keypair(&mut svm, 1);
    let vault = vault_authority();
    let held = 2 * LAMPORTS_PER_SOL;
    svm.airdrop(&vault, held).unwrap();

    let before = svm.get_balance(&recipient.pubkey()).unwrap();
    send_ok(
        &mut svm,
        &[deliver_sol_ix(&caller.pubkey(), &recipient.pubkey(), held)],
        &caller,
        &[],
    );

    assert_eq!(svm.get_balance(&recipient.pubkey()).unwrap(), before + held);
    assert_eq!(svm.get_balance(&vault).unwrap_or(0), 0);
}

#[test]
fn deliver_sol_sweeps_pre_existing_dust() {
    let mut svm = new_svm();
    let caller = funded_keypair(&mut svm, 10);
    let recipient = funded_keypair(&mut svm, 1);
    let vault = vault_authority();

    svm.airdrop(&vault, LAMPORTS_PER_SOL).unwrap(); // dust from an earlier flow
    svm.airdrop(&vault, 2 * LAMPORTS_PER_SOL).unwrap(); // this delivery

    let before = svm.get_balance(&recipient.pubkey()).unwrap();
    send_ok(
        &mut svm,
        &[deliver_sol_ix(
            &caller.pubkey(),
            &recipient.pubkey(),
            2 * LAMPORTS_PER_SOL,
        )],
        &caller,
        &[],
    );

    assert_eq!(
        svm.get_balance(&recipient.pubkey()).unwrap(),
        before + 3 * LAMPORTS_PER_SOL
    );
    assert_eq!(svm.get_balance(&vault).unwrap_or(0), 0);
}

#[test]
fn deliver_sol_is_permissionless_an_unrelated_caller_can_invoke_it() {
    let mut svm = new_svm();
    let recipient = funded_keypair(&mut svm, 1);
    let vault = vault_authority();
    svm.airdrop(&vault, 2 * LAMPORTS_PER_SOL).unwrap();

    let stranger = funded_keypair(&mut svm, 5);
    let before = svm.get_balance(&recipient.pubkey()).unwrap();
    send_ok(
        &mut svm,
        &[deliver_sol_ix(&stranger.pubkey(), &recipient.pubkey(), 1)],
        &stranger,
        &[],
    );

    assert_eq!(
        svm.get_balance(&recipient.pubkey()).unwrap(),
        before + 2 * LAMPORTS_PER_SOL
    );
}

#[test]
fn deliver_sol_zero_balance_with_min_zero_succeeds_as_a_noop() {
    let mut svm = new_svm();
    let caller = funded_keypair(&mut svm, 10);
    let recipient = funded_keypair(&mut svm, 1);
    let vault = vault_authority();
    assert_eq!(svm.get_balance(&vault).unwrap_or(0), 0);

    let before = svm.get_balance(&recipient.pubkey()).unwrap();
    send_ok(
        &mut svm,
        &[deliver_sol_ix(&caller.pubkey(), &recipient.pubkey(), 0)],
        &caller,
        &[],
    );

    assert_eq!(svm.get_balance(&recipient.pubkey()).unwrap(), before);
    assert_eq!(svm.get_balance(&vault).unwrap_or(0), 0);
}

#[test]
fn deliver_sol_zero_balance_with_nonzero_min_reverts() {
    let mut svm = new_svm();
    let caller = funded_keypair(&mut svm, 10);
    let recipient = funded_keypair(&mut svm, 1);

    assert_below_min(send(
        &mut svm,
        &[deliver_sol_ix(&caller.pubkey(), &recipient.pubkey(), 1)],
        &caller,
        &[],
    ));
}

// =============================================================================================
// SVM-only cases — properties the EVM side has no counterpart for
// =============================================================================================

/// The vault PDA must carry zero data or the full drain is impossible: the System Program refuses
/// to move lamports out of an account with data. The program never allocates data at the PDA, but
/// that assumption is worth checking against the runtime rather than trusting.
#[test]
fn deliver_sol_fails_when_vault_pda_carries_data() {
    let mut svm = new_svm();
    let caller = funded_keypair(&mut svm, 10);
    let recipient = funded_keypair(&mut svm, 1);
    let vault = vault_authority();

    // Force the counterfactual: a system-owned PDA that does carry data.
    svm.set_account(
        vault,
        Account {
            lamports: 2 * LAMPORTS_PER_SOL,
            data: vec![0u8; 8],
            owner: system_program::ID,
            executable: false,
            rent_epoch: 0,
        },
    )
    .unwrap();

    let res = send(
        &mut svm,
        &[deliver_sol_ix(&caller.pubkey(), &recipient.pubkey(), 1)],
        &caller,
        &[],
    );
    let e = res.expect_err("a data-carrying PDA must not be drainable");
    assert!(
        e.meta
            .logs
            .iter()
            .any(|l| l.contains("must not carry data")),
        "expected the System Program's data refusal, got {:#?}",
        e.meta.logs
    );
    assert_eq!(svm.get_balance(&vault).unwrap(), 2 * LAMPORTS_PER_SOL);
}

/// EVM has no counterpart: the recipient there is an address that always exists. Here the ATA may
/// not, and this instruction creates it with the permissionless caller paying the rent.
#[test]
fn deliver_token_creates_the_recipient_ata_when_it_does_not_exist() {
    let mut f = spl_fixture();
    let recipient = Pubkey::new_unique();
    let recipient_ata = f.recipient_ata(&recipient);
    f.fund_vault(1_000_000);

    assert!(!account_exists(&f.svm, &recipient_ata));

    let stranger = funded_keypair(&mut f.svm, 10);
    let before = f.svm.get_balance(&stranger.pubkey()).unwrap();
    let ix = f.deliver_token_ix(&stranger.pubkey(), &recipient, 1_000_000);
    send_ok(&mut f.svm, &[ix], &stranger, &[]);

    assert!(account_exists(&f.svm, &recipient_ata));
    assert_eq!(token_balance(&f.svm, &recipient_ata), 1_000_000);

    // The caller — not the recipient, not the vault — paid for it, and nothing refunds them.
    let rent = f
        .svm
        .minimum_balance_for_rent_exemption(spl_token::state::Account::LEN);
    let after = f.svm.get_balance(&stranger.pubkey()).unwrap();
    assert!(
        before - after >= rent,
        "caller should have paid at least {rent} lamports of rent, paid {}",
        before - after
    );
}

/// EVM has no counterpart: there, a token balance of zero is simply zero. Here the vault's token
/// account is a distinct account that must already exist. The program never pulls funds in, so a
/// caller who has not funded the vault has nothing to deliver and the transaction cannot resolve.
#[test]
fn deliver_token_fails_when_the_vault_ata_does_not_exist() {
    // Deliberately does not use `fixture`, which creates the vault ATA.
    let mut svm = new_svm();
    let payer = funded_keypair(&mut svm, 100);
    let mint_kp = Keypair::new();
    let space = spl_token_2022::state::Mint::LEN;
    let mint_rent = svm.minimum_balance_for_rent_exemption(space);
    send_ok(
        &mut svm,
        &[
            system_instruction::create_account(
                &payer.pubkey(),
                &mint_kp.pubkey(),
                mint_rent,
                space as u64,
                &spl_token::ID,
            ),
            ix_initialize_mint2(&spl_token::ID, &mint_kp.pubkey(), &payer.pubkey()),
        ],
        &payer,
        &[&mint_kp],
    );

    let vault = vault_authority();
    let f = Fixture {
        payer: payer.insecure_clone(),
        mint_authority: payer.insecure_clone(),
        mint: mint_kp.pubkey(),
        token_program: spl_token::ID,
        vault,
        vault_ata: get_associated_token_address_with_program_id(
            &vault,
            &mint_kp.pubkey(),
            &spl_token::ID,
        ),
        svm,
    };
    let recipient = Pubkey::new_unique();
    let ix = f.deliver_token_ix(&payer.pubkey(), &recipient, 0);
    let mut svm = f.svm;
    let res = send(&mut svm, &[ix], &payer, &[]);
    let e = res.expect_err("an unfunded vault has nothing to deliver");
    // Anchor 3012 = AccountNotInitialized, raised on `vault_token_account` specifically.
    assert!(
        format!("{:?}", e.err).contains("Custom(3012)"),
        "expected AccountNotInitialized, got {:?}\nlogs: {:#?}",
        e.err,
        e.meta.logs
    );
    assert!(
        e.meta
            .logs
            .iter()
            .any(|l| { l.contains("vault_token_account") && l.contains("AccountNotInitialized") }),
        "expected the failure to name the vault token account, got {:#?}",
        e.meta.logs
    );
}

// =============================================================================================
// property / fuzz tests — the SVM counterpart to the EVM suite's `testFuzz_*` cases
// =============================================================================================
//
// Foundry fuzzes 4096 runs per property in-process against a fresh EVM state. Each case here boots
// a whole LiteSVM, loads the BPF ELF and lands several real transactions, so the case count is
// deliberately lower — the wall clock is dominated by VM setup, not by the property being checked.
//
// `testFuzz_SentinelBoundaryBalanceVersusMin` has no counterpart here and cannot have one: there is
// no token-address argument on this side to overload with a sentinel, so `deliver_token` can never
// be steered into the lamport path. See PARITY.md.

const FUZZ_CASES: u32 = 256;

/// `(balance, min)` pairs weighted toward the boundary.
///
/// Two independent uniform draws over a 64-bit space would essentially never produce
/// `balance == min`, which is exactly the case the floor check turns on. So most draws straddle the
/// boundary by ±2, with a small dense region and wide independent draws mixed in.
fn balance_and_min() -> impl Strategy<Value = (u64, u64)> {
    prop_oneof![
        4 => (1u64..=u64::MAX / 4, -2i64..=2i64)
            .prop_map(|(balance, delta)| (balance, balance.saturating_add_signed(delta))),
        1 => (0u64..=8, 0u64..=8),
        1 => (0u64..=u64::MAX / 4, 0u64..=u64::MAX / 4),
    ]
}

/// The same shape for lamports, bounded to 100k SOL so airdrops stay in a realistic range.
fn lamports_and_min() -> impl Strategy<Value = (u64, u64)> {
    const MAX: u64 = 100_000 * LAMPORTS_PER_SOL;
    prop_oneof![
        4 => (1u64..=MAX, -2i64..=2i64)
            .prop_map(|(balance, delta)| (balance, balance.saturating_add_signed(delta))),
        1 => (0u64..=8, 0u64..=8),
        1 => (0u64..=MAX, 0u64..=MAX),
    ]
}

fn err_text(res: &TransactionResult) -> String {
    res.as_ref()
        .err()
        .map(|e| format!("{:?} logs: {:?}", e.err, e.meta.logs))
        .unwrap_or_default()
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(FUZZ_CASES))]

    /// Counterpart to `testFuzz_BoundaryBalanceVersusMin`.
    ///
    /// The property: the call succeeds iff `balance >= min`; success moves the *entire* balance and
    /// leaves the vault at zero; failure moves nothing at all.
    #[test]
    fn fuzz_deliver_token_boundary_balance_versus_min((balance, min) in balance_and_min()) {
        let mut f = spl_fixture();
        f.fund_vault(balance);
        let recipient = Pubkey::new_unique();
        let recipient_ata = f.recipient_ata(&recipient);

        let res = f.deliver(&recipient, min);
        let rendered = err_text(&res);

        if balance < min {
            prop_assert!(res.is_err(), "balance {} < min {} must revert", balance, min);
            prop_assert!(
                rendered.contains(ERR_BALANCE_BELOW_MIN),
                "expected {ERR_BALANCE_BELOW_MIN}, got {rendered}"
            );
            // A reverted delivery is atomic: the vault keeps everything and no ATA was created.
            prop_assert_eq!(token_balance(&f.svm, &f.vault_ata), balance);
            prop_assert!(!account_exists(&f.svm, &recipient_ata));
        } else {
            prop_assert!(res.is_ok(), "balance {} >= min {} must succeed: {rendered}", balance, min);
            prop_assert_eq!(token_balance(&f.svm, &recipient_ata), balance);
            prop_assert_eq!(token_balance(&f.svm, &f.vault_ata), 0);
        }
    }

    /// Counterpart to `testFuzz_AnyCallerSweepsFullBalance`.
    ///
    /// Permissionless is a load-bearing property, not an accident: an arbitrary signer with no
    /// relationship to the vault, the mint or the fixture payer sweeps the full balance to an
    /// arbitrary recipient key.
    #[test]
    fn fuzz_any_caller_sweeps_full_balance_to_any_recipient(
        balance in 0u64..=u64::MAX / 4,
        recipient_bytes in any::<[u8; 32]>(),
    ) {
        let recipient = Pubkey::new_from_array(recipient_bytes);
        // Delivering to the vault itself would make source and destination the same account.
        prop_assume!(recipient != vault_authority());

        let mut f = spl_fixture();
        f.fund_vault(balance);

        let stranger = funded_keypair(&mut f.svm, 10);
        let ix = f.deliver_token_ix(&stranger.pubkey(), &recipient, balance);
        let res = send(&mut f.svm, &[ix], &stranger, &[]);
        let rendered = err_text(&res);

        prop_assert!(res.is_ok(), "an unrelated caller must be able to deliver: {rendered}");
        prop_assert_eq!(token_balance(&f.svm, &f.recipient_ata(&recipient)), balance);
        prop_assert_eq!(token_balance(&f.svm, &f.vault_ata), 0);
    }

    /// Counterpart to `testFuzz_NativeBoundaryBalanceVersusMin`.
    #[test]
    fn fuzz_deliver_sol_boundary_balance_versus_min((balance, min) in lamports_and_min()) {
        let mut svm = new_svm();
        let caller = funded_keypair(&mut svm, 10);
        let vault = vault_authority();

        // The recipient is pre-funded so it already exists. A System transfer into a *new* account
        // must leave that account rent-exempt, and that rule would otherwise confound this
        // property at small sweep amounts — it is a separate concern from the `min` floor.
        let recipient = Pubkey::new_unique();
        let rent_exempt = svm.minimum_balance_for_rent_exemption(0);
        svm.airdrop(&recipient, rent_exempt).unwrap();

        if balance > 0 {
            svm.airdrop(&vault, balance).unwrap();
        }

        let ix = deliver_sol_ix(&caller.pubkey(), &recipient, min);
        let res = send(&mut svm, &[ix], &caller, &[]);
        let rendered = err_text(&res);

        let vault_lamports = |svm: &LiteSVM| svm.get_account(&vault).map(|a| a.lamports).unwrap_or(0);

        if balance < min {
            prop_assert!(res.is_err(), "balance {} < min {} must revert", balance, min);
            prop_assert!(
                rendered.contains(ERR_BALANCE_BELOW_MIN),
                "expected {ERR_BALANCE_BELOW_MIN}, got {rendered}"
            );
            prop_assert_eq!(vault_lamports(&svm), balance);
            prop_assert_eq!(svm.get_account(&recipient).unwrap().lamports, rent_exempt);
        } else {
            prop_assert!(res.is_ok(), "balance {} >= min {} must succeed: {rendered}", balance, min);
            // The drain is total; the runtime reaps the emptied PDA.
            prop_assert_eq!(vault_lamports(&svm), 0);
            prop_assert_eq!(
                svm.get_account(&recipient).unwrap().lamports,
                rent_exempt + balance
            );
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Token-2022 MemoTransfer (Octane 66f2d780)
// ---------------------------------------------------------------------------------------------
//
// A recipient may enable `MemoTransfer` on their own ATA, which makes Token-2022 require that the
// instruction *immediately preceding the transfer, at the same CPI stack height* be a memo. It
// enforces that with the `get_processed_sibling_instruction` syscall — no Instructions sysvar and
// no extra account is involved, so a memo placed at the top level of the transaction does not
// satisfy a transfer issued from inside `deliver_token`. A caller therefore cannot work around
// this from outside the program.

/// Give `owner`'s ATA for the fixture mint the MemoTransfer extension, with memos required.
///
/// The ATA program sizes a new account from the *mint's* extensions, and MemoTransfer is an
/// account-level extension, so the account has to be reallocated before it can be enabled.
fn enable_required_memos(f: &mut Fixture, owner: &Keypair) -> Pubkey {
    let ata = f.recipient_ata(&owner.pubkey());
    let payer = f.payer.insecure_clone();
    send_ok(
        &mut f.svm,
        &[create_associated_token_account(
            &payer.pubkey(),
            &owner.pubkey(),
            &f.mint,
            &f.token_program,
        )],
        &payer,
        &[],
    );
    send_ok(
        &mut f.svm,
        &[
            spl_token_2022::instruction::reallocate(
                &f.token_program,
                &ata,
                &payer.pubkey(),
                &owner.pubkey(),
                &[],
                &[spl_token_2022::extension::ExtensionType::MemoTransfer],
            )
            .unwrap(),
            spl_token_2022::extension::memo_transfer::instruction::enable_required_transfer_memos(
                &f.token_program,
                &ata,
                &owner.pubkey(),
                &[],
            )
            .unwrap(),
        ],
        &payer,
        &[owner],
    );
    ata
}

/// The repro: delivering into a memo-required ATA fails outright.
#[test]
fn deliver_token_token2022_memo_required_recipient_is_rejected() {
    let mut f = fixture(spl_token_2022::ID, None);
    let recipient = funded_keypair(&mut f.svm, 10);
    let ata = enable_required_memos(&mut f, &recipient);

    f.fund_vault(1_000_000);
    let res = f.deliver(&recipient.pubkey(), 0);

    let e = res.expect_err("expected the Token-2022 memo check to reject this transfer");
    assert!(
        e.meta
            .logs
            .iter()
            .any(|l| l.contains("No memo in previous instruction")),
        "expected Token-2022 NoMemo, got {:?}\nlogs: {:#?}",
        e.err,
        e.meta.logs
    );
    // Fail-closed: nothing moved.
    assert_eq!(token_balance(&f.svm, &f.vault_ata), 1_000_000);
    assert_eq!(token_balance(&f.svm, &ata), 0);
}

/// A memo at the TOP LEVEL of the transaction does not help, because it is not a sibling of the
/// `transfer_checked` CPI that `deliver_token` issues. This is what makes it unfixable by callers.
#[test]
fn deliver_token_token2022_top_level_memo_does_not_satisfy_the_check() {
    let mut f = fixture(spl_token_2022::ID, None);
    let recipient = funded_keypair(&mut f.svm, 10);
    enable_required_memos(&mut f, &recipient);
    f.fund_vault(1_000_000);

    let payer = f.payer.insecure_clone();
    let memo_ix = Instruction::new_with_bytes(MEMO_PROGRAM_ID, b"deliver", vec![]);
    let deliver_ix = f.deliver_token_ix(&payer.pubkey(), &recipient.pubkey(), 0);
    let res = send(&mut f.svm, &[memo_ix, deliver_ix], &payer, &[]);

    let e = res.expect_err("a top-level memo must not satisfy a nested CPI's memo check");
    assert!(
        e.meta
            .logs
            .iter()
            .any(|l| l.contains("No memo in previous instruction")),
        "expected NoMemo even with a top-level memo, got {:?}\nlogs: {:#?}",
        e.err,
        e.meta.logs
    );
}

/// With the optional memo program supplied, the same delivery succeeds: the handler emits a memo
/// as the sibling instruction immediately before `transfer_checked`, which is what the extension
/// requires.
#[test]
fn deliver_token_token2022_memo_required_succeeds_with_memo_program() {
    let mut f = fixture(spl_token_2022::ID, None);
    let recipient = funded_keypair(&mut f.svm, 10);
    let ata = enable_required_memos(&mut f, &recipient);

    let held = 1_000_000u64;
    f.fund_vault(held);

    let payer = f.payer.insecure_clone();
    let ix = f.deliver_token_ix_with_memo(&payer.pubkey(), &recipient.pubkey(), held);
    send_ok(&mut f.svm, &[ix], &payer, &[]);

    assert_eq!(token_balance(&f.svm, &ata), held, "full balance delivered");
    assert_eq!(token_balance(&f.svm, &f.vault_ata), 0, "vault swept");
}

/// The optional account changes nothing for everyone else: an ordinary SPL Token delivery works
/// identically whether or not the memo program is supplied.
#[test]
fn deliver_token_memo_program_is_optional_for_ordinary_mints() {
    for with_memo in [false, true] {
        let mut f = spl_fixture();
        let recipient = Pubkey::new_unique();
        f.fund_vault(500_000);

        let payer = f.payer.insecure_clone();
        let ix = if with_memo {
            f.deliver_token_ix_with_memo(&payer.pubkey(), &recipient, 500_000)
        } else {
            f.deliver_token_ix(&payer.pubkey(), &recipient, 500_000)
        };
        send_ok(&mut f.svm, &[ix], &payer, &[]);

        assert_eq!(
            token_balance(&f.svm, &f.recipient_ata(&recipient)),
            500_000,
            "with_memo={with_memo}"
        );
    }
}

/// Adding the optional account IS a breaking wire change, and this pins it so nobody assumes
/// otherwise. Anchor represents an absent optional account by the *program's own id* occupying the
/// slot — the slot itself is never omitted — so a client built against the pre-memo IDL, which
/// sends only nine accounts, is rejected with `AccountNotEnoughKeys`.
///
/// This is acceptable only because nothing is integrated against the program yet. It is the reason
/// the change belongs before integration rather than after.
#[test]
fn deliver_token_legacy_nine_account_caller_is_rejected() {
    let mut f = spl_fixture();
    let recipient = Pubkey::new_unique();
    f.fund_vault(750_000);

    let payer = f.payer.insecure_clone();
    let mut ix = f.deliver_token_ix(&payer.pubkey(), &recipient, 750_000);
    assert_eq!(ix.accounts.len(), 10, "the optional slot is always emitted");
    ix.accounts.truncate(9); // what a pre-memo client sends

    let e = send(&mut f.svm, &[ix], &payer, &[])
        .expect_err("a nine-account caller must not silently succeed");
    assert!(
        e.meta
            .logs
            .iter()
            .any(|l| l.contains("AccountNotEnoughKeys")),
        "expected AccountNotEnoughKeys, got {:?}\nlogs: {:#?}",
        e.err,
        e.meta.logs
    );
}

/// Naming the vault PDA itself as `recipient` is a no-op that succeeds: the System Program
/// transfer nets to zero. Nothing is lost and nothing is delivered.
///
/// The EVM twin does exactly the same on both of its paths — see `test_SelfDeliveryIsANoOpOnBothPaths`
/// — so this is pinned rather than constrained. Rejecting it here alone would be the divergence.
/// Raised as Octane df9b0426; see PARITY.md row 16a for why it is not a defect.
#[test]
fn deliver_sol_to_the_vault_itself_is_a_noop() {
    let mut svm = new_svm();
    let caller = funded_keypair(&mut svm, 10);
    let vault = vault_authority();
    svm.airdrop(&vault, 3 * LAMPORTS_PER_SOL).unwrap();
    let before = svm.get_balance(&vault).unwrap();

    send_ok(
        &mut svm,
        &[deliver_sol_ix(&caller.pubkey(), &vault, before)],
        &caller,
        &[],
    );

    assert_eq!(
        svm.get_balance(&vault).unwrap(),
        before,
        "the call succeeded and moved nothing"
    );

    // ...and the balance is still there for a real delivery, which is what actually drains it.
    let recipient = funded_keypair(&mut svm, 1);
    let recipient_before = svm.get_balance(&recipient.pubkey()).unwrap();
    send_ok(
        &mut svm,
        &[deliver_sol_ix(
            &caller.pubkey(),
            &recipient.pubkey(),
            before,
        )],
        &caller,
        &[],
    );
    assert_eq!(svm.get_balance(&vault).unwrap_or(0), 0, "drained for real");
    assert_eq!(
        svm.get_balance(&recipient.pubkey()).unwrap(),
        recipient_before + before
    );
}

// ---------------------------------------------------------------------------------------------
// Token-2022 DefaultAccountState::Frozen (Octane 01c1d77c)
// ---------------------------------------------------------------------------------------------

/// Stand up a Token-2022 mint whose `DefaultAccountState` is `Frozen`, so every token account
/// created for it starts frozen. Returns `(svm, payer, mint, mint_authority, freeze_authority)`.
fn default_frozen_fixture() -> (LiteSVM, Keypair, Pubkey, Keypair, Keypair) {
    use spl_token_2022::{extension::ExtensionType, state::AccountState};

    let mut svm = new_svm();
    let payer = funded_keypair(&mut svm, 100);
    let mint_authority = funded_keypair(&mut svm, 10);
    let freeze_authority = funded_keypair(&mut svm, 10);
    let mint_kp = Keypair::new();
    let mint = mint_kp.pubkey();

    let space = ExtensionType::try_calculate_account_len::<spl_token_2022::state::Mint>(&[
        ExtensionType::DefaultAccountState,
    ])
    .unwrap();
    let rent = svm.minimum_balance_for_rent_exemption(space);
    send_ok(
        &mut svm,
        &[
            system_instruction::create_account(
                &payer.pubkey(),
                &mint,
                rent,
                space as u64,
                &spl_token_2022::ID,
            ),
            spl_token_2022::extension::default_account_state::instruction::initialize_default_account_state(
                &spl_token_2022::ID,
                &mint,
                &AccountState::Frozen,
            )
            .unwrap(),
            spl_token_2022::instruction::initialize_mint2(
                &spl_token_2022::ID,
                &mint,
                &mint_authority.pubkey(),
                Some(&freeze_authority.pubkey()),
                DECIMALS,
            )
            .unwrap(),
        ],
        &payer,
        &[&mint_kp],
    );

    (svm, payer, mint, mint_authority, freeze_authority)
}

/// A `DefaultAccountState::Frozen` mint cannot be delivered without the freeze authority's
/// cooperation, and the obstruction starts well before `deliver_token`: even the *vault* ATA is
/// created frozen, so the vault cannot be funded until someone thaws it.
///
/// This is a property of the mint, not of this program. Such a mint is a permissioned asset —
/// whoever holds the freeze authority can re-freeze at any moment — and is therefore fundamentally
/// incompatible with permissionless push-delivery. Fail-closed: the transaction reverts, nothing
/// is lost. Documented, not worked around. See the module docs.
#[test]
fn deliver_token_token2022_default_frozen_recipient_ata_is_rejected() {
    let (mut svm, payer, mint, mint_authority, freeze_authority) = default_frozen_fixture();
    let tp = spl_token_2022::ID;
    let vault = vault_authority();
    let vault_ata = get_associated_token_address_with_program_id(&vault, &mint, &tp);

    send_ok(
        &mut svm,
        &[create_associated_token_account(
            &payer.pubkey(),
            &vault,
            &mint,
            &tp,
        )],
        &payer,
        &[],
    );

    // Even the vault ATA starts frozen, so funding is blocked first.
    let state =
        spl_token_2022::extension::StateWithExtensions::<spl_token_2022::state::Account>::unpack(
            &svm.get_account(&vault_ata).unwrap().data,
        )
        .unwrap()
        .base
        .state;
    assert_eq!(
        state,
        spl_token_2022::state::AccountState::Frozen,
        "the vault ATA itself is created frozen"
    );

    // Thaw and fund the vault so we reach deliver_token at all.
    send_ok(
        &mut svm,
        &[spl_token_2022::instruction::thaw_account(
            &tp,
            &vault_ata,
            &mint,
            &freeze_authority.pubkey(),
            &[],
        )
        .unwrap()],
        &payer,
        &[&freeze_authority],
    );
    send_ok(
        &mut svm,
        &[ix_mint_to(
            &tp,
            &mint,
            &vault_ata,
            &mint_authority.pubkey(),
            1_000_000,
        )],
        &mint_authority,
        &[],
    );

    // The recipient ATA does not exist; init_if_needed creates it frozen and the transfer fails.
    let recipient = Pubkey::new_unique();
    let r_ata = get_associated_token_address_with_program_id(&recipient, &mint, &tp);
    let ix = frozen_deliver_ix(
        &payer.pubkey(),
        vault,
        mint,
        vault_ata,
        recipient,
        r_ata,
        tp,
    );

    let e = send(&mut svm, &[ix], &payer, &[]).expect_err("expected AccountFrozen");
    assert!(
        format!("{:?}", e.err).contains("Custom(17)"),
        "expected Token-2022 AccountFrozen (17), got {:?}\nlogs: {:#?}",
        e.err,
        e.meta.logs
    );
    assert_eq!(token_balance(&svm, &vault_ata), 1_000_000, "nothing moved");
}

/// The reason no program change is warranted: a caller who holds the freeze authority can create
/// and thaw the recipient ATA with **ordinary top-level instructions in the same transaction**,
/// and delivery then succeeds unmodified.
///
/// Contrast with `MemoTransfer` (Octane 66f2d780), where the check inspects CPI *siblings* and a
/// top-level instruction genuinely could not satisfy it — which is why that one needed a program
/// change and this one does not. Thawing carries no such constraint.
#[test]
fn deliver_token_token2022_default_frozen_succeeds_with_a_top_level_thaw() {
    let (mut svm, payer, mint, mint_authority, freeze_authority) = default_frozen_fixture();
    let tp = spl_token_2022::ID;
    let vault = vault_authority();
    let vault_ata = get_associated_token_address_with_program_id(&vault, &mint, &tp);

    send_ok(
        &mut svm,
        &[create_associated_token_account(
            &payer.pubkey(),
            &vault,
            &mint,
            &tp,
        )],
        &payer,
        &[],
    );
    send_ok(
        &mut svm,
        &[spl_token_2022::instruction::thaw_account(
            &tp,
            &vault_ata,
            &mint,
            &freeze_authority.pubkey(),
            &[],
        )
        .unwrap()],
        &payer,
        &[&freeze_authority],
    );
    send_ok(
        &mut svm,
        &[ix_mint_to(
            &tp,
            &mint,
            &vault_ata,
            &mint_authority.pubkey(),
            1_000_000,
        )],
        &mint_authority,
        &[],
    );

    let recipient = Pubkey::new_unique();
    let r_ata = get_associated_token_address_with_program_id(&recipient, &mint, &tp);

    // create ATA, thaw it, deliver -- all top level, one transaction, no program change.
    send_ok(
        &mut svm,
        &[
            create_associated_token_account(&payer.pubkey(), &recipient, &mint, &tp),
            spl_token_2022::instruction::thaw_account(
                &tp,
                &r_ata,
                &mint,
                &freeze_authority.pubkey(),
                &[],
            )
            .unwrap(),
            frozen_deliver_ix(
                &payer.pubkey(),
                vault,
                mint,
                vault_ata,
                recipient,
                r_ata,
                tp,
            ),
        ],
        &payer,
        &[&freeze_authority],
    );

    assert_eq!(token_balance(&svm, &r_ata), 1_000_000, "delivered in full");
    assert_eq!(token_balance(&svm, &vault_ata), 0, "vault swept");
}

#[allow(clippy::too_many_arguments)]
fn frozen_deliver_ix(
    payer: &Pubkey,
    vault: Pubkey,
    mint: Pubkey,
    vault_ata: Pubkey,
    recipient: Pubkey,
    recipient_ata: Pubkey,
    token_program: Pubkey,
) -> Instruction {
    Instruction::new_with_bytes(
        deliver::ID,
        &deliver::instruction::DeliverToken { min: 0 }.data(),
        deliver::accounts::DeliverToken {
            payer: *payer,
            vault_authority: vault,
            mint,
            vault_token_account: vault_ata,
            recipient,
            recipient_token_account: recipient_ata,
            token_program,
            associated_token_program: ASSOCIATED_TOKEN_PROGRAM_ID,
            system_program: system_program::ID,
            // These mints are frozen, not memo-gated; the optional memo account stays absent.
            memo_program: None,
        }
        .to_account_metas(None),
    )
}
