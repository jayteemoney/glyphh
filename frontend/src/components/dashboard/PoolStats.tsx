import { formatUnits } from "viem";
import type { Sandwich } from "@/hooks/useGlyphEvents";

/**
 * The four numbers that say what the pool did, not what it is.
 *
 * v1 showed LP donations here. v2 does not have them: the premium reaches LPs through
 * v4's dynamic fee override as fee growth, which is the correct mechanism but is not an
 * event to count. What *is* countable, and more interesting, is the money returned to
 * sandwiched traders — the thing that separates this from a hook that merely charges
 * attackers more.
 */
export function PoolStats({
  sandwiches,
  toxicCount,
  crossPoolCount,
}: {
  sandwiches: Sandwich[];
  toxicCount: number;
  crossPoolCount: number;
}) {
  const rebated = sandwiches.reduce((a, s) => a + s.rebate, BigInt(0));

  return (
    <section className="grid grid-cols-2 gap-4 sm:grid-cols-4">
      <Stat label="Returned to victims" value={fmt(rebated)} accent="emerald" />
      <Stat label="Sandwiches caught" value={String(sandwiches.length)} accent="red" />
      <Stat label="Toxic flags" value={String(toxicCount)} accent="amber" />
      <Stat
        label="Flagged in 2+ pools"
        value={String(crossPoolCount)}
        accent="amber"
        hint="Wallets the cross-pool layer propagates"
      />
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

function Stat({
  label,
  value,
  accent,
  hint,
}: {
  label: string;
  value: string;
  accent: string;
  hint?: string;
}) {
  return (
    <div className="card card-hover rounded-2xl p-4" title={hint}>
      <p className="text-xs uppercase tracking-wider text-zinc-400">{label}</p>
      <p className={`mt-1 text-2xl font-semibold tabular-nums ${accents[accent]}`}>{value}</p>
    </div>
  );
}
