"use client";

import { useReadContract } from "wagmi";
import { REGISTRY_ADDRESS, registryAbi } from "@/config/contracts";

/// Reads a wallet's effective (decay-adjusted) score straight from the registry.
export function useReputationScore(wallet?: `0x${string}`) {
  const enabled = Boolean(REGISTRY_ADDRESS && wallet);
  const { data, isLoading, error, refetch } = useReadContract({
    address: REGISTRY_ADDRESS ? (REGISTRY_ADDRESS as `0x${string}`) : undefined,
    abi: registryAbi,
    functionName: "scoreOf",
    args: wallet ? [wallet] : undefined,
    query: { enabled },
  });

  return {
    score: data !== undefined ? Number(data) : undefined,
    isLoading,
    error,
    refetch,
  };
}
