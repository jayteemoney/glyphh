import { http, createConfig } from "wagmi";
import { injected } from "wagmi/connectors";
import { defineChain } from "viem";

/**
 * The chain the dashboard talks to.
 *
 * Defaults to Unichain Sepolia, which is where Glyph is deployed. It is overridable so the
 * same build can be pointed at a local Anvil node — which the demo needs: the recorded
 * walkthrough runs the whole stack locally so a take never depends on a public RPC, and a
 * dashboard hardwired to 1301 would sit empty beside a terminal that was clearly working.
 *
 * Set NEXT_PUBLIC_CHAIN_ID=31337 and NEXT_PUBLIC_RPC_URL=http://127.0.0.1:8545 for that.
 */
const CHAIN_ID = Number(process.env.NEXT_PUBLIC_CHAIN_ID ?? 1301);
const RPC_URL = process.env.NEXT_PUBLIC_RPC_URL ?? "https://sepolia.unichain.org";

const PRESETS: Record<number, { name: string; explorer?: { name: string; url: string } }> = {
  1301: {
    name: "Unichain Sepolia",
    explorer: { name: "Uniscan", url: "https://sepolia.uniscan.xyz" },
  },
  31337: { name: "Anvil" },
};

const preset = PRESETS[CHAIN_ID] ?? { name: `Chain ${CHAIN_ID}` };

/// Defined locally so we don't depend on a specific viem/chains export.
export const activeChain = defineChain({
  id: CHAIN_ID,
  name: preset.name,
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [RPC_URL] } },
  ...(preset.explorer ? { blockExplorers: { default: preset.explorer } } : {}),
  testnet: true,
});

/// Kept as a named export so existing imports keep working.
export const unichainSepolia = activeChain;

export const config = createConfig({
  chains: [activeChain],
  connectors: [injected()],
  transports: {
    [activeChain.id]: http(RPC_URL),
  },
  ssr: true,
});

declare module "wagmi" {
  interface Register {
    config: typeof config;
  }
}
