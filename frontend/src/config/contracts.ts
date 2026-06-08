// Glyph contract addresses + the minimal ABIs the dashboard consumes.
// Addresses come from env so the same build works across deployments; fill them in
// frontend/.env.local after `forge script DeployGlyph` (see .env.example).

export const UNICHAIN_SEPOLIA_CHAIN_ID = 1301;

export const REGISTRY_ADDRESS = (process.env.NEXT_PUBLIC_REGISTRY_ADDRESS ?? "") as `0x${string}` | "";
export const HOOK_ADDRESS = (process.env.NEXT_PUBLIC_HOOK_ADDRESS ?? "") as `0x${string}` | "";

export const registryAbi = [
  {
    type: "event",
    name: "ScoreUpdated",
    inputs: [
      { name: "wallet", type: "address", indexed: true },
      { name: "value", type: "uint16", indexed: false },
      { name: "nonce", type: "uint32", indexed: false },
    ],
  },
  {
    type: "event",
    name: "ToxicTradeReported",
    inputs: [
      { name: "wallet", type: "address", indexed: true },
      { name: "pool", type: "address", indexed: true },
      { name: "localSeverity", type: "uint16", indexed: false },
      { name: "timestamp", type: "uint256", indexed: false },
    ],
  },
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

export const hookAbi = [
  {
    type: "event",
    name: "LPDonation",
    inputs: [
      { name: "poolId", type: "bytes32", indexed: true },
      { name: "amount0", type: "uint256", indexed: false },
      { name: "amount1", type: "uint256", indexed: false },
    ],
  },
] as const;
