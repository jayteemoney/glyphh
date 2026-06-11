"use client";

import { useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { useAccount, useConnect } from "wagmi";

/**
 * Landing-page CTA that adapts to wallet state. Connected visitors go straight to
 * the dashboard; everyone else gets the wallet prompt and is taken there the moment
 * the connection lands.
 */
export function WalletCTA({
  connectedLabel = "Open the live dashboard",
  disconnectedLabel = "Connect wallet to enter",
}: {
  connectedLabel?: string;
  disconnectedLabel?: string;
}) {
  const [mounted, setMounted] = useState(false);
  useEffect(() => setMounted(true), []);

  const router = useRouter();
  const { isConnected } = useAccount();
  const { connect, connectors, isPending, error } = useConnect();
  const wantsDashboard = useRef(false);

  // Follow through once the connection the visitor asked for completes.
  useEffect(() => {
    if (isConnected && wantsDashboard.current) {
      wantsDashboard.current = false;
      router.push("/dashboard");
    }
  }, [isConnected, router]);

  const cls =
    "inline-block rounded-full bg-foreground px-7 py-3 text-sm font-medium text-background transition-transform hover:scale-[1.03] disabled:opacity-70";

  if (!mounted) {
    return (
      <button className={cls} disabled>
        {disconnectedLabel}
      </button>
    );
  }

  if (isConnected) {
    return (
      <button className={cls} onClick={() => router.push("/dashboard")}>
        {connectedLabel}
      </button>
    );
  }

  return (
    <span className="inline-flex flex-col items-center gap-2">
      <button
        className={cls}
        disabled={isPending}
        onClick={() => {
          wantsDashboard.current = true;
          connect({ connector: connectors[0] });
        }}
      >
        {isPending ? "Connecting…" : disconnectedLabel}
      </button>
      {error && (
        <span className="text-xs text-red-500">
          {error.message.includes("Provider not found") || error.message.includes("not detected")
            ? "No wallet found. Install MetaMask first."
            : "Connection failed. Try again."}
        </span>
      )}
    </span>
  );
}
