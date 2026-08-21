"use client";

import type { FeeQuote } from "@/hooks/useFeeQuotes";
import { shortAddr } from "@/lib/format";

const pct = (pips: number) => (pips / 10_000).toFixed(3) + "%";

/** Each term, with the layer it comes from and how it moves the price. */
const TERMS = [
  { key: "base", label: "Base", tone: "bg-zinc-400", sign: 1 },
  { key: "arb", label: "Arbitrage", tone: "bg-red-500", sign: 1 },
  { key: "unproven", label: "Unproven", tone: "bg-amber-500", sign: 1 },
  { key: "toxic", label: "Toxicity", tone: "bg-orange-500", sign: 1 },
  { key: "trustDiscount", label: "Trust discount", tone: "bg-emerald-500", sign: -1 },
] as const;

export function FeeBreakdown({ quotes }: { quotes: FeeQuote[] }) {
  return (
    <section className="card rounded-2xl p-4 sm:p-5">
      <header className="mb-1 flex flex-wrap items-center justify-between gap-2">
        <h2 className="text-sm font-semibold uppercase tracking-wider text-zinc-500">
          Why each swap was priced
        </h2>
        <span className="text-xs text-zinc-400">{quotes.length} recent swaps</span>
      </header>
      <p className="mb-4 text-xs leading-relaxed text-zinc-500">
        Glyph charges for what a swap <em>does to the pool</em>, not for who sent it. Every
        term below is emitted on chain, so any fee here can be accounted for line by line.
      </p>

      {quotes.length === 0 ? (
        <Empty label="No swaps yet. The next one through a Glyph pool appears here with its price broken out." />
      ) : (
        <ul className="flex flex-col gap-2">
          {quotes.slice(0, 12).map((q) => (
            <QuoteRow key={`${q.txHash}-${q.blockNumber}-${q.swapper}`} quote={q} />
          ))}
        </ul>
      )}
    </section>
  );
}

function QuoteRow({ quote }: { quote: FeeQuote }) {
  const charged = quote.base + quote.arb + quote.unproven + quote.toxic;
  const scale = Math.max(charged, quote.final, 1);

  // The headline: what made this swap different from the base rate.
  const driver =
    quote.arb > 0
      ? { label: "closed an oracle gap", tone: "text-red-600 dark:text-red-400" }
      : quote.toxic > 0
        ? { label: "flagged wallet", tone: "text-orange-600 dark:text-orange-400" }
        : quote.unproven > 0
          ? { label: "large swap, no record", tone: "text-amber-600 dark:text-amber-400" }
          : quote.trustDiscount > 0
            ? { label: "earned discount", tone: "text-emerald-600 dark:text-emerald-400" }
            : { label: "base rate", tone: "text-zinc-500" };

  return (
    <li className="rounded-xl border border-white/5 bg-white/[0.02] p-3">
      <div className="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
        <span className="font-mono text-xs text-zinc-400">{shortAddr(quote.swapper)}</span>
        <span className="flex items-baseline gap-2">
          <span className={`text-xs ${driver.tone}`}>{driver.label}</span>
          <span className="text-base font-semibold tabular-nums">{pct(quote.final)}</span>
        </span>
      </div>

      {/* Stacked bar: premiums add, the trust discount subtracts. */}
      <div className="mt-2 flex h-2 w-full overflow-hidden rounded-full bg-white/5">
        {TERMS.filter((t) => t.sign > 0).map((t) => {
          const v = quote[t.key as keyof FeeQuote] as number;
          if (!v) return null;
          return (
            <div
              key={t.key}
              className={t.tone}
              style={{ width: `${(v / scale) * 100}%` }}
              title={`${t.label} ${pct(v)}`}
            />
          );
        })}
      </div>

      <div className="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-[11px] tabular-nums text-zinc-500">
        {TERMS.map((t) => {
          const v = quote[t.key as keyof FeeQuote] as number;
          if (!v) return null;
          return (
            <span key={t.key} className="inline-flex items-center gap-1.5">
              <span className={`h-1.5 w-1.5 rounded-full ${t.tone}`} />
              {t.label} {t.sign < 0 ? "−" : "+"}
              {pct(v)}
            </span>
          );
        })}
      </div>
    </li>
  );
}

function Empty({ label }: { label: string }) {
  return (
    <p className="rounded-xl border border-dashed border-white/10 px-4 py-8 text-center text-sm text-zinc-500">
      {label}
    </p>
  );
}
