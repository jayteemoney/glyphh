install:
	forge install uniswap/v4-core uniswap/v4-periphery OpenZeppelin/openzeppelin-contracts foundry-rs/forge-std --no-git
	npm install @pythnetwork/pyth-sdk-solidity

build:
	forge build

test:
	forge test -vv

test-fuzz:
	forge test --fuzz-runs 10000 -vv

snapshot:
	forge snapshot

coverage:
	forge coverage --report summary

deploy-testnet:
	forge script script/DeployGlyph.s.sol \
		--rpc-url unichain_sepolia \
		--broadcast \
		--verify \
		-vvv

.PHONY: install build test test-fuzz snapshot coverage deploy-testnet
