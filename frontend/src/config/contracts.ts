// Glyph v2 contract addresses + the minimal ABIs the dashboard consumes.
// Addresses come from env so the same build works across deployments; fill them in
// frontend/.env.local after `forge script DeployGlyph` (see .env.example).

export const UNICHAIN_SEPOLIA_CHAIN_ID = 1301;

export const REGISTRY_ADDRESS = (process.env.NEXT_PUBLIC_REGISTRY_ADDRESS ?? "") as `0x${string}` | "";
export const HOOK_ADDRESS = (process.env.NEXT_PUBLIC_HOOK_ADDRESS ?? "") as `0x${string}` | "";
export const VAULT_ADDRESS = (process.env.NEXT_PUBLIC_VAULT_ADDRESS ?? "") as `0x${string}` | "";
export const ORACLE_ADDRESS = (process.env.NEXT_PUBLIC_ORACLE_ADDRESS ?? "") as `0x${string}` | "";

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
    name: "TrustUpdated",
    inputs: [
      { name: "wallet", type: "address", indexed: true },
      { name: "value", type: "uint16", indexed: false },
      { name: "nonce", type: "uint32", indexed: false },
    ],
  },
  // v2: keyed on the real PoolId, so the dashboard can count *distinct* pools rather
  // than repeat offences in one. v1 passed the hook's own address here.
  {
    type: "event",
    name: "ToxicSwapReported",
    inputs: [
      { name: "wallet", type: "address", indexed: true },
      { name: "poolId", type: "bytes32", indexed: true },
      { name: "severity", type: "uint16", indexed: false },
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
    name: "trustOf",
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
  // The centrepiece of the v2 dashboard. The hook emits every term of the quoted fee
  // separately, so the UI can show *why* a swap was priced the way it was rather than
  // just what it cost. A fee a trader cannot account for is indistinguishable from an
  // arbitrary one.
  {
    type: "event",
    name: "FeeQuoted",
    inputs: [
      { name: "poolId", type: "bytes32", indexed: true },
      { name: "swapper", type: "address", indexed: true },
      { name: "baseFee", type: "uint24", indexed: false },
      { name: "arbPremium", type: "uint24", indexed: false },
      { name: "unprovenPremium", type: "uint24", indexed: false },
      { name: "toxicPremium", type: "uint24", indexed: false },
      { name: "trustDiscount", type: "uint24", indexed: false },
      { name: "finalFee", type: "uint24", indexed: false },
    ],
  },
  {
    type: "event",
    name: "SandwichDetected",
    inputs: [
      { name: "poolId", type: "bytes32", indexed: true },
      { name: "attacker", type: "address", indexed: true },
      { name: "victim", type: "address", indexed: true },
      { name: "currency", type: "address", indexed: false },
      { name: "rebate", type: "uint256", indexed: false },
    ],
  },
] as const;

export const vaultAbi = [
  {
    type: "function",
    name: "claimable",
    stateMutability: "view",
    inputs: [
      { name: "victim", type: "address" },
      { name: "currency", type: "address" },
    ],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "claim",
    stateMutability: "nonpayable",
    inputs: [{ name: "currency", type: "address" }],
    outputs: [{ name: "amount", type: "uint256" }],
  },
  {
    type: "event",
    name: "RebateCredited",
    inputs: [
      { name: "victim", type: "address", indexed: true },
      { name: "currency", type: "address", indexed: true },
      { name: "amount", type: "uint256", indexed: false },
      { name: "hook", type: "address", indexed: true },
    ],
  },
  {
    type: "event",
    name: "RebateClaimed",
    inputs: [
      { name: "victim", type: "address", indexed: true },
      { name: "currency", type: "address", indexed: true },
      { name: "amount", type: "uint256", indexed: false },
    ],
  },
] as const;
