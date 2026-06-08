"use client";

import { useGlyphEvents } from "@/hooks/useGlyphEvents";
import { ScoreTable } from "@/components/dashboard/ScoreTable";
import { ToxicTradesFeed } from "@/components/dashboard/ToxicTradesFeed";
import { PoolStats } from "@/components/dashboard/PoolStats";

export default function DashboardPage() {
  const { scores, toxicTrades, donations, configured } = useGlyphEvents();

  return (
    <main className="mx-auto w-full max-w-6xl flex-1 px-6 py-10">
      <div className="mb-8 flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight">Live reputation dashboard</h1>
          <p className="mt-1 text-sm text-zinc-500">
            Every Glyph pool on Unichain, streaming through one registry — and one cross-pool sensor.
          </p>
        </div>
        <span className="flex items-center gap-2 rounded-full border border-black/10 px-3 py-1 text-xs text-zinc-500 dark:border-white/10">
          <span className="h-2 w-2 rounded-full bg-emerald-500" /> Unichain Sepolia · 1301
        </span>
      </div>

      {!configured && (
        <div className="mb-6 rounded-2xl border border-amber-500/30 bg-amber-500/5 px-4 py-3 text-sm text-amber-700 dark:text-amber-300">
          No contract address configured. Set <code className="font-mono">NEXT_PUBLIC_REGISTRY_ADDRESS</code> and{" "}
          <code className="font-mono">NEXT_PUBLIC_HOOK_ADDRESS</code> in{" "}
          <code className="font-mono">frontend/.env.local</code> to go live. The UI below updates the moment events arrive.
        </div>
      )}

      <PoolStats donations={donations} toxicCount={toxicTrades.length} flaggedCount={scores.length} />

      <div className="mt-6 grid gap-6 lg:grid-cols-3">
        <div className="lg:col-span-2">
          <ScoreTable scores={scores} />
        </div>
        <div className="lg:col-span-1">
          <ToxicTradesFeed trades={toxicTrades} />
        </div>
      </div>
    </main>
  );
}
