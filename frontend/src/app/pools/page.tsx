import { REGISTRY_ADDRESS, HOOK_ADDRESS } from "@/config/contracts";
import { shortAddr } from "@/lib/format";

const POOLS = [
  { name: "Pool A", pair: "ETH / USDC", note: "Primary venue — first-touch detection via Pyth." },
  { name: "Pool B", pair: "ETH / USDT", note: "Guarded by cross-pool propagation from Pool A." },
];

export default function PoolsPage() {
  return (
    <main className="mx-auto w-full max-w-4xl flex-1 px-6 py-10">
      <h1 className="text-2xl font-semibold tracking-tight">Glyph pools</h1>
      <p className="mt-1 text-sm text-zinc-500">
        Two dynamic-fee v4 pools share one reputation registry. A wallet flagged in Pool A pays an
        elevated fee in Pool B within seconds — the Reactive cross-pool guarantee.
      </p>

      <div className="mt-8 grid gap-4 sm:grid-cols-2">
        {POOLS.map((p) => (
          <div
            key={p.name}
            className="rounded-2xl border border-black/10 bg-white/60 p-5 shadow-sm dark:border-white/10 dark:bg-white/3"
          >
            <div className="flex items-center justify-between">
              <h2 className="text-lg font-semibold">{p.name}</h2>
              <span className="rounded-full bg-black/5 px-2 py-0.5 text-xs text-zinc-500 dark:bg-white/10">
                dynamic fee
              </span>
            </div>
            <p className="mt-1 font-mono text-sm text-zinc-700 dark:text-zinc-300">{p.pair}</p>
            <p className="mt-3 text-sm text-zinc-500">{p.note}</p>
          </div>
        ))}
      </div>

      <dl className="mt-8 space-y-2 rounded-2xl border border-black/10 p-5 text-sm dark:border-white/10">
        <Row label="Hook" value={HOOK_ADDRESS ? shortAddr(HOOK_ADDRESS) : "not configured"} />
        <Row label="Registry" value={REGISTRY_ADDRESS ? shortAddr(REGISTRY_ADDRESS) : "not configured"} />
      </dl>
    </main>
  );
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex items-center justify-between">
      <dt className="text-zinc-500">{label}</dt>
      <dd className="font-mono text-zinc-700 dark:text-zinc-300">{value}</dd>
    </div>
  );
}
