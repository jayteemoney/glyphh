import { REGISTRY_ADDRESS, HOOK_ADDRESS } from "@/config/contracts";
import { shortAddr } from "@/lib/format";

// The live Unichain Sepolia deployment (docs/DEPLOYMENT.md). Every additional pool
// created with the Glyph hook joins the same registry — and the same protection.
const POOLS = [
  {
    name: "GLYPH-A / GLYPH-B",
    pair: "0x2762…cA69 / 0xCAF1…3Aa7",
    note: "The live proving ground. Fees follow each swapper's reputation, and everything charged above 0.30% lands on the LPs.",
    live: true,
  },
  {
    name: "Your pool",
    pair: "any v4 pair",
    note: "Launch any v4 pool with the Glyph hook and it knows every scored wallet from its very first block. Protection is instant, not earned.",
    live: false,
  },
];

export default function PoolsPage() {
  return (
    <main className="mx-auto w-full max-w-4xl flex-1 px-4 py-8 sm:px-6 sm:py-10">
      <h1 className="text-xl font-semibold tracking-tight sm:text-2xl">Glyph pools</h1>
      <p className="mt-1 text-sm text-zinc-500">
        Every Glyph pool shares one reputation registry. Get flagged in one pool and within
        seconds every other pool quotes you the elevated fee too.
      </p>

      <div className="mt-8 grid gap-4 sm:grid-cols-2">
        {POOLS.map((p) => (
          <div
            key={p.name}
            className="card card-hover rounded-2xl p-5"
          >
            <div className="flex items-center justify-between gap-2">
              <h2 className="min-w-0 truncate text-base font-semibold sm:text-lg">{p.name}</h2>
              <span
                className={`shrink-0 rounded-full px-2 py-0.5 text-xs ${
                  p.live
                    ? "bg-emerald-500/10 text-emerald-600 dark:text-emerald-400"
                    : "bg-black/5 text-zinc-500 dark:bg-white/10"
                }`}
              >
                {p.live ? "live · dynamic fee" : "bring your own"}
              </span>
            </div>
            <p className="mt-1 truncate font-mono text-sm text-zinc-700 dark:text-zinc-300">{p.pair}</p>
            <p className="mt-3 text-sm text-zinc-500">{p.note}</p>
          </div>
        ))}
      </div>

      <dl className="card mt-8 space-y-2 rounded-2xl p-5 text-sm">
        <Row label="Hook" value={HOOK_ADDRESS ? shortAddr(HOOK_ADDRESS) : "not configured"} />
        <Row label="Registry" value={REGISTRY_ADDRESS ? shortAddr(REGISTRY_ADDRESS) : "not configured"} />
        <Row label="Cross-pool engine" value="live" />
      </dl>
    </main>
  );
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex items-center justify-between gap-3">
      <dt className="shrink-0 text-zinc-500">{label}</dt>
      <dd className="min-w-0 truncate text-right font-mono text-zinc-700 dark:text-zinc-300">{value}</dd>
    </div>
  );
}
