const { ethers } = require("hardhat");
const { run } = require("hardhat");
const hre = require("hardhat");
require("dotenv").config();

async function main() {
  // Get network from Hardhat's network configuration
  const network = hre.network.name || "baseSepolia";
  
  if (!["base", "baseSepolia"].includes(network)) {
    throw new Error("Invalid network. Use 'base' or 'baseSepolia'");
  }
  
  console.log(`🚀 Starting deployment on ${network}...`);
  
  // Check for private key in environment
  if (!process.env.PRIVATE_KEY) {
    throw new Error("PRIVATE_KEY not found in environment variables");
  }
  
  // Create wallet from private key
  const wallet = new ethers.Wallet(process.env.PRIVATE_KEY);
  console.log("Deploying with account:", wallet.address);
  
  // Set up network configuration
  let rpcUrl, chainId, networkName, etherscanApiKey, blockExplorer;
  
  if (network === "base") {
    rpcUrl = process.env.BASE_RPC_URL || "https://base.drpc.org";
    chainId = 8453;
    networkName = "Base Mainnet";
    etherscanApiKey = process.env.ETHERSCAN_API_KEY;
    blockExplorer = "https://basescan.org";
  } else {
    rpcUrl = process.env.BASE_SEPOLIA_RPC_URL || "https://sepolia.base.org";
    chainId = 84532;
    networkName = "Base Sepolia";
    etherscanApiKey = process.env.ETHERSCAN_API_KEY;
    blockExplorer = "https://sepolia.basescan.org";
  }
  
  console.log(`Network: ${networkName} (Chain ID: ${chainId})`);
  
  // Connect to network
  const provider = new ethers.JsonRpcProvider(rpcUrl);
  const deployer = wallet.connect(provider);
  
  // Check balance
  const balance = await provider.getBalance(deployer.address);
  console.log("Account balance:", ethers.formatEther(balance), "ETH");
  
  if (balance === 0n) {
    throw new Error("Account has no ETH balance. Please fund the account first.");
  }
  
  console.log("✅ Account funded, proceeding with deployment...");
  
  // ===== STEP 1: DEPLOY REGULAR CONTRACT =====
  console.log("\n📦 Step 1: Deploying LightV2 contract...");
  
  const LightV2 = await ethers.getContractFactory("LightV2", deployer);
  console.log("✅ Contract factory loaded");
  
  // Constructor parameters
  const constructorArgs = [
    deployer.address, // _treasury (deployer is the treasury)
  ];
  
  console.log("Constructor arguments:");
  console.log("  Treasury:", constructorArgs[0]);
  
  let lightV2;
  let retryCount = 0;
  const maxRetries = 3;
  
  while (retryCount < maxRetries) {
    try {
      console.log("⏳ Submitting deployment transaction...");
      
      // Get current gas price
      const feeData = await provider.getFeeData();
      console.log("Current gas price:", ethers.formatUnits(feeData.gasPrice || 0, "gwei"), "gwei");
      
      // Deploy regular contract with constructor
      lightV2 = await LightV2.deploy(...constructorArgs, {
        gasPrice: feeData.gasPrice ? feeData.gasPrice * 120n / 100n : undefined, // 20% higher gas price
      });
      
      console.log("✅ Transaction submitted!");
      
      // Get transaction details
      const deploymentTx = lightV2.deploymentTransaction();
      if (deploymentTx) {
        console.log("Transaction hash:", deploymentTx.hash);
        console.log(`View on BlockExplorer: ${blockExplorer}/tx/${deploymentTx.hash}`);
      }
      
      // Wait for deployment
      console.log("⏳ Waiting for deployment confirmation...");
      await lightV2.waitForDeployment();
      
      // Get the contract address
      const contractAddress = await lightV2.getAddress();
      console.log("✅ Contract deployed to:", contractAddress);
      break; // Success, exit retry loop
      
    } catch (error) {
      retryCount++;
      console.error(`❌ Deployment attempt ${retryCount} failed:`, error.message);
      
      if (retryCount >= maxRetries) {
        throw new Error(`Deployment failed after ${maxRetries} attempts. Last error: ${error.message}`);
      }
      
      console.log(`⏳ Retrying deployment in 10 seconds... (Attempt ${retryCount + 1}/${maxRetries})`);
      await new Promise(resolve => setTimeout(resolve, 10000));
    }
  }
  
  // ===== STEP 2: GET CONTRACT ADDRESS =====
  console.log("\n📍 Step 2: Getting contract address...");
  const contractAddress = await lightV2.getAddress();
  console.log("✅ LightV2 deployed to:", contractAddress);
  
  // ===== STEP 3: GET TRANSACTION DETAILS =====
  console.log("\n🔍 Step 3: Getting transaction details...");
  const deploymentTx = lightV2.deploymentTransaction();
  if (deploymentTx) {
    console.log("Transaction hash:", deploymentTx.hash);
    console.log("Gas limit:", deploymentTx.gasLimit?.toString() || "N/A");
    console.log("Gas price:", ethers.formatUnits(deploymentTx.gasPrice || 0, "gwei"), "gwei");
    
    // Wait for transaction confirmation
    console.log("⏳ Waiting for transaction confirmation...");
    const receipt = await deploymentTx.wait();
    console.log("✅ Transaction confirmed in block:", receipt?.blockNumber || "N/A");
    console.log("Gas used:", receipt?.gasUsed?.toString() || "N/A");
    console.log("Transaction fee:", ethers.formatEther((receipt?.gasUsed || 0n) * (receipt?.gasPrice || 0n)), "ETH");
  }
  
  // ===== STEP 4: BASIC CONTRACT VERIFICATION =====
  console.log("\n🔍 Step 4: Basic contract verification...");
  
  try {
    // Test basic contract functions
    const owner = await lightV2.owner();
    console.log("✅ Contract owner:", owner);
    
    const treasury = await lightV2.treasury();
    console.log("✅ Treasury address:", treasury);
    
    // Check if ETH is supported by default
    const ethSupported = await lightV2.supportedTokens(ethers.ZeroAddress);
    console.log("✅ ETH supported:", ethSupported);
    
    // Check admin status
    const isActiveAdmin = await lightV2.isActiveAdmin(owner);
    console.log("✅ Owner is active admin:", isActiveAdmin);
    
    // Check pending orders count
    const pendingCount = await lightV2.getPendingOrdersCount();
    console.log("✅ Pending orders count:", pendingCount.toString());
    
    // Check minimum refund time
    const MIN_REFUND_TIME = 2 * 60 * 60; // 2 hours in seconds
    console.log("✅ Min refund time:", MIN_REFUND_TIME, "seconds (2 hours)");
    
    console.log("✅ Basic contract verification passed!");
    
  } catch (error) {
    console.error("❌ Basic contract verification failed:", error.message);
    throw error;
  }
  
  // ===== STEP 5: ETHERSCAN VERIFICATION =====
  console.log("\n🔐 Step 5: Verifying contract on Etherscan...");
  
  if (!etherscanApiKey) {
    console.log("⚠️  No Etherscan API key found, skipping verification");
    console.log("To verify later, run:");
    console.log(`npx hardhat verify --network ${network} ${contractAddress} "${constructorArgs[0]}"`);
  } else {
    try {
      console.log("⏳ Verifying contract on Etherscan...");
      
      // Wait a bit for Etherscan to index the contract
      console.log("⏳ Waiting 30 seconds for Etherscan to index...");
      await new Promise(resolve => setTimeout(resolve, 30000));
      
      // Verify the contract with constructor arguments
      await run("verify:verify", {
        address: contractAddress,
        constructorArguments: constructorArgs,
      });
      console.log("✅ Contract verified successfully!");
    } catch (error) {
      console.error("❌ Verification failed:", error.message);
      console.log("You can verify manually later using:");
      console.log(`npx hardhat verify --network ${network} ${contractAddress} "${constructorArgs[0]}"`);
    }
  }
  
  // ===== STEP 6: FINAL SUMMARY =====
  console.log("\n🎉 DEPLOYMENT COMPLETE!");
  console.log("=====================================");
  console.log(`Network: ${networkName}`);
  console.log(`Contract Address: ${contractAddress}`);
  console.log(`Block Explorer: ${blockExplorer}/address/${contractAddress}`);
  console.log(`Deployer: ${deployer.address}`);
  console.log(`Treasury: ${constructorArgs[0]}`);
  console.log("=====================================");
  
  // ===== STEP 7: USAGE EXAMPLES =====
  console.log("\n📡 Usage Examples:");
  
  // Contract interaction example
  console.log("\n1. Contract interaction via ethers.js:");
  console.log(`const contract = new ethers.Contract("${contractAddress}", abi, signer);`);
  console.log(`const owner = await contract.owner();`);
  console.log(`const pendingOrders = await contract.getPendingOrderIds();`);
  console.log(`const userOrders = await contract.getUserOrders(userAddress);`);
  
  // Order creation example
  console.log("\n2. Create a buy order:");
  console.log(`const orderMetadata = JSON.stringify({`);
  console.log(`  serviceType: "offramp",`);
  console.log(`  paymentMethod: "MTN_MOMO",`);
  console.log(`  phoneNumber: "+256123456789",`);
  console.log(`  recipientName: "John Doe"`);
  console.log(`});`);
  console.log(`const tx = await contract.createBuyOrder(`);
  console.log(`  ethers.ZeroAddress, // ETH`);
  console.log(`  ethers.parseEther("0.01"), // 0.01 ETH`);
  console.log(`  "UGX", // Target currency`);
  console.log(`  "100000", // 100,000 UGX`);
  console.log(`  orderMetadata,`);
  console.log(`  { value: ethers.parseEther("0.01") }`);
  console.log(`);`);
  
  // Admin functions
  console.log("\n3. Admin functions:");
  console.log(`// Fill an order (after sending fiat to user)`);
  console.log(`await contract.fillOrder(orderId, "Sent 100,000 UGX via MTN Mobile Money");`);
  console.log(`// Refund an order`);
  console.log(`await contract.refundOrder(orderId, "Unable to process payment");`);
  
  // API call examples
  console.log("\n4. Direct RPC calls:");
  console.log("Get contract owner:");
  console.log(`curl -X POST ${rpcUrl} \\`);
  console.log(`  -H "Content-Type: application/json" \\`);
  console.log(`  -d '{"jsonrpc": "2.0", "method": "eth_call", "params": [{"to": "${contractAddress}", "data": "0x8da5cb5b"}, "latest"], "id": 1}'`);
  
  console.log("\nGet pending orders count:");
  console.log(`curl -X POST ${rpcUrl} \\`);
  console.log(`  -H "Content-Type: application/json" \\`);
  console.log(`  -d '{"jsonrpc": "2.0", "method": "eth_call", "params": [{"to": "${contractAddress}", "data": "0x925feaae"}, "latest"], "id": 1}'`);
  
  // Next steps
  console.log("\n📋 Next Steps:");
  console.log("1. Add supported tokens using setSupportedToken()");
  console.log("   Example: await contract.setSupportedToken('0xUSDTAddress', true)");
  console.log("2. Add additional admins using addAdmin()");
  console.log("   Example: await contract.addAdmin('0xAdminAddress', 'Admin Name')");
  console.log("3. Test order creation flow with different service types");
  console.log("4. Test admin order filling and refunding");
  console.log("5. Update treasury address if needed using updateTreasury()");
  
  // Example service types
  console.log("\n🛍️ Example Service Types in Order Metadata:");
  
  console.log("\n• Off-ramp (Mobile Money):");
  console.log(`{`);
  console.log(`  "serviceType": "offramp",`);
  console.log(`  "paymentMethod": "MTN_MOMO",`);
  console.log(`  "phoneNumber": "+256123456789",`);
  console.log(`  "recipientName": "John Doe"`);
  console.log(`}`);
  
  console.log("\n• Utility Payment:");
  console.log(`{`);
  console.log(`  "serviceType": "utility",`);
  console.log(`  "utilityType": "electricity",`);
  console.log(`  "accountNumber": "12345678",`);
  console.log(`  "providerName": "UMEME"`);
  console.log(`}`);
  
  console.log("\n• Send to Someone:");
  console.log(`{`);
  console.log(`  "serviceType": "transfer",`);
  console.log(`  "paymentMethod": "BANK_TRANSFER",`);
  console.log(`  "recipientName": "Jane Smith",`);
  console.log(`  "bankAccount": "1234567890",`);
  console.log(`  "bankName": "Stanbic Bank"`);
  console.log(`}`);
  
  console.log("\n• Airtime Purchase:");
  console.log(`{`);
  console.log(`  "serviceType": "airtime",`);
  console.log(`  "phoneNumber": "+256987654321",`);
  console.log(`  "network": "MTN",`);
  console.log(`  "amount": 10000`);
  console.log(`}`);
  
  // Save deployment info
  const deploymentInfo = {
    network: networkName,
    chainId: chainId,
    contractAddress: contractAddress,
    blockExplorer: `${blockExplorer}/address/${contractAddress}`,
    deployer: deployer.address,
    treasury: constructorArgs[0],
    deploymentTime: new Date().toISOString(),
    transactionHash: deploymentTx?.hash,
    constructorArguments: constructorArgs,
    contractType: "LightV2",
    isUpgradeable: false,
    minRefundTimeHours: 2,
    features: [
      "Buy orders with crypto escrow",
      "Flexible JSON metadata for service types",
      "Editable metadata until order filled",
      "2-hour minimum refund time",
      "Admin order filling and refunding",
      "Multi-service support (offramp, utilities, transfers, airtime)",
      "ETH and ERC20 token support"
    ]
  };
  
  console.log("\n💾 Deployment Info (save this):");
  console.log(JSON.stringify(deploymentInfo, null, 2));
  
  // Write deployment info to file
  const fs = require('fs');
  const deploymentFile = `deployments/${network}-lightv2-${Date.now()}.json`;
  
  try {
    // Create deployments directory if it doesn't exist
    if (!fs.existsSync('deployments')) {
      fs.mkdirSync('deployments');
    }
    
    fs.writeFileSync(deploymentFile, JSON.stringify(deploymentInfo, null, 2));
    console.log(`\n📁 Deployment info saved to: ${deploymentFile}`);
  } catch (error) {
    console.log("\n⚠️  Could not save deployment file:", error.message);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });