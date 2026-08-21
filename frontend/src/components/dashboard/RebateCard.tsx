"use client";

import { formatUnits } from "viem";
import { useRebate } from "@/hooks/useRebate";

const amount = (v: bigint) => {
  const n = Number(formatUnits(v, 18));
  return n < 0.0001 ? n.toExponential(2) : n.toLocaleString(undefined, { maximumFractionDigits: 4 });
};

/**
 * What the pool owes you for having been sandwiched — and the button that pays it out.
 *
 * Most MEV hooks stop at charging the attacker more, which moves the money to LPs. But
 * the party a sandwich actually harms is the trader caught in the middle, so Glyph routes
 * that surcharge here instead, credited to them by address.
 */
export function RebateCard() {
  const { balances, hasRebate, claim, isPending, isConfirming, isSuccess, configured } = useRebate();

  if (!configured) return null;

  return (
    <section
      className={`rounded-2xl border px-5 py-4 transition-colors ${
        hasRebate
          ? "border-emerald-500/30 bg-emerald-500/5"
          : "border-white/10 bg-white/[0.02]"
      }`}
    >
      <header className="flex flex-wrap items-baseline justify-between gap-2">
        <h2 className="text-sm font-semibold uppercase tracking-wider text-zinc-500">
          Sandwich rebate
        </h2>
        {isSuccess && !hasRebate && (
          <span className="text-xs text-emerald-600 dark:text-emerald-400">Paid out</span>
        )}
      </header>

      {!hasRebate ? (
        <p className="mt-2 text-sm leading-relaxed text-zinc-500">
          Nothing owed to you — you haven&apos;t been sandwiched in a Glyph pool. If you ever
          are, the attacker&apos;s surcharge lands here in your name, not in the LPs&apos;
          fee growth.
        </p>
      ) : (
        <>
          <p className="mt-2 text-sm leading-relaxed text-zinc-500">
            You were sandwiched. The attacker paid the maximum fee, and the part above the
            normal rate was escrowed for you.
          </p>
          <ul className="mt-3 flex flex-col gap-2">
            {balances
              .filter((b) => b.amount > BigInt(0))
              .map((b) => (
                <li
                  key={b.currency}
                  className="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-white/5 bg-white/[0.03] px-3 py-2.5"
                >
                  <span className="tabular-nums">
                    <span className="text-base font-semibold">{amount(b.amount)}</span>{" "}
                    <span className="text-xs text-zinc-500">{b.symbol}</span>
                  </span>
                  <button
                    type="button"
                    onClick={() => claim(b.currency)}
                    disabled={isPending || isConfirming}
                    className="rounded-full bg-emerald-600 px-4 py-1.5 text-xs font-medium text-white transition-colors hover:bg-emerald-500 disabled:cursor-not-allowed disabled:opacity-50"
                  >
                    {isPending ? "Confirm in wallet…" : isConfirming ? "Claiming…" : "Claim"}
                  </button>
                </li>
              ))}
          </ul>
        </>
      )}
    </section>
  );
}
