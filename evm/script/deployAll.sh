#!/usr/bin/env bash
#
# deployAll.sh — deploy Deliver to every chain in chaindata.json.
#
# The chain set is eco-chains (eco/eco-chains src/assets/chain.json), the same list eco-routes
# deploys against. Refresh it from there rather than editing by hand.
#
# Deployment is CREATE2 through CreateX with an unguarded salt, so the address depends only on
# (salt, initCode) — not on who deploys. Every chain gets the SAME address and ANYONE can extend
# the fleet to a new chain later without a key from eco. Each chain is idempotent: one that already
# has the contract is detected and skipped, so the script is safe to re-run.
#
# Chains where CreateX itself is not deployed are reported as `no-createx` and skipped rather than
# failing the run — they cannot get the shared address until someone deploys CreateX there.
#
# Required environment:
#   SALT              bytes32, canonical unguarded form (first 20 bytes zero, byte 20 zero).
#                     THIS FIXES THE ADDRESS ON EVERY CHAIN, PERMANENTLY.
#   PRIVATE_KEY       deployer key, funded on every target chain. NOT needed for DRY_RUN —
#                     prediction is deployer-independent, which is the point of the design.
#   ALCHEMY_API_KEY   substituted into the chaindata.json RPC URLs
#
# Optional:
#   CHAIN_DATA        path to the chain config (default: alongside this script)
#   RESULTS_FILE      CSV of results (default: ./deploy-results.csv)
#   ONLY              comma-separated chain ids to restrict to, e.g. ONLY=10,8453
#   DRY_RUN           "true" to only predict addresses, broadcasting nothing
#
# Usage:
#   DRY_RUN=true ./script/deployAll.sh          # predict everywhere, touch nothing
#   ./script/deployAll.sh                       # deploy
#   ONLY=10 ./script/deployAll.sh               # one chain

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

CHAIN_DATA="${CHAIN_DATA:-$SCRIPT_DIR/chaindata.json}"
RESULTS_FILE="${RESULTS_FILE:-$PWD/deploy-results.csv}"
DRY_RUN="${DRY_RUN:-false}"
ONLY="${ONLY:-}"

fail() { echo "error: $*" >&2; exit 1; }

[ -f "$CHAIN_DATA" ] || fail "chain data not found: $CHAIN_DATA"
[ -n "${SALT:-}" ] || fail "SALT is not set. It fixes the deployed address on every chain permanently — choose it deliberately, do not let it default."
if [ "${DRY_RUN:-false}" != "true" ]; then
    [ -n "${PRIVATE_KEY:-}" ] || fail "PRIVATE_KEY is not set"
fi
# NOTE: predicting needs no key at all — the CreateX address does not depend on the deployer.
if grep -q 'ALCHEMY_API_KEY' "$CHAIN_DATA" && [ -z "${ALCHEMY_API_KEY:-}" ]; then
    fail "chaindata.json uses \${ALCHEMY_API_KEY} but it is not set"
fi

CHAIN_IDS=$(python3 -c "
import json,sys
d=json.load(open('$CHAIN_DATA'))
only='$ONLY'
ids=sorted(d, key=int)
if only:
    want=[x.strip() for x in only.split(',') if x.strip()]
    missing=[w for w in want if w not in d]
    if missing:
        sys.exit('ONLY names chains absent from chaindata.json: ' + ','.join(missing))
    ids=[i for i in ids if i in want]
print(' '.join(ids))
")

echo "chains:   $(echo "$CHAIN_IDS" | wc -w | tr -d ' ')"
echo "mode:     $([ "$DRY_RUN" = "true" ] && echo 'DRY RUN — predicting only' || echo 'BROADCAST')"
echo "results:  $RESULTS_FILE"
echo

echo "chain_id,status,address" > "$RESULTS_FILE"

failed=()
for id in $CHAIN_IDS; do
    url=$(python3 -c "
import json,os
d=json.load(open('$CHAIN_DATA'))
print(os.path.expandvars(d['$id']['url']))
")
    printf '%-8s ' "$id"

    if [ "$DRY_RUN" = "true" ]; then
        out=$(forge script script/Deploy.s.sol --sig "predictAddress()" --rpc-url "$url" 2>&1) || {
            echo "RPC/script failure"; echo "$id,error," >> "$RESULTS_FILE"; failed+=("$id"); continue
        }
        addr=$(echo "$out" | grep -oE 'Predicted addr : 0x[0-9a-fA-F]{40}' | awk '{print $NF}')
        live=$(echo "$out" | grep -oE 'Deployed *: (true|false)' | awk '{print $NF}')
        echo "predicted $addr (already deployed: ${live:-?})"
        echo "$id,predicted,$addr" >> "$RESULTS_FILE"
        continue
    fi

    out=$(forge script script/Deploy.s.sol --rpc-url "$url" --broadcast --slow --private-key "$PRIVATE_KEY" 2>&1) || {
        if echo "$out" | grep -q 'CreateX is not deployed on this chain'; then
            echo "skipped — CreateX absent on this chain"
            echo "$id,no-createx," >> "$RESULTS_FILE"; continue
        fi
        echo "FAILED"; echo "$out" | tail -5 | sed 's/^/         /'
        echo "$id,failed," >> "$RESULTS_FILE"; failed+=("$id"); continue
    }
    addr=$(echo "$out" | grep -oE '(Deployed at|Predicted addr) *: 0x[0-9a-fA-F]{40}' | tail -1 | awk '{print $NF}')
    if echo "$out" | grep -q 'Already deployed'; then
        echo "already deployed at $addr"
        echo "$id,already,$addr" >> "$RESULTS_FILE"
    else
        echo "deployed at $addr"
        echo "$id,deployed,$addr" >> "$RESULTS_FILE"
    fi
done

echo
# Every chain must agree on the address, or the "one address everywhere" property this whole
# CREATE3 setup exists to provide has quietly failed on part of the fleet.
distinct=$(awk -F, 'NR>1 && $3 != "" {print $3}' "$RESULTS_FILE" | sort -u | wc -l | tr -d ' ')
if [ "$distinct" -gt 1 ]; then
    echo "WARNING: chains do not agree on the address — $distinct distinct values:"
    awk -F, 'NR>1 && $3 != "" {print "  " $1 " " $3}' "$RESULTS_FILE"
elif [ "$distinct" -eq 1 ]; then
    echo "address (identical on every chain): $(awk -F, 'NR>1 && $3 != "" {print $3; exit}' "$RESULTS_FILE")"
fi

if [ ${#failed[@]} -gt 0 ]; then
    echo "failed chains: ${failed[*]}"
    echo "re-run with ONLY=$(IFS=,; echo "${failed[*]}") once fixed — completed chains are skipped."
    exit 1
fi
echo "all chains OK"
