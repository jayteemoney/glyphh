"use client";

import { useAccount, useChainId, useConnect, useDisconnect, useSwitchChain } from "wagmi";
import { useMounted } from "@/hooks/useMounted";
import { unichainSepolia } from "@/lib/wagmi";
import { shortAddr } from "@/lib/format";

/**
 * The one wallet button used everywhere. Header-sized by default, CTA-sized with
 * `size="lg"`. Connected state shows the address and disconnects on click; a wallet
 * on the wrong network gets a one-click switch instead.
 */
export function ConnectButton({ size = "sm" }: { size?: "sm" | "lg" }) {
  const mounted = useMounted();

  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const { connect, connectors, isPending, error } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain, isPending: switching } = useSwitchChain();

  const base =
    size === "lg"
      ? "rounded-full px-7 py-3 text-sm font-medium transition-transform hover:scale-[1.03]"
      : "rounded-full px-4 py-1.5 text-sm font-medium transition-colors";

  // Render a stable placeholder until mounted so SSR and client HTML match.
  if (!mounted) {
    return (
      <button className={`${base} bg-foreground text-background opacity-80`} disabled>
        Connect wallet
      </button>
    );
  }

  if (isConnected && address) {
    if (chainId !== unichainSepolia.id) {
      return (
        <button
          onClick={() => switchChain({ chainId: unichainSepolia.id })}
          disabled={switching}
          className={`${base} border border-amber-500/40 bg-amber-500/10 text-amber-600 hover:bg-amber-500/20 dark:text-amber-400`}
        >
          {switching ? "Switching…" : "Switch network"}
        </button>
      );
    }
    return (
      <button
        onClick={() => disconnect()}
        title="Click to disconnect"
        className={`${base} group border border-emerald-500/30 bg-emerald-500/10 font-mono text-emerald-600 hover:border-red-500/40 hover:bg-red-500/10 hover:text-red-500 dark:text-emerald-400`}
      >
        <span className="group-hover:hidden">{shortAddr(address)}</span>
        <span className="hidden group-hover:inline">Disconnect</span>
      </button>
    );
  }

  return (
    <span className="inline-flex flex-col items-end gap-1">
      <button
        onClick={() => connect({ connector: connectors[0] })}
        disabled={isPending}
        className={`${base} bg-foreground text-background ${
          size === "sm" ? "hover:opacity-85" : ""
        }`}
      >
        {isPending ? "Connecting…" : "Connect wallet"}
      </button>
      {error && (
        <span className="text-[11px] text-red-500">
          {error.message.includes("Provider not found") || error.message.includes("not detected")
            ? "No wallet found. Install MetaMask first."
            : "Connection failed. Try again."}
        </span>
      )}
    </span>
  );
}
