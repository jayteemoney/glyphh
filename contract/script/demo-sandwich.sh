#!/usr/bin/env bash
# Stage a sandwich against the live pool and show the victim being credited.
#
#   ./script/demo-sandwich.sh
#
# One transaction. The bundler is deployed, authorized and funded by DemoPrep, because the
# six setup transactions around this one prove nothing and cost most of a minute.
#
# The three legs are bundled into a single transaction on purpose. Detection matches on
# per-pool *block* state, so three legs in one transaction and three in three traverse
# identical code — the bundle only guarantees they land adjacent and in order, which three
# separate sends cannot on a load-balanced public RPC.
source "$(dirname "$0")/demo-lib.sh"

[ -n "${BUNDLER_ADDRESS:-}" ] || die "BUNDLER_ADDRESS not set — run: forge script script/DemoPrep.s.sol --broadcast --slow"

OPEN=${SANDWICH_OPEN:-50000000000000000000}    # attacker's opening leg
VICTIM_SIZE=${SANDWICH_VICTIM:-30000000000000000000}

# A fresh attacker every run, unless one is pinned.
#
# This is not cosmetic. The closing leg is priced at MAX_FEE and the rebate is the difference
# between that cap and what the fee would otherwise have been — so an attacker whose toxicity
# has already saturated from earlier takes is *already* being charged the cap, leaving zero
# headroom, and the victim is credited nothing. The beat silently dies with no error.
#
# The bundler names the attacker through hookData on the hook's trusted-router path, so this
# address needs no key and no funds. It is a label, and a fresh one each take is free.
ATTACKER=${SANDWICH_ATTACKER:-$(cast wallet new --json 2>/dev/null | python3 -c "import json,sys;print(json.load(sys.stdin)[0]['address'])")}
[ -n "$ATTACKER" ] || die "could not derive a fresh attacker address"

printf '%s\n' "${DIM}attacker ${ATTACKER:0:10}… opens, a third party trades into the worse price, attacker reverses…${OFF}"

send_retry cast send "$BUNDLER_ADDRESS" \
  "runSandwich((address,address,uint24,int24,address),address,address,uint256,uint256)" \
  "$POOL_KEY" "$ATTACKER" "$CLEAN_ADDRESS" "$OPEN" "$VICTIM_SIZE" \
  --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url "$RPC" --json >/tmp/glyph-sandwich.json \
  || { head -c 300 /tmp/glyph-sandwich.json; echo; die "sandwich failed"; }

score=$(cast call "$REGISTRY_ADDRESS" "scoreOf(address)(uint16)" "$ATTACKER" --rpc-url "$RPC" | awk '{print $1}')
owed=$(cast call "$VAULT_ADDRESS" "claimable(address,address)(uint256)" "$CLEAN_ADDRESS" "$CURRENCY0" --rpc-url "$RPC" | awk '{print $1}')

SCORE="$score" OWED="$owed" HOOK="$HOOK_ADDRESS" \
  BOLD="$BOLD" DIM="$DIM" OFF="$OFF" AMBER="$AMBER" TEAL="$TEAL" \
  python3 script/_show_sandwich.py < /tmp/glyph-sandwich.json
