import Link from "next/link";

const DIFFS = [
  { hook: "DetoxHook", axis: "Price divergence (Pyth)", highlight: false },
  { hook: "AdaptiveSwap", axis: "Volatility", highlight: false },
  { hook: "Glyph", axis: "The trader — reputation + cross-pool", highlight: true },
];

const FEATURES = [
  "Per-wallet reputation score (0–10,000)",
  "EIP-712 ML attestations, verified on-chain",
  "Pyth pull-oracle first-touch toxicity check",
  "Reactive Network cross-pool propagation",
  "Brevis ZK-proven trade history",
  "7-day linear decay — no permanent blacklist",
];

export default function Home() {
  return (
    <main className="flex-1">
      <section className="mx-auto w-full max-w-5xl px-6 py-20">
        <span className="inline-flex items-center gap-2 rounded-full border border-black/10 px-3 py-1 text-xs text-zinc-500 dark:border-white/10">
          <span className="h-1.5 w-1.5 rounded-full bg-emerald-500" /> Uniswap v4 hook · UHI9
        </span>

        <h1 className="mt-6 max-w-3xl text-4xl font-semibold leading-tight tracking-tight sm:text-5xl">
          Swaps priced by <span className="text-emerald-500">who</span> is trading, not just what.
        </h1>

        <p className="mt-5 max-w-2xl text-lg text-zinc-500">
          Glyph gives every wallet a reputation score from its on-chain history. Clean traders pay
          0.30%. Sandwichers, arbitrageurs and MEV bots pay up to 10% — and the excess is donated
          straight back to LPs.
        </p>

        <div className="mt-8 flex flex-wrap gap-3">
          <Link href="/dashboard" className="rounded-full bg-foreground px-5 py-2.5 text-sm font-medium text-background">
            Open live dashboard
          </Link>
          <Link href="/pools" className="rounded-full border border-black/10 px-5 py-2.5 text-sm font-medium dark:border-white/15">
            View pools
          </Link>
        </div>

        <div className="mt-16 overflow-hidden rounded-2xl border border-black/10 dark:border-white/10">
          <table className="w-full text-left text-sm">
            <thead className="bg-black/3 text-xs uppercase tracking-wider text-zinc-500 dark:bg-white/3">
              <tr>
                <th className="px-5 py-3 font-medium">Hook</th>
                <th className="px-5 py-3 font-medium">Reacts to</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-black/5 dark:divide-white/5">
              {DIFFS.map((d) => (
                <tr key={d.hook} className={d.highlight ? "bg-emerald-500/5" : ""}>
                  <td className="px-5 py-3 font-medium">{d.hook}</td>
                  <td
                    className={`px-5 py-3 ${
                      d.highlight ? "font-medium text-emerald-600 dark:text-emerald-400" : "text-zinc-500"
                    }`}
                  >
                    {d.axis}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        <div className="mt-10 grid gap-3 sm:grid-cols-2">
          {FEATURES.map((f) => (
            <div
              key={f}
              className="flex items-center gap-2 rounded-xl border border-black/5 px-4 py-3 text-sm dark:border-white/5"
            >
              <span className="text-emerald-500">▸</span> {f}
            </div>
          ))}
        </div>
      </section>
    </main>
  );
}
