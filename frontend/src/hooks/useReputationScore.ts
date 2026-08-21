"use client";

import { useReadContract } from "wagmi";
import { REGISTRY_ADDRESS, registryAbi } from "@/config/contracts";

/**
 * A wallet's two standing figures, both decay-adjusted on read.
 *
 * They are independent axes rather than ends of one scale. Toxicity is what a wallet has
 * done wrong recently and fades over 7 days; trust is what it has proven over settled
 * benign volume and fades over 30. A wallet can carry both, and the fee model resolves
 * that — it does not need the registry to pick a winner.
 */
export function useReputationScore(wallet?: `0x${string}`) {
  const enabled = Boolean(REGISTRY_ADDRESS && wallet);
  const common = {
    address: REGISTRY_ADDRESS ? (REGISTRY_ADDRESS as `0x${string}`) : undefined,
    abi: registryAbi,
    args: wallet ? ([wallet] as const) : undefined,
    query: { enabled },
  };

  const scoreQuery = useReadContract({ ...common, functionName: "scoreOf" });
  const trustQuery = useReadContract({ ...common, functionName: "trustOf" });

  return {
    score: scoreQuery.data !== undefined ? Number(scoreQuery.data) : undefined,
    trust: trustQuery.data !== undefined ? Number(trustQuery.data) : undefined,
    isLoading: scoreQuery.isLoading || trustQuery.isLoading,
    error: scoreQuery.error ?? trustQuery.error,
    refetch: () => {
      scoreQuery.refetch();
      trustQuery.refetch();
    },
  };
}
