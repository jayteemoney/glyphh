#!/usr/bin/env bash
# Put the reference exactly 101 bps below the live pool price.
#
# 101 bps is the number the README, docs/DEPLOYMENT.md and the deck all quote:
#   (101 - 40 tolerance) x 60% capture = 3660 fee units on top of the 3000 base = 0.666%.
#
# It is solved from the pool's *current* price rather than hardcoded, because every swap moves
# the pool. A flat 0.99e18 gave exactly 101 bps only on a pool sitting at parity — by the second
# take the fee on camera would have drifted off the number every document promises.
#
# Run this between takes. One transaction, about three seconds.
source "$(dirname "$0")/demo-lib.sh"

price=$(pool_price) || die "could not read the pool price"
ref=$(python3 -c "print($price * 10000 // 10101)")

printf '%s\n' "${DIM}pool price $price  ->  reference $ref${OFF}"
send_retry cast send "$ORACLE_ADDRESS" "setPrice(bytes32,uint256,bool)" "$POOL_ID" "$ref" true \
  --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url "$RPC" >/dev/null || die "setPrice failed"

# Drain any rebate left over from the previous take, so the sandwich beat shows the victim's
# claim rising from zero rather than from whatever the last rehearsal left behind.
if [ -n "${CLEAN_PRIVATE_KEY:-}" ]; then
  owed=$(cast call "$VAULT_ADDRESS" "claimable(address,address)(uint256)" "$CLEAN_ADDRESS" "$CURRENCY0" --rpc-url "$RPC" | awk '{print $1}')
  if [ "${owed:-0}" != "0" ]; then
    send_retry cast send "$VAULT_ADDRESS" "claim(address)" "$CURRENCY0" \
      --private-key "$CLEAN_PRIVATE_KEY" --rpc-url "$RPC" >/dev/null \
      && printf '%s\n' "${DIM}drained the victim's leftover rebate from the last take${OFF}"
  fi
fi

printf '%s\n' "${BOLD}reference parked 101 bps below the pool.${OFF} The gap is now open."
