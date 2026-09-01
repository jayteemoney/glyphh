"""Fetch real ETH/USDT 1-minute klines from Binance's public data mirror.

No API key, no authentication. The mirror is the same data the exchange serves, and the
only thing this backtest takes from it is the mid-price series that stands in for "the
true price" an arbitrageur trades against.
"""

from __future__ import annotations

import json
import sys
import time
import urllib.request
from pathlib import Path

BASE = "https://data-api.binance.vision/api/v3/klines"
SYMBOL = "ETHUSDT"
INTERVAL = "1m"
PAGE = 1000

OUT = Path(__file__).parent / "data" / f"{SYMBOL}-{INTERVAL}.json"


def fetch_page(end_ms: int) -> list:
    url = f"{BASE}?symbol={SYMBOL}&interval={INTERVAL}&limit={PAGE}&endTime={end_ms}"
    with urllib.request.urlopen(url, timeout=30) as r:
        return json.loads(r.read())


def main(days: int = 30) -> None:
    minutes = days * 24 * 60
    end = int(time.time() * 1000)
    rows: list = []

    while len(rows) < minutes:
        page = fetch_page(end)
        if not page:
            break
        rows = page + rows
        end = page[0][0] - 1
        OUT.parent.mkdir(parents=True, exist_ok=True)
        OUT.write_text(json.dumps([[int(r[0]), float(r[4])] for r in rows]))
        print(f"  {len(rows):>6} candles, back to {time.strftime('%Y-%m-%d %H:%M', time.gmtime(page[0][0] / 1000))}",
              file=sys.stderr)
        time.sleep(0.1)

    rows = rows[-minutes:]
    # (open_time_ms, close_price) is all the simulation needs.
    series = [[int(r[0]), float(r[4])] for r in rows]

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(series))
    span = (series[-1][0] - series[0][0]) / 86_400_000
    print(f"wrote {len(series)} points spanning {span:.1f} days -> {OUT}", file=sys.stderr)


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 30)
