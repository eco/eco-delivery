# EVM ↔ SVM parity

Two encodings of one primitive: **deliver the entire balance already held, revert unless it meets a
caller-supplied floor.** This document records exactly where the two implementations line up, where
they cannot, and which EVM test cases have a Solana counterpart.

Nothing here is aspirational. Every "yes" below is backed by a test that runs in the committed
suites (EVM: 50 tests, `forge test`; SVM: 23 tests, `cargo test`). Every gap is stated as a gap.

- EVM: `evm/src/Deliver.sol`
- SVM: `solana/programs/deliver/src/`

---

## 1. Interface and behaviour map

| # | EVM | SVM | Behaviourally identical? |
|---|-----|-----|--------------------------|
| 1 | `deliverToken(IERC20 token, address recipient, uint256 min)` | `deliver_token(ctx: Context<DeliverToken>, min: u64)` | **Yes**, in the core semantics: read held balance, require `>= min`, transfer the whole balance. Argument order and meaning are aligned. Differences are in the token model (rows 8–12), not the logic. |
| 2 | `deliverNative(address recipient, uint256 min)` | `deliver_sol(ctx: Context<DeliverSol>, min: u64)` | **Yes** in semantics; the transport differs (`call{value:}` vs a System Program CPI). See §2.3. |
| 3 | `deliverToken(address(0) \| NATIVE_SENTINEL, …)` dispatches to the native path | — | **No counterpart.** See §2.4. |
| 4 | `receive() external payable {}` | — (none needed) | **No counterpart needed.** Any Solana account accepts lamports with no code; an ATA accepts transfers with no code. Funding the SVM vault is a plain `system_program::transfer` / airdrop. |
| 5 | `address public constant NATIVE_SENTINEL` | — | **No counterpart.** Nothing to overload. |
| 6 | `error BalanceBelowMin(uint256 balance, uint256 min)` | `DeliverError::BalanceBelowMin`, Anchor code `6000`, msg `"deliver: balance below min"` | **Partial.** The human-readable string is deliberately identical. The EVM error carries `(balance, min)` in its payload; the Anchor error carries only the code and the message. A caller cannot read the observed balance off an SVM failure. |
| 7 | `error NativeTransferFailed(address recipient, uint256 amount)` | — | **No counterpart.** A failing System Program transfer aborts the whole transaction with the runtime's own error; there is no partial state to fail closed against. |
| 8 | Balance source: `token.balanceOf(address(this))` — the verifier contract *is* the holder | Balance source: `vault_token_account.amount` — a PDA-owned ATA; the program itself holds nothing | **No.** Structural. See §2.1. |
| 9 | Native balance source: `address(this).balance` | `vault_authority.lamports()`, the PDA at seeds `[b"vault"]` | **No.** Structural, same reason. |
| 10 | Transfer: `SafeERC20.safeTransfer` | Transfer: `transfer_checked` CPI signed with `[b"vault", bump]` | **Yes** in effect. `transfer_checked` additionally validates mint + decimals, which has no ERC-20 equivalent. |
| 11 | Vault topology: one contract address holds every asset | One vault-authority PDA, one ATA per mint, plus bare lamports | **No.** Structural. |
| 12 | Amount width: `uint256` | `u64` | **No.** An SVM `min` above `u64::MAX` is unrepresentable. Not a practical limit (SPL supplies are `u64`), but it is a real signature difference. |
| 13 | Stateless: no storage, no owner, no allowlist, no pause | Stateless: no program state; the vault PDA is never allocated data | **Yes.** |
| 14 | Permissionless: any caller, caller picks the recipient | Permissionless: any signer, caller picks the recipient | **Yes**, with one cost asymmetry — the SVM caller may pay ATA rent. See §2.1. |
| 15 | No events; the ERC-20 `Transfer` log is the outcome record | No events; the SPL `TransferChecked` instruction and balance change are the outcome record | **Yes**, same decision on both sides. |
| 16 | Recipient never validated, including `address(0)` | Recipient never validated, including `Pubkey::default()` | **Yes** as a policy. On SVM the hazard is *documented only*, not tested — see §3, EVM case 36. |
| 17 | `min` checked **pre-transfer** against the held balance | `min` checked **pre-transfer** against the held balance | **Yes** — including the shared under-delivery hole. See §2.2. |
| 18 | Zero balance + `min == 0` succeeds as a no-op (a transfer of 0) | Zero balance + `min == 0` succeeds as a no-op (a `transfer_checked` of 0 is still issued) | **Yes**, deliberately matched on both sides, on both the token and the native path. |
| 19 | Pre-existing dust is swept along with the delivery | Pre-existing dust is swept along with the delivery | **Yes.** |
| 20 | After a sweep the contract persists at zero balance | After `deliver_sol` the PDA is drained to zero lamports and **reaped by the runtime** | **No.** It springs back when next funded, so the observable primitive is the same, but "the vault still exists at zero" is not true on SVM. |

---

## 2. Where the two CANNOT be identical

These are not gaps to close. They are consequences of the two chain models, listed so nobody reads
"behaviorally identical" as stronger than it is.

### 2.1 Recipient token-account creation and rent payment

On EVM the recipient is an address. It always exists, an ERC-20 balance is a mapping entry, and a
transfer to a never-before-seen address costs the caller nothing beyond gas.

On SVM the recipient needs an **associated token account** for the mint, and it may not exist.
`deliver_token` creates it with `init_if_needed`, **with the permissionless caller as the rent
payer**. Consequences with no EVM analogue:

- Calling `deliver_token` can cost the caller ~0.002 SOL of rent that **nobody refunds**.
- Any caller can force ATA creation for an arbitrary recipient at their own expense.
- The instruction needs three accounts EVM never mentions: `associated_token_program`,
  `system_program`, and the recipient's ATA itself.

Pinned by `deliver_token_creates_the_recipient_ata_when_it_does_not_exist`, which asserts the
caller's lamport balance actually drops by at least one token-account rent exemption.

The mirror-image asymmetry: the **vault's** ATA is *not* created by the program. It must already
exist, because the program never pulls funds in. So an unfunded vault behaves differently on the two
sides — see §2.5.

The vault token account is also **not closed** after a sweep; its rent stays locked so the ATA is
reusable. EVM has nothing to close.

### 2.2 Token-2022 transfer fees vs fee-on-transfer ERC-20s

**The hole is the same on both sides, and it is the same root cause:** `min` is checked against the
balance *held before the transfer*, never against the recipient's balance delta. A token that takes
a cut in transit passes the check and credits the recipient strictly less than `min`. The call
succeeds. Neither implementation detects it.

| | EVM | SVM |
|---|-----|-----|
| Mechanism | Arbitrary token code; any ERC-20 may do anything on `transfer` | Token-2022 `TransferFee` extension, enforced by the token program |
| Tested by | `test_Hole_FeeOnTransferTokenCanDeliverLessThanMin` (1% fee mock, `min == balance`, recipient gets `0.99 * min`) | `deliver_token_token2022_transfer_fee_recipient_gets_less_than_min` (5% fee mint, `min == 1_000_000`, recipient gets `950_000`) |
| Breadth | **Wider.** Any under-delivering ERC-20 works and is swept: fee-on-transfer, rebasing, hook tokens | **Narrower.** `TransferFee` mints work. **Token-2022 `TransferHook` mints are NOT supported at all** |

That last row is the one real coverage asymmetry, and it runs in SVM's disfavour. The
`transfer_checked` CPI forwards exactly the four accounts the instruction needs and drops
`remaining_accounts`, so a hook mint whose hook program requires extra accounts **fails outright**
rather than misbehaving. There is no test for it. Supporting hook mints would mean resolving and
forwarding the hook's account list. Do not read the EVM side's broad non-standard-token coverage as
implying the SVM side has it.

Rebasing is documented on both sides and separately mocked on neither; the fee mocks stand in for
the whole under-delivery class.

### 2.3 Native ETH vs lamport sweep

Same primitive, materially different failure surface.

| | EVM `deliverNative` | SVM `deliver_sol` |
|---|-----|-----|
| Send | `recipient.call{value: balance}("")`, forwarding all remaining gas | `system_program::transfer` CPI signed with the PDA seeds |
| Recipient runs code? | **Yes.** A contract recipient executes arbitrary logic, and can re-enter | **No.** A lamport credit executes nothing |
| Can the recipient refuse? | **Yes** — reverts on receive; the contract fails closed with `NativeTransferFailed` | **No.** A lamport credit cannot be refused. There is no analogue of a rejecting recipient, so `NativeTransferFailed` has no counterpart |
| Requires the sender to hold no data? | N/A | **Yes.** The System Program refuses to move lamports out of an account carrying data. The vault PDA is never allocated data — load-bearing, and asserted against the runtime in `deliver_sol_fails_when_vault_pda_carries_data` |
| Rent rule on a new recipient | None | **A brand-new recipient must be left rent-exempt by the swept amount or the transaction is rejected.** Documented; **no dedicated test** — the `deliver_sol` tests pre-fund their recipients |
| Vault after a full sweep | Persists at zero balance | Drained to zero and reaped by the runtime |
| Funding path | `receive() external payable` | No code; any lamport transfer to the PDA |

### 2.4 The two address sentinels have no SVM analogue

On EVM, `deliverToken` treats both `address(0)` and `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE` as
"native ETH" and routes them into the native path. Ten EVM tests cover that dispatch and its hazard.

**None of it can exist on SVM.** There is no token-*address* argument to overload: `deliver_token`
takes a `mint` *account*, and native value is reachable only through its own separate instruction.
`deliver_token` can never be tricked into a lamport sweep. This is stated as a comment in the SVM
test file's `deliver_sol` section.

The upshot is that **the `address(0)` hazard is an EVM-only hazard.** The SVM side is strictly safer
here. The *parallel* hazard — an unvalidated, caller-supplied recipient, `Pubkey::default()`
included — does exist on SVM and is documented loudly in the module docs, but it is not tested.

### 2.5 An unfunded vault: EVM no-ops, SVM errors

A genuine behavioural divergence, not just a test gap.

- **EVM:** `deliverToken(token, recipient, 0)` against a contract holding nothing **succeeds** as a
  no-op transfer of 0 (`test_ZeroBalanceWithZeroMinSucceedsAsNoOp`).
- **SVM:** `deliver_token` with `min == 0` against a vault whose ATA **does not exist** **fails** at
  account resolution with Anchor `3012 AccountNotInitialized`
  (`deliver_token_fails_when_the_vault_ata_does_not_exist`).

The two agree once the vault ATA exists but is empty — that case is a successful no-op on both sides
(`deliver_token_zero_balance_with_min_zero_succeeds_as_a_noop`). The divergence is confined to the
"vault ATA was never created" state, which has no EVM representation at all.

### 2.6 Reentrancy is an EVM-only concern

The EVM suite spends six tests proving re-entry is harmless: token hooks firing after *and* before
the balance update, a re-entrant native recipient, and re-entry through the sentinel path.

**The whole class is structurally absent on SVM.** SPL Token has no ERC-777-style recipient hook;
the only callback mechanism is the Token-2022 `TransferHook` extension, which this program does not
support; the System Program runs no recipient code; and the Solana runtime forbids re-entrant CPI
other than direct self-recursion. There is no SVM test for any of it, and none can be written
against this implementation. It is reasoned about in the SVM module docs.

### 2.7 Non-standard-token classes that only exist on EVM

`SafeERC20` exists because ERC-20 has no enforced ABI: USDT-style tokens return nothing, some tokens
return `false` instead of reverting. Three EVM tests cover the no-return case and one covers the
false-return case.

SPL Token and Token-2022 are **fixed programs with one uniform interface**. A transfer either
succeeds or aborts the transaction with a program error; it cannot return a value that gets silently
ignored. The nearest SVM axis is *which token program owns the mint*, and both are covered
(`deliver_token_works_with_a_token_2022_mint`).

---

## 3. EVM test cases → SVM counterparts

All 50 EVM tests. Legend:

- **✅ direct** — a counterpart test exists and asserts the same property.
- **🟰 subsumed** — the property is asserted inside a counterpart test, but not as its own test.
- **🚫 cannot exist** — the property is not expressible on SVM. Reason given.
- **⚠️ gap** — the property *could* be tested on SVM and is not. These are real holes.

### `test/Deliver.t.sol` — core ERC-20 path (13)

| EVM test | SVM counterpart | |
|---|---|---|
| `test_DeliversFullBalanceNotPartialAmount` | `deliver_token_sweeps_the_full_balance_not_a_partial_amount` | ✅ |
| `test_PreExistingDustIsIncludedInSweep` | `deliver_token_sweeps_pre_existing_dust_along_with_the_delivery` | ✅ |
| `test_HoldsNoFundsBetweenCalls` | none | ⚠️ gap. Writable on SVM (sweep, then call again with `min == 0` against the now-empty vault ATA). Not written. |
| `test_RevertWhen_BalanceBelowMin` | `deliver_token_reverts_when_balance_is_below_min` | ✅ |
| `test_RevertWhen_BalanceIsOneBelowMin` | `deliver_token_reverts_at_the_boundary_balance_equals_min_minus_one` | ✅ |
| `test_SucceedsWhenBalanceExactlyEqualsMin` | `deliver_token_succeeds_when_balance_equals_min_exactly` | ✅ |
| `test_ZeroBalanceWithZeroMinSucceedsAsNoOp` | `deliver_token_zero_balance_with_min_zero_succeeds_as_a_noop` | ✅ Both assert the zero-amount transfer is actually issued, not merely that the call succeeded. |
| `test_RevertWhen_ZeroBalanceAndPositiveMin` | `deliver_token_zero_balance_with_nonzero_min_reverts` | ✅ |
| `test_UnrelatedCallerCanDeliver` | `deliver_token_is_permissionless_an_unrelated_caller_can_invoke_it` | ✅ |
| `test_AnyoneCanDivertAStrandedBalance` | none | ⚠️ gap. The permissionless test proves an unrelated *caller*; nothing on SVM proves a stranded balance is claimable *for an attacker-chosen recipient*. The property holds by construction, but is unasserted. |
| `test_ContractWritesNoStorage` | none directly | ⚠️ gap. `deliver_sol_fails_when_vault_pda_carries_data` is adjacent but asserts a different thing (the runtime refuses to drain a data-carrying account), not that the program leaves the PDA data-free. |
| `testFuzz_BoundaryBalanceVersusMin` | `fuzz_deliver_token_boundary_balance_versus_min` | ✅ proptest, 256 cases. Draws are weighted toward the boundary (±2 of `balance`) because two uniform 64-bit draws would essentially never produce `balance == min`. |
| `testFuzz_AnyCallerSweepsFullBalance` | `fuzz_any_caller_sweeps_full_balance_to_any_recipient` | ✅ proptest, 256 cases, fuzzing both the balance and the full 32-byte recipient key space. |

### `test/DeliverNative.t.sol` — native ETH path (14)

| EVM test | SVM counterpart | |
|---|---|---|
| `test_DeliversFullNativeBalanceNotPartialAmount` | `deliver_sol_sweeps_the_full_lamport_balance` | ✅ |
| `test_PreExistingNativeDustIsIncludedInSweep` | `deliver_sol_sweeps_pre_existing_dust` | ✅ |
| `test_HoldsNoNativeFundsBetweenCalls` | none | ⚠️ gap, with a semantic caveat: on SVM the drained PDA is *reaped*, so the second call runs against a non-existent account rather than a persisting zero-balance contract. The assertion would have to be worded differently. |
| `test_ReceiveAcceptsPlainEthSend` | none needed | 🚫 There is no code path to test. Solana accounts accept lamports unconditionally; every `deliver_sol` test funds the PDA by plain airdrop, which *is* the counterpart. |
| `test_RevertWhen_NativeBalanceBelowMin` | `deliver_sol_reverts_at_the_boundary_balance_equals_min_minus_one` | 🟰 subsumed. SVM has only the tighter `min - 1` case; the loose "well below min" case is not separately written. |
| `test_RevertWhen_NativeBalanceIsOneBelowMin` | `deliver_sol_reverts_at_the_boundary_balance_equals_min_minus_one` | ✅ |
| `test_SucceedsWhenNativeBalanceExactlyEqualsMin` | `deliver_sol_succeeds_when_balance_equals_min_exactly` | ✅ |
| `test_ZeroNativeBalanceWithZeroMinSucceedsAsNoOp` | `deliver_sol_zero_balance_with_min_zero_succeeds_as_a_noop` | ✅ |
| `test_RevertWhen_ZeroNativeBalanceAndPositiveMin` | `deliver_sol_zero_balance_with_nonzero_min_reverts` | ✅ |
| `test_RevertWhen_NativeRecipientRejectsEth` | none | 🚫 A lamport credit cannot be refused — no recipient code runs. See §2.3. |
| `test_RevertWhen_NativeRecipientRejectsZeroValueNoOp` | none | 🚫 Same reason. |
| `test_DeliversToContractRecipientThatAcceptsEth` | none | 🚫 SVM draws no EOA/contract distinction for a lamport credit; a program-owned account receives exactly like any other, and `deliver_sol`'s tests already deliver to plain accounts. |
| `test_UnrelatedCallerCanDeliverNative` | `deliver_sol_is_permissionless_an_unrelated_caller_can_invoke_it` | ✅ |
| `testFuzz_NativeBoundaryBalanceVersusMin` | `fuzz_deliver_sol_boundary_balance_versus_min` | ✅ proptest, 256 cases. The recipient is pre-funded so the runtime's rent-exemption-on-create rule does not confound the `min` property. |

### `test/DeliverSentinels.t.sol` — the two native sentinels (10)

**Every case here is 🚫.** There is no token-address argument to overload on SVM, so
`deliver_token` cannot be routed into a lamport sweep and no sentinel exists to test. See §2.4.

| EVM test | Why no counterpart can exist |
|---|---|
| `test_NativeSentinelConstant` | No sentinel constant exists. |
| `test_ZeroAddressSentinelRoutesToNativePath` | No address-to-native dispatch. |
| `test_EeeeSentinelRoutesToNativePath` | No address-to-native dispatch. |
| `test_RevertWhen_ZeroAddressSentinelBalanceBelowMin` | No dispatch to check a floor against. |
| `test_RevertWhen_EeeeSentinelBalanceBelowMin` | Same. |
| `test_SentinelPathLeavesErc20BalancesUntouched` | The instructions are already disjoint by construction; `deliver_sol` never touches a token account. |
| `test_UnrelatedCallerCanUseSentinelPath` | `deliver_sol_is_permissionless_…` covers permissionless native delivery through the only path there is. |
| `test_SentinelZeroBalanceWithZeroMinSucceedsAsNoOp` | `deliver_sol_zero_balance_with_min_zero_succeeds_as_a_noop` covers the no-op through the only path there is. |
| `test_Hazard_UninitializedTokenSweepsEthInsteadOfReverting` | **The hazard itself does not exist on SVM** — an unset mint field cannot become a native sweep. The parallel hazard (an unvalidated recipient, `Pubkey::default()` included) does exist there, is documented in the module docs, and is **not tested**. ⚠️ |
| `testFuzz_SentinelBoundaryBalanceVersusMin` | No sentinel to fuzz. There is no token-address argument on this side to overload, so the dispatch this fuzzes cannot exist. |

### `test/DeliverNonStandardTokens.t.sol` — non-standard ERC-20s (7)

| EVM test | SVM counterpart | |
|---|---|---|
| `test_NoReturnTokenIsDeliveredInFull` | none | 🚫 SPL Token has no return-value convention to violate. §2.7. The nearest axis — which token program owns the mint — is covered by `deliver_token_works_with_a_token_2022_mint`. |
| `test_NoReturnTokenHonoursTheMinFloor` | none | 🚫 Same reason. |
| `test_NoReturnTokenSucceedsAtExactlyMin` | none | 🚫 Same reason. |
| `test_RevertWhen_TokenTransferReturnsFalse` | none | 🚫 An SPL transfer cannot report failure by return value; it aborts the transaction. |
| `test_Hole_FeeOnTransferTokenCanDeliverLessThanMin` | `deliver_token_token2022_transfer_fee_recipient_gets_less_than_min` | ✅ **The important one.** Both pin the same documented hole: the call succeeds while the recipient receives strictly less than `min`. |
| `test_FeeOnTransferTokenIsStillFullySwept` | inside the test above | 🟰 subsumed. The SVM fee test also asserts the vault ATA ends at zero, but there is no standalone "fee mint is still fully swept" test. |
| `test_FeeOnTransferTokenStillRevertsBelowMin` | none | ⚠️ gap. Writable on SVM (a fee mint funded below `min`); the pre-transfer check makes it behave identically. Not written. |

### `test/DeliverReentrancy.t.sol` — re-entry (6)

**Every case here is 🚫.** See §2.6.

| EVM test | Why no counterpart can exist |
|---|---|
| `test_TokenHookReentrancyFindsZeroBalance` | SPL Token has no recipient hook; Token-2022 `TransferHook` mints are unsupported by this program; the runtime forbids non-self re-entrant CPI. |
| `test_TokenHookReentrancyWithPositiveMinReverts` | Same. |
| `test_PreUpdateHookTokenCannotDoubleDeliver` | The token program is fixed code; there is no hook-ordering choice to exploit. |
| `test_NativeReentrancyFindsZeroBalance` | A System Program transfer runs no recipient code. |
| `test_NativeReentrancyWithPositiveMinReverts` | Same. |
| `test_NativeReentrancyViaSentinelFindsZeroBalance` | No sentinel *and* no re-entrancy. |

### Tally

| | Count |
|---|---|
| ✅ direct counterpart | 16 |
| 🟰 subsumed | 3 |
| 🚫 cannot exist on SVM | 23 |
| ⚠️ real gap (writable, not written) | 8 |
| **EVM tests total** | **50** |

---

## 4. SVM test cases with no EVM counterpart

| SVM test | Why EVM has none |
|---|---|
| `deliver_token_creates_the_recipient_ata_when_it_does_not_exist` | An EVM address always exists; an ERC-20 balance is a mapping entry. No account creation, no rent, no payer. §2.1 |
| `deliver_token_fails_when_the_vault_ata_does_not_exist` | An EVM balance of zero is simply zero. The "the holding account was never created" state has no EVM representation — and this is where the two genuinely diverge. §2.5 |
| `deliver_sol_fails_when_vault_pda_carries_data` | EVM has no coupling between an account's data and its ability to send value. §2.3 |

---

## 5. Consolidated gap list

Known and accepted, in rough order of how much they matter:

1. **Token-2022 `TransferHook` mints are unsupported and untested on SVM.** The EVM side handles
   arbitrary hook tokens through the generic ERC-20 interface; the SVM side fails outright. This is
   the only coverage asymmetry that could surprise an integrator reading "behaviorally identical".
2. **Fuzz depth differs by an order of magnitude.** Both suites now fuzz the same three
   properties, but Foundry runs 4096 cases in-process while the SVM properties run 256 proptest
   cases each — every SVM case boots a LiteSVM, loads the BPF ELF and lands several real
   transactions (~9.6s for 768 cases). The properties are at parity; the sample depth is not.
3. **No re-entrancy testing on SVM** — structurally impossible against this implementation, but it
   means the EVM suite's six-test proof has nothing backing it on the other side.
4. **The unvalidated-recipient hazard is untested on SVM.** EVM pins its `address(0)` variant with
   `test_Hazard_UninitializedTokenSweepsEthInsteadOfReverting`; SVM documents the parallel
   `Pubkey::default()` hazard in prose only.
5. **`deliver_sol` to a non-existent recipient** must leave it rent-exempt or the runtime rejects
   the transaction. Documented, untested; the `deliver_sol` tests pre-fund their recipients.
6. Five smaller writable-but-unwritten SVM cases: holds-no-funds-between-calls (token and native),
   stranded-balance-divertible, fee-mint-below-min, and program-writes-no-state.
7. **Rebasing tokens are documented on both sides and mocked on neither.** The fee mocks stand in
   for the whole under-delivery class.
8. Neither side has an integration/fork test against a real deployment. All non-standard behaviour
   is exercised through local mocks (EVM) and litesvm's bundled program versions (SVM:
   `spl_token` 3.5.0, `spl_token_2022` 10.0.0, `spl_associated_token_account` 1.1.1).
9. Both sides now have a deploy script (`evm/script/Deploy.s.sol`, `anchor run deploy-*`; see
   `docs/DEPLOYING.md`), and CI runs both suites plus the SDK on every push
   (`.github/workflows/ci.yml`). Nothing has been deployed to a real network.
