import type { ToxicTrade } from "@/hooks/useGlyphEvents";
import { shortAddr, timeAgo } from "@/lib/format";

export function ToxicTradesFeed({ trades }: { trades: ToxicTrade[] }) {
  return (
    <section className="flex h-full flex-col rounded-2xl border border-black/10 bg-white/60 p-5 shadow-sm backdrop-blur dark:border-white/10 dark:bg-white/3">
      <header className="mb-4 flex items-center justify-between">
        <h2 className="text-sm font-semibold uppercase tracking-wider text-zinc-500">Live toxic trades</h2>
        <span className="flex items-center gap-1.5 text-xs text-zinc-400">
          <span className="relative flex h-2 w-2">
            <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-red-400 opacity-75" />
            <span className="relative inline-flex h-2 w-2 rounded-full bg-red-500" />
          </span>
          live
        </span>
      </header>

      {trades.length === 0 ? (
        <div className="flex flex-1 items-center justify-center rounded-xl border border-dashed border-black/10 px-4 py-10 text-center text-sm text-zinc-400 dark:border-white/10">
          Waiting for ToxicTradeReported events…
        </div>
      ) : (
        <ul className="flex-1 space-y-2 overflow-y-auto">
          {trades.map((t, i) => (
            <li
              key={`${t.txHash ?? "x"}-${i}`}
              className="flex items-center justify-between rounded-xl border border-black/5 bg-black/2 px-3 py-2.5 dark:border-white/5 dark:bg-white/2"
            >
              <div className="min-w-0">
                <p className="font-mono text-xs text-zinc-700 dark:text-zinc-200">{shortAddr(t.wallet)}</p>
                <p className="text-[11px] text-zinc-400">
                  pool {shortAddr(t.pool)} · {timeAgo(t.timestamp)}
                </p>
              </div>
              <span className="ml-3 shrink-0 rounded-full bg-red-500/10 px-2 py-0.5 text-xs font-semibold text-red-500 ring-1 ring-red-500/30">
                +{t.severity}
              </span>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
