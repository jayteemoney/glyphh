#!/usr/bin/env bash
# One swap, one clean readout of the fee the hook quoted.
#
#   ./script/demo-swap.sh closing    # moves the pool toward the reference -> 0.666%
#   ./script/demo-swap.sh widening   # moves it away                       -> 0.300%
#
# Prints only the hook's own FeeQuoted event, decomposed into the terms that sum to the fee,
# because that decomposition is the entire argument.
source "$(dirname "$0")/demo-lib.sh"

DIR=${1:-closing}
AMOUNT=${DEMO_SWAP_AMOUNT:-1000000000000000000}

case "$DIR" in
  closing)  ZERO_FOR_ONE=true;  LIMIT=$MIN_SQRT_PLUS1;  HUE=$AMBER; MOVED="toward the reference" ;;
  widening) ZERO_FOR_ONE=false; LIMIT=$MAX_SQRT_MINUS1; HUE=$TEAL;  MOVED="away from the reference" ;;
  *) die "usage: $0 closing|widening" ;;
esac

printf '%s\n' "${DIM}sending ${DIR} swap…${OFF}"

# --json gives the receipt, logs included. Reading FeeQuoted straight out of it beats a
# follow-up `cast logs`: one fewer round trip, and no race against a load-balanced replica
# that has not indexed the block yet (which is exactly what bit the first version).
send_retry cast send "$SWAP_ROUTER_ADDRESS" \
  "swap((address,address,uint24,int24,address),(bool,int256,uint160),(bool,bool),bytes)" \
  "$POOL_KEY" "($ZERO_FOR_ONE,-$AMOUNT,$LIMIT)" "(false,false)" "0x" \
  --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url "$RPC" --json >/tmp/glyph-swap.json \
  || { head -c 300 /tmp/glyph-swap.json; echo; die "swap failed"; }

BOLD="$BOLD" DIM="$DIM" OFF="$OFF" HUE="$HUE" MOVED="$MOVED" HOOK="$HOOK_ADDRESS" \
  python3 script/_show_fee.py < /tmp/glyph-swap.json
