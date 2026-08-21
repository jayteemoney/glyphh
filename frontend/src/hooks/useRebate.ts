"use client";

import { useEffect, useMemo } from "react";
import { useAccount, useReadContract, useWaitForTransactionReceipt, useWriteContract } from "wagmi";
import { VAULT_ADDRESS, vaultAbi } from "@/config/contracts";

const CURRENCY0 = (process.env.NEXT_PUBLIC_CURRENCY0 ?? "") as `0x${string}` | "";
const CURRENCY1 = (process.env.NEXT_PUBLIC_CURRENCY1 ?? "") as `0x${string}` | "";

export type RebateBalance = {
  currency: `0x${string}`;
  symbol: string;
  amount: bigint;
};

/**
 * What the vault owes the connected wallet, and the ability to withdraw it.
 *
 * The vault holds surcharges taken from sandwich attackers, credited to the trader who
 * was squeezed between the two legs. Paying that to LPs — as a hook that merely charges
 * attackers more would — leaves the actual victim exactly as badly off, so it is escrowed
 * here by address instead.
 */
export function useRebate() {
  const { address } = useAccount();
  const vaultReady = Boolean(VAULT_ADDRESS);
  const enabled = Boolean(vaultReady && address);

  const c0 = useReadContract({
    address: vaultReady ? (VAULT_ADDRESS as `0x${string}`) : undefined,
    abi: vaultAbi,
    functionName: "claimable",
    args: address && CURRENCY0 ? [address, CURRENCY0 as `0x${string}`] : undefined,
    query: { enabled: Boolean(enabled && CURRENCY0), refetchInterval: 5_000 },
  });

  const c1 = useReadContract({
    address: vaultReady ? (VAULT_ADDRESS as `0x${string}`) : undefined,
    abi: vaultAbi,
    functionName: "claimable",
    args: address && CURRENCY1 ? [address, CURRENCY1 as `0x${string}`] : undefined,
    query: { enabled: Boolean(enabled && CURRENCY1), refetchInterval: 5_000 },
  });

  const { writeContract, data: txHash, isPending, reset } = useWriteContract();
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash: txHash });

  // Once a claim confirms, the balances are stale by definition.
  useEffect(() => {
    if (!isSuccess) return;
    c0.refetch();
    c1.refetch();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isSuccess]);

  const balances = useMemo<RebateBalance[]>(() => {
    const rows: RebateBalance[] = [];
    if (CURRENCY0) rows.push({ currency: CURRENCY0 as `0x${string}`, symbol: "GLYPH-A", amount: (c0.data as bigint) ?? BigInt(0) });
    if (CURRENCY1) rows.push({ currency: CURRENCY1 as `0x${string}`, symbol: "GLYPH-B", amount: (c1.data as bigint) ?? BigInt(0) });
    return rows;
  }, [c0.data, c1.data]);

  const total = balances.reduce((sum, b) => sum + b.amount, BigInt(0));

  const claim = (currency: `0x${string}`) => {
    if (!vaultReady) return;
    writeContract({
      address: VAULT_ADDRESS as `0x${string}`,
      abi: vaultAbi,
      functionName: "claim",
      args: [currency],
    });
  };

  return {
    balances,
    total,
    hasRebate: total > BigInt(0),
    claim,
    isPending,
    isConfirming,
    isSuccess,
    txHash,
    reset,
    configured: vaultReady && Boolean(CURRENCY0 || CURRENCY1),
  };
}
