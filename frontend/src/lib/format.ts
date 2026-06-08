// Mirror of the on-chain ToxicityScoring.scoreToFee curve, so the dashboard previews
// the exact fee a wallet would pay. Fee units are Uniswap pips (1_000_000 = 100%).

export function scoreToFeeUnits(score: number): number {
  if (score <= 0) return 3_000;
  if (score >= 10_000) return 100_000;
  if (score < 2_500) return Math.round(3_000 + (score * 7_000) / 2_500);
  if (score < 7_500) return Math.round(10_000 + ((score - 2_500) * 30_000) / 5_000);
  return Math.round(40_000 + ((score - 7_500) * 60_000) / 2_500);
}

export function feePct(score: number): string {
  return (scoreToFeeUnits(score) / 10_000).toFixed(2) + "%";
}

export type Risk = "clean" | "low" | "medium" | "high";

export function riskOf(score: number): Risk {
  if (score <= 0) return "clean";
  if (score < 2_500) return "low";
  if (score < 7_500) return "medium";
  return "high";
}

export const riskRing: Record<Risk, string> = {
  clean: "text-emerald-600 bg-emerald-500/10 ring-emerald-500/30 dark:text-emerald-400",
  low: "text-lime-600 bg-lime-500/10 ring-lime-500/30 dark:text-lime-400",
  medium: "text-amber-600 bg-amber-500/10 ring-amber-500/30 dark:text-amber-400",
  high: "text-red-600 bg-red-500/10 ring-red-500/30 dark:text-red-400",
};

export const riskBar: Record<Risk, string> = {
  clean: "bg-emerald-500",
  low: "bg-lime-500",
  medium: "bg-amber-500",
  high: "bg-red-500",
};

export function shortAddr(a?: string): string {
  if (!a) return "—";
  return a.slice(0, 6) + "…" + a.slice(-4);
}

export function timeAgo(ts: number): string {
  const s = Math.floor(Date.now() / 1000) - ts;
  if (s < 0) return "now";
  if (s < 60) return `${s}s ago`;
  if (s < 3_600) return `${Math.floor(s / 60)}m ago`;
  return `${Math.floor(s / 3_600)}h ago`;
}
