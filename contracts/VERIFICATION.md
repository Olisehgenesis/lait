# Contract Verification Guide

This guide explains how to verify your smart contracts on Base network using Hardhat.

## Prerequisites

1. **API Key**: You need a BaseScan API key
   - Go to [BaseScan](https://basescan.org/apis)
   - Sign up and create an API key
   - Set it as an environment variable: `export ETHERSCAN_API_KEY=your_api_key_here`

2. **Deployed Contracts**: Make sure you have deployed contracts in the `deployments/base/` directory

## Available Verification Scripts

### 1. Simple Verification (`pnpm verify`)
- **File**: `scripts/verify-simple.ts`
- **Usage**: `pnpm verify`
- **Description**: Simple, sequential verification of all deployed contracts
- **Best for**: Quick verification of a few contracts

### 2. Advanced Verification (`pnpm verify:advanced`)
- **File**: `scripts/verify-contracts-base.ts`
- **Usage**: `pnpm verify:advanced`
- **Description**: Advanced verification with retry logic, parallel processing, and error handling
- **Best for**: Verifying many contracts or dealing with rate limits

## How to Use

### Step 1: Set up your environment
```bash
# Set your BaseScan API key
export ETHERSCAN_API_KEY=your_api_key_here

# Or add it to your .env file
echo "ETHERSCAN_API_KEY=your_api_key_here" >> .env
```

### Step 2: Run verification
```bash
# Simple verification (recommended for most cases)
pnpm verify

# Advanced verification (for complex scenarios)
pnpm verify:advanced
```

### Step 3: Check results
- Successful verifications will show BaseScan links
- Failed verifications will show error details
- Already verified contracts will be detected automatically

## Understanding the Output

### Success Messages
- ✅ `Verification successful!` - Contract verified successfully
- ✅ `Already verified` - Contract was already verified
- 🔗 `View on BaseScan` - Link to view the verified contract

### Error Messages
- ❌ `Verification failed` - Check error details for specific issues
- ⚠️ `Rate limited` - Wait and retry (advanced script handles this automatically)
- 🌐 `Network error` - Temporary network issue (advanced script retries automatically)

## Troubleshooting

### Common Issues

1. **"Contract source code already verified"**
   - This is normal - the contract is already verified
   - The script will detect this and show success

2. **"Rate limit exceeded"**
   - BaseScan has rate limits
   - Use the advanced script which handles retries automatically
   - Or wait a few minutes and try again

3. **"Bytecode mismatch"**
   - The deployed bytecode doesn't match the source code
   - Check if you're using the correct compiler settings
   - Ensure the contract hasn't been modified since deployment

4. **"Constructor arguments"**
   - Some contracts need constructor arguments for verification
   - Check the deployment script for the correct arguments
   - Add them to the verification command if needed

### Manual Verification

If the scripts don't work, you can verify manually:

```bash
# Basic verification
npx hardhat verify --network base CONTRACT_ADDRESS

# With constructor arguments
npx hardhat verify --network base CONTRACT_ADDRESS "arg1" "arg2"
```

## Configuration

The verification uses your `hardhat.config.ts` configuration:

- **Network**: `base` (Base mainnet)
- **API Key**: From `ETHERSCAN_API_KEY` environment variable
- **Explorer**: BaseScan (https://basescan.org)

## File Structure

```
contracts/
├── scripts/
│   ├── verify-simple.ts          # Simple verification
│   ├── verify-contracts-base.ts  # Advanced verification
│   └── utils/
│       └── deployments.ts        # Deployment utilities
├── deployments/
│   └── base/
│       ├── LightV1Beta.json      # Deployment data
│       └── laitUSDC.json         # Deployment data
└── hardhat.config.ts             # Hardhat configuration
```

## Best Practices

1. **Always verify contracts** - It's essential for transparency and trust
2. **Use the simple script first** - It's easier to debug issues
3. **Check BaseScan after verification** - Ensure the contract is properly verified
4. **Keep deployment data** - The JSON files in `deployments/` are needed for verification
5. **Test on testnet first** - Verify on Base Sepolia before mainnet

## Support

If you encounter issues:

1. Check the error messages carefully
2. Verify your API key is correct
3. Ensure the contract is deployed and has bytecode
4. Check BaseScan directly to see if the contract is already verified
5. Review the Hardhat documentation for verification troubleshooting
