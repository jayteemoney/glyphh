import { formatUnits } from "viem";
import type { Donation } from "@/hooks/useGlyphEvents";

export function PoolStats({
  donations,
  toxicCount,
  flaggedCount,
}: {
  donations: Donation[];
  toxicCount: number;
  flaggedCount: number;
}) {
  const sum0 = donations.reduce((a, d) => a + d.amount0, BigInt(0));
  const sum1 = donations.reduce((a, d) => a + d.amount1, BigInt(0));

  return (
    <section className="grid grid-cols-2 gap-4 sm:grid-cols-4">
      <Stat label="LP donated (t0)" value={fmt(sum0)} accent="emerald" />
      <Stat label="LP donated (t1)" value={fmt(sum1)} accent="emerald" />
      <Stat label="Toxic trades" value={String(toxicCount)} accent="red" />
      <Stat label="Flagged wallets" value={String(flaggedCount)} accent="amber" />
    </section>
  );
}

function fmt(v: bigint): string {
  const n = Number(formatUnits(v, 18));
  if (n === 0) return "0";
  if (n < 0.0001) return "<0.0001";
  return n.toLocaleString(undefined, { maximumFractionDigits: 4 });
}

const accents: Record<string, string> = {
  emerald: "text-emerald-500",
  red: "text-red-500",
  amber: "text-amber-500",
};

function Stat({ label, value, accent }: { label: string; value: string; accent: string }) {
  return (
    <div className="rounded-2xl border border-black/10 bg-white/60 p-4 shadow-sm backdrop-blur dark:border-white/10 dark:bg-white/3">
      <p className="text-xs uppercase tracking-wider text-zinc-400">{label}</p>
      <p className={`mt-1 text-2xl font-semibold tabular-nums ${accents[accent]}`}>{value}</p>
    </div>
  );
}
