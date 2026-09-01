"""Render the hook's FeeQuoted event as the decomposition it is.

Reads a `cast send --json` receipt on stdin and picks the hook's own FeeQuoted log out of it.
The terms print in the order the argument runs: base, then what each layer added, then the
sum. Only the arb line is highlighted, because on this demo it is the only one that should
ever be non-zero — and the whole claim is that it is non-zero in exactly one direction.
"""

import json
import os
import sys

# keccak256("FeeQuoted(bytes32,address,uint24,uint24,uint24,uint24,uint24,uint24)")
TOPIC0 = "0xa6787ad69a9d33b00c4bf7ce667af0b8414ec911e44d254158fe27d05055a70c"

receipt = json.load(sys.stdin)
if receipt.get("status") not in ("0x1", 1, "1"):
    sys.exit(f"  swap did not succeed (status {receipt.get('status')})")

hook = os.environ.get("HOOK", "").lower()
rows = [
    lg for lg in receipt.get("logs", [])
    if lg["topics"] and lg["topics"][0].lower() == TOPIC0
    and (not hook or lg["address"].lower() == hook)
]
if not rows:
    sys.exit("  the swap landed but emitted no FeeQuoted — wrong pool key?")

data = rows[-1]["data"][2:]
v = [int(data[i * 64:(i + 1) * 64], 16) for i in range(6)]

B = os.environ.get("BOLD", "")
D = os.environ.get("DIM", "")
O = os.environ.get("OFF", "")
H = os.environ.get("HUE", "")
moved = os.environ.get("MOVED", "")

print()
print(f"  {D}this swap moved the pool {moved}{O}")
print()
for name, val in zip(("base", "arb", "unproven", "toxic", "discount"), v[:5]):
    hot = H if (name == "arb" and val) else ""
    end = O if hot else ""
    print(f"    {name:<10}{hot}{val:>7}{end}")
print(f"    {D}{'-' * 17}{O}")
print(f"    {B}{H}final     {v[5]:>7}   =  {v[5] / 10000:.3f}%{O}")
print()
