# GhostLend

A basic borrowing and lending protocol built on Foundry with Chainlink price feeds and [BattleChain](https://docs.battlechain.com/) integration.

## Overview

GhostLend allows users to deposit ERC20 tokens (WETH, USDC) as collateral and borrow against them. All positions must maintain a **200% minimum collateralization ratio**. Positions that fall below 200% are liquidatable, with liquidators receiving a 10% bonus on seized collateral.

## Architecture

```
src/
├── GhostLend.sol              # Core lending protocol
├── libraries/
│   └── OracleLib.sol          # Chainlink price feed helper
└── utils/
    └── ReentrancyGuard.sol    # Transient storage reentrancy guard

script/
├── DeployGhostLend.s.sol      # BattleChain-aware deploy script
└── HelperConfig.s.sol         # Per-network configuration

test/
├── GhostLend.t.sol            # Protocol test suite
└── mocks/
    ├── MockERC20.sol           # Mintable ERC20 for testing
    └── MockV3Aggregator.sol    # Mock Chainlink price feed
```

## How It Works

1. **Deposit** — Users deposit WETH or USDC as collateral
2. **Borrow** — Users borrow any supported token, provided their total collateral value (USD) is at least 2x their total borrow value (USD)
3. **Repay** — Users repay outstanding debt
4. **Withdraw** — Users withdraw collateral, as long as the 200% ratio holds
5. **Liquidate** — Anyone can repay an undercollateralized user's debt and receive 110% of that value in the user's collateral

## Getting Started

```bash
# Install dependencies
forge install

# Build
forge build

# Test
forge test
```

## Deploy

Uses [battlechain-lib](https://github.com/cyfrin/battlechain-lib) for cross-chain deployment via CreateX and BattleChain Safe Harbor agreements.

```bash
# Local (Anvil)
forge script script/DeployGhostLend.s.sol --broadcast --skip-simulation

# BattleChain Testnet
forge script script/DeployGhostLend.s.sol \
  --rpc-url https://testnet.battlechain.com \
  --account $ACCOUNT --sender $SENDER \
  --broadcast --skip-simulation --legacy -g 300
```

## Dependencies

- [OpenZeppelin Contracts v5](https://github.com/OpenZeppelin/openzeppelin-contracts) — SafeERC20, IERC20
- [Chainlink EVM](https://github.com/smartcontractkit/chainlink-evm) — AggregatorV3Interface
- [battlechain-lib](https://github.com/cyfrin/battlechain-lib) — BCScript, CreateX deploys, Safe Harbor
- [forge-std](https://github.com/foundry-rs/forge-std) — Testing framework
