// Contract addresses and ABIs for Glyph on Unichain Sepolia.
// TODO: populate addresses after deployment (Day 4).
// TODO: import ABIs from contract/out/ after forge build.

export const CONTRACTS = {
  registry: {
    address: "" as `0x${string}`,
    // abi: ReputationRegistryABI,
  },
  hook: {
    address: "" as `0x${string}`,
    // abi: GlyphHookABI,
  },
} as const;

export const UNICHAIN_SEPOLIA_CHAIN_ID = 1301;
