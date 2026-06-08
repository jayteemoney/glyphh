import { http, createConfig } from "wagmi";
import { defineChain } from "viem";

/// Unichain Sepolia — defined locally so we don't depend on a specific viem/chains export.
export const unichainSepolia = defineChain({
  id: 1301,
  name: "Unichain Sepolia",
  nativeCurrency: { name: "Sepolia Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: {
      http: [process.env.NEXT_PUBLIC_RPC_URL ?? "https://sepolia.unichain.org"],
    },
  },
  blockExplorers: {
    default: { name: "Uniscan", url: "https://sepolia.uniscan.xyz" },
  },
  testnet: true,
});

export const config = createConfig({
  chains: [unichainSepolia],
  transports: {
    [unichainSepolia.id]: http(),
  },
});

declare module "wagmi" {
  interface Register {
    config: typeof config;
  }
}
