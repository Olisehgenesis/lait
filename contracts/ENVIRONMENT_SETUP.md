# Environment Setup

To use this project, you need to create a `.env` file in the root directory with the following variables:

## Required Environment Variables

```bash
# RPC URLs
RPC_URL=https://mainnet.base.org
SEPOLIA_RPC_URL=https://sepolia.base.org

# Private Keys (for deployment - keep secure!)
PRIVATE_KEY=your_private_key_here
SEPOLIA_PRIVATE_KEY=your_sepolia_private_key_here

# Etherscan API Key (for contract verification - works for both Etherscan and Basescan)
ETHERSCAN_API_KEY=your_etherscan_api_key_here

# WalletConnect
WALLETCONNECT_PROJECT_ID=d14e06d5b6397bc594e038b7c05f62da
```

## Getting API Keys

### Etherscan API Key
1. Go to [Etherscan.io](https://etherscan.io/)
2. Create an account or log in
3. Go to API Keys section
4. Create a new API key
5. Copy the API key and use it for `ETHERSCAN_API_KEY` (works for both Etherscan and Basescan)

### Base RPC URL
- Mainnet: `https://mainnet.base.org`
- Testnet: `https://sepolia.base.org`

## Usage

1. Copy this file to `.env` in the project root
2. Fill in your actual values
3. Never commit the `.env` file to version control

## Verification

After setting up the environment variables, you can verify contracts using:

```bash
pnpm verify
```

