// Shared plumbing for the Glyph demo bots: clients, ABIs, the v4 PoolKey/swap
// encoding, the on-chain score read, and the fee curve (mirrors the frontend).

import "dotenv/config";
import {
  createPublicClient,
  createWalletClient,
  http,
  defineChain,
  getAddress,
  zeroAddress,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

// ── Env helpers ────────────────────────────────────────────────────────────────

export function env(name: string, fallback?: string): string {
  const v = process.env[name] ?? fallback;
  if (v === undefined || v === "") {
    throw new Error(`Missing required env var: ${name}`);
  }
  return v;
}

function optAddr(name: string): Address {
  const v = process.env[name];
  return v && v !== "" ? getAddress(v) : zeroAddress;
}

export const RPC_URL = env("RPC_URL", "https://sepolia.unichain.org");
export const CHAIN_ID = Number(env("CHAIN_ID", "1301"));

export const REGISTRY_ADDRESS = optAddr("REGISTRY_ADDRESS");
export const HOOK_ADDRESS = optAddr("HOOK_ADDRESS");
export const SWAP_ROUTER_ADDRESS = optAddr("SWAP_ROUTER_ADDRESS");

// ── Chain + clients ─────────────────────────────────────────────────────────────

export const unichainSepolia = defineChain({
  id: CHAIN_ID,
  name: "Unichain Sepolia",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [RPC_URL] } },
});

export const publicClient = createPublicClient({
  chain: unichainSepolia,
  transport: http(RPC_URL),
});

export function walletFor(privKeyEnv: string) {
  const pk = env(privKeyEnv) as Hex;
  const account = privateKeyToAccount(pk);
  const client = createWalletClient({
    account,
    chain: unichainSepolia,
    transport: http(RPC_URL),
  });
  return { account, client };
}

// ── ABIs ─────────────────────────────────────────────────────────────────────

export const registryAbi = [
  {
    type: "function",
    name: "scoreOf",
    stateMutability: "view",
    inputs: [{ name: "wallet", type: "address" }],
    outputs: [{ name: "", type: "uint16" }],
  },
  {
    type: "function",
    name: "scoreDataOf",
    stateMutability: "view",
    inputs: [{ name: "wallet", type: "address" }],
    outputs: [
      {
        name: "",
        type: "tuple",
        components: [
          { name: "value", type: "uint16" },
          { name: "updatedAt", type: "uint64" },
          { name: "nonce", type: "uint32" },
        ],
      },
    ],
  },
] as const;

// v4 PoolSwapTest.swap(PoolKey, SwapParams, TestSettings, hookData)
export const swapRouterAbi = [
  {
    type: "function",
    name: "swap",
    stateMutability: "payable",
    inputs: [
      {
        name: "key",
        type: "tuple",
        components: [
          { name: "currency0", type: "address" },
          { name: "currency1", type: "address" },
          { name: "fee", type: "uint24" },
          { name: "tickSpacing", type: "int24" },
          { name: "hooks", type: "address" },
        ],
      },
      {
        name: "params",
        type: "tuple",
        components: [
          { name: "zeroForOne", type: "bool" },
          { name: "amountSpecified", type: "int256" },
          { name: "sqrtPriceLimitX96", type: "uint160" },
        ],
      },
      {
        name: "testSettings",
        type: "tuple",
        components: [
          { name: "takeClaims", type: "bool" },
          { name: "settleUsingBurn", type: "bool" },
        ],
      },
      { name: "hookData", type: "bytes" },
    ],
    outputs: [{ name: "delta", type: "int256" }],
  },
] as const;

export const erc20Abi = [
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    type: "function",
    name: "allowance",
    stateMutability: "view",
    inputs: [
      { name: "owner", type: "address" },
      { name: "spender", type: "address" },
    ],
    outputs: [{ name: "", type: "uint256" }],
  },
] as const;

// ── v4 constants ───────────────────────────────────────────────────────────────

// LPFeeLibrary.DYNAMIC_FEE_FLAG — pools using a dynamic-fee hook carry this as their fee.
export const DYNAMIC_FEE_FLAG = 0x800000;

// TickMath sqrt-price bounds; we use (MIN+1) / (MAX-1) as effectively-unbounded limits.
export const MIN_SQRT_PRICE_PLUS_ONE = 4295128740n;
export const MAX_SQRT_PRICE_MINUS_ONE =
  1461446703485210103287273052203988822378723970341n;

export type PoolKey = {
  currency0: Address;
  currency1: Address;
  fee: number;
  tickSpacing: number;
  hooks: Address;
};

export function poolKeyFromEnv(): PoolKey {
  const c0 = optAddr("CURRENCY0");
  const c1 = optAddr("CURRENCY1");
  // v4 requires currency0 < currency1.
  const [currency0, currency1] =
    BigInt(c0) <= BigInt(c1) ? [c0, c1] : [c1, c0];
  return {
    currency0,
    currency1,
    fee: DYNAMIC_FEE_FLAG,
    tickSpacing: Number(env("TICK_SPACING", "60")),
    hooks: HOOK_ADDRESS,
  };
}

// ── Fee curve (mirror of ToxicityScoring.scoreToFee / frontend format.ts) ────────

export function scoreToFeeUnits(score: number): number {
  if (score <= 0) return 3_000;
  if (score >= 10_000) return 100_000;
  if (score < 2_500) return Math.round(3_000 + (score * 7_000) / 2_500);
  if (score < 7_500) return Math.round(10_000 + ((score - 2_500) * 30_000) / 5_000);
  return Math.round(40_000 + ((score - 7_500) * 60_000) / 2_500);
}

export function feePct(score: number): string {
  return (scoreToFeeUnits(score) / 10_000).toFixed(3) + "%";
}

// ── Reads ──────────────────────────────────────────────────────────────────────

export async function readScore(wallet: Address): Promise<number> {
  if (REGISTRY_ADDRESS === zeroAddress) return 0;
  try {
    const score = await publicClient.readContract({
      address: REGISTRY_ADDRESS,
      abi: registryAbi,
      functionName: "scoreOf",
      args: [wallet],
    });
    return Number(score);
  } catch {
    return 0;
  }
}

export function logScore(label: string, score: number): void {
  const bar = "█".repeat(Math.round(score / 250)).padEnd(40, "░");
  console.log(
    `  ${label.padEnd(10)} score ${String(score).padStart(5)}/10000  ${bar}  fee ${feePct(score)}`,
  );
}

// ── Swap ─────────────────────────────────────────────────────────────────────────

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
export { sleep };

// The public Unichain Sepolia RPC is load-balanced across nodes whose pending-nonce
// views lag each other, so letting viem fetch the nonce per-tx intermittently fails
// with "nonce too low". Track nonces locally: seed from the freshest chain view, then
// increment per send.
const nonces = new Map<Address, number>();

async function nonceFor(address: Address): Promise<number> {
  const [latest, pending] = await Promise.all([
    publicClient.getTransactionCount({ address, blockTag: "latest" }),
    publicClient.getTransactionCount({ address, blockTag: "pending" }),
  ]);
  const next = Math.max(latest, pending, nonces.get(address) ?? 0);
  nonces.set(address, next + 1);
  return next;
}

/**
 * Send one exact-input swap through the PoolSwapTest router and wait for the receipt.
 * `zeroForOne` direction alternates per call so the demo stays roughly balanced.
 */
export async function doSwap(opts: {
  client: ReturnType<typeof walletFor>["client"];
  account: ReturnType<typeof walletFor>["account"];
  key: PoolKey;
  zeroForOne: boolean;
  amount: bigint;
}): Promise<Hex> {
  const { client, account, key, zeroForOne, amount } = opts;

  const params = {
    zeroForOne,
    amountSpecified: -amount, // negative = exact input
    sqrtPriceLimitX96: zeroForOne
      ? MIN_SQRT_PRICE_PLUS_ONE
      : MAX_SQRT_PRICE_MINUS_ONE,
  } as const;

  const testSettings = { takeClaims: false, settleUsingBurn: false } as const;

  // Native ETH (currency0 == 0) is sent as msg.value; ERC20s must be pre-approved.
  const value =
    key.currency0 === zeroAddress && zeroForOne ? amount : 0n;

  const hash = await client.writeContract({
    account,
    address: SWAP_ROUTER_ADDRESS,
    abi: swapRouterAbi,
    functionName: "swap",
    args: [key, params, testSettings, "0x"],
    value,
    nonce: await nonceFor(account.address),
  });
  await publicClient.waitForTransactionReceipt({ hash });
  return hash;
}

/** Ensure the swap router can pull both ERC20 currencies from `account`. */
export async function ensureApprovals(
  client: ReturnType<typeof walletFor>["client"],
  account: ReturnType<typeof walletFor>["account"],
  key: PoolKey,
): Promise<void> {
  const MAX = (1n << 256n) - 1n;
  for (const currency of [key.currency0, key.currency1]) {
    if (currency === zeroAddress) continue; // native ETH needs no approval
    const allowance = await publicClient.readContract({
      address: currency,
      abi: erc20Abi,
      functionName: "allowance",
      args: [account.address, SWAP_ROUTER_ADDRESS],
    });
    if (allowance < MAX / 2n) {
      const hash = await client.writeContract({
        account,
        address: currency,
        abi: erc20Abi,
        functionName: "approve",
        args: [SWAP_ROUTER_ADDRESS, MAX],
        nonce: await nonceFor(account.address),
      });
      await publicClient.waitForTransactionReceipt({ hash });
      console.log(`  approved ${currency} → router`);
    }
  }
}

export function preflight(): { ready: boolean; reason?: string } {
  if (REGISTRY_ADDRESS === zeroAddress)
    return { ready: false, reason: "REGISTRY_ADDRESS not set" };
  if (SWAP_ROUTER_ADDRESS === zeroAddress)
    return { ready: false, reason: "SWAP_ROUTER_ADDRESS not set" };
  if (HOOK_ADDRESS === zeroAddress)
    return { ready: false, reason: "HOOK_ADDRESS not set" };
  return { ready: true };
}
