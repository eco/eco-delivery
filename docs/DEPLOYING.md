# Deploying EcoDelivery

Conventions follow `eco-routes` (CREATE3 + versioned salt) and `eco-routes-svm` (`Eco…` vanity
program id, per-cluster tables). Nothing here has been deployed to any real network yet.

- [EVM](#evm) · [Solana](#solana) · [Before mainnet](#before-mainnet)

---

## EVM

`Deliver` takes no constructor arguments and holds no state, so the same bytecode is correct
everywhere. It is deployed with **CREATE3** through eco's shared deployer at
`0xC6BAd1EbAF366288dA6FB5689119eDd695a66814`, which derives the address from `(deployer, salt)`
alone — giving one address on every chain for integrators to hardcode.

```bash
cd evm

# check the address on a chain without deploying anything
PRIVATE_KEY=0x... SALT=0x... forge script script/Deploy.s.sol \
  --sig "predictAddress()" --rpc-url $RPC_URL

# deploy
PRIVATE_KEY=0x... SALT=0x... forge script script/Deploy.s.sol \
  --rpc-url $RPC_URL --broadcast --slow --verify
```

The script is **idempotent** — a second run against a chain that already has the contract prints
`Already deployed, nothing to do.` and exits, so it is safe to re-run across a chain list.

### The chain set

`evm/script/chaindata.json` is **copied from `eco-swap-gateway/evm/script/chaindata.json`**, so
EcoDelivery lands on exactly the chains eco-swap is deployed to. Keep the two in sync when either
moves — nothing enforces it automatically.

| | | | |
|---|---|---|---|
| `1` ethereum | `10` optimism | `56` bnb | `130` unichain |
| `137` polygon | `146` sonic | `999` hyperevm | `2020` ronin |
| `8453` base | `9745` plasma | `42161` arbitrum | `42220` celo |
| `57073` ink | | | |

All mainnet; no testnets. eco's shared CREATE3 deployer was verified present on **all thirteen**
(polygon needed a non-default RPC to confirm, the endpoint in chaindata was down at the time).

### Deploying the whole set

```bash
cd evm

# predict everywhere, broadcast nothing
DRY_RUN=true ALCHEMY_API_KEY=... SALT=0x... PRIVATE_KEY=0x... ./script/deployAll.sh

# deploy
ALCHEMY_API_KEY=... SALT=0x... PRIVATE_KEY=0x... ./script/deployAll.sh

# one chain, or retry the ones that failed
ONLY=10,8453 ... ./script/deployAll.sh
```

Every chain is idempotent, so the script is safe to re-run and safe to run again after adding a
chain. It writes a CSV of results and **fails loudly if the chains do not all agree on the same
address** — that agreement is the entire point of the CREATE3 setup, and a partial fleet where it
silently does not hold is worse than a failed deploy.

A note on deployer choice: `eco-swap-gateway` deploys through **CreateX** with an unguarded salt, so
*any* deployer can reproduce its address on a new chain. This repo follows `eco-routes` instead and
uses eco's CREATE3 deployer, where the address is derived from `(deployer, salt)` — reproducible
only by that deployer. Both contracts are present on all thirteen chains, so either would work; the
difference is who can extend the deployment later. Worth a deliberate decision rather than
inheriting mine.

### The salt rule

`DELIVER_VERSION` in `script/Deploy.s.sol` is a salt discriminator, currently `ECO_DELIVERY_V1`.

> **Bump it on any change to the contract's interface.**

CREATE3 ignores bytecode when deriving the address. Without a bump, a modified contract would land
on the *same* address on any chain not yet deployed to — so "same address everywhere" would quietly
come to mean "same address, different code". That is also why the script reads `NATIVE_SENTINEL()`
back after deploying: a matching address proves only that the same deployer used the same salt, not
that it deployed the same contract.

### Broadcast logs are not committed

Foundry's template un-ignores `broadcast/` so real deployment records get tracked. That is turned
off here, deliberately: a fork test writes its records under the **forked** chain's id, so an anvil
fork of Optimism produces `broadcast/Deploy.s.sol/10/` that reads exactly like a real mainnet
deploy. Until something is genuinely deployed, ignoring the directory beats committing a record of
a deployment that never happened. Revisit once there are real ones worth keeping.

### Verified against a fork

The read path and the deploy path were both exercised against a local anvil fork of Optimism
(chain 10): first run deploys at the predicted address, second run detects it and no-ops. No real
network was touched.

## Solana

The program id is **`EcoyzRRwsSsFz6i4YU6r28WGD9mamCtRi4Zc8w78FNjw`**, a ground vanity key matching
the `Eco…` convention used by the programs in `eco-routes-svm`. It replaces the throwaway id that
`anchor init` generated.

```bash
cd solana
anchor build
anchor run deploy-devnet     # anchor deploy --provider.cluster devnet  --program-name deliver
anchor run deploy-mainnet    # anchor deploy --provider.cluster mainnet --program-name deliver
```

`Anchor.toml` carries the id in `[programs.localnet]`, `[programs.devnet]` and
`[programs.mainnet]` — the same id on every cluster, as in `eco-routes-svm`.

### The program keypair is not in this repo

`solana/keys/EcoyzRRwsSsFz6i4YU6r28WGD9mamCtRi4Zc8w78FNjw.json` is **gitignored** (as program
keypairs are in `eco-routes-svm`), and a copy sits at `solana/target/deploy/deliver-keypair.json`
where `anchor deploy` expects it — also gitignored.

> **Back it up somewhere durable before deploying.** Losing it means losing the program id
> permanently: the address cannot be recovered, every integrator's hardcoded id becomes dead, and
> the program can never be upgraded again.

Unlike `eco-routes-svm`, this repo has **no `mainnet` feature flag**, because the program has no
network-specific configuration — no mailbox address, no bridge endpoints, nothing to switch. The
same build is correct on every cluster.

## Before mainnet

Undecided, and each is a one-way door:

- [ ] **The `SALT` value for EVM.** It fixes the address on every chain, forever. Pick it once.
- [ ] **Which chains**, and in what order.
- [ ] **Solana upgrade authority.** `anchor deploy` leaves the deploying wallet as upgrade
      authority. Decide whether to transfer it to a multisig, or make the program immutable with
      `solana program set-upgrade-authority --final` — which cannot be undone. A stateless
      pass-through is a reasonable candidate for immutability, but that is a decision, not a
      default.
- [ ] **An audit.** The repo says "not audited" in every doc; that stays true until it isn't.
- [ ] **Addresses into the SDK.** `@eco-foundation/delivery` ships no addresses today. Add them
      once deployed, and drop `"private": true` from `ts/package.json` to publish.
