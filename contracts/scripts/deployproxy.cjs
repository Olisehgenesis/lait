const { ethers, upgrades } = require("hardhat");
const { run } = require("hardhat");
const hre = require("hardhat");
require("dotenv").config();

async function main() {
  // Get network from Hardhat's network configuration
  const network = hre.network.name || "baseSepolia";
  
  if (!["base", "baseSepolia"].includes(network)) {
    throw new Error("Invalid network. Use 'base' or 'baseSepolia'");
  }
  
  console.log(`🚀 Starting UUPS Proxy deployment on ${network}...`);
  
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
  
  // Resolve signer/provider. Prefer Hardhat signer; fallback to PRIVATE_KEY
  let provider = ethers.provider;
  let deployer;
  let signers;
  try {
    signers = await ethers.getSigners();
  } catch (_) {
    signers = [];
  }
  if (signers && signers.length > 0) {
    deployer = signers[0];
  } else {
    const pk = process.env.PRIVATE_KEY;
    if (!pk) {
      throw new Error("No Hardhat signer and PRIVATE_KEY missing. Configure one of them.");
    }
    provider = new ethers.JsonRpcProvider(rpcUrl);
    deployer = new ethers.Wallet(pk, provider);
  }
  console.log("Deploying with account:", deployer.address);
  
  // Check balance
  const balance = await provider.getBalance(deployer.address);
  console.log("Account balance:", ethers.formatEther(balance), "ETH");
  
  if (balance === 0n) {
    throw new Error("Account has no ETH balance. Please fund the account first.");
  }
  
  console.log("✅ Account funded, proceeding with deployment...");
  
  // ===== STEP 1: DEPLOY IMPLEMENTATION CONTRACT =====
  console.log("\n📦 Step 1: Deploying LaitV2 Implementation contract...");
  
  const LaitV2 = await ethers.getContractFactory("LaitV2", deployer);
  console.log("✅ Contract factory loaded");
  
  // Initialize parameters for the proxy
  const treasuryAddress = deployer.address; // Treasury is deployer initially
  
  console.log("Initialize parameters:");
  console.log("  Treasury:", treasuryAddress);
  
  let proxyContract;
  let implementationAddress;
  let retryCount = 0;
  const maxRetries = 3;
  
  while (retryCount < maxRetries) {
    try {
      console.log("⏳ Deploying UUPS Proxy with Implementation...");
      
      // Log current gas price (bestEffort)
      const feeData = await provider.getFeeData();
      console.log("Current gas price:", ethers.formatUnits(feeData.gasPrice || 0, "gwei"), "gwei");
      
      // Deploy using OpenZeppelin upgrades plugin
      // This deploys the implementation and proxy in one transaction
      proxyContract = await upgrades.deployProxy(
        LaitV2,
        [treasuryAddress],
        {
          kind: 'uups',
          initializer: 'initialize(address)'
        }
      );
      
      console.log("✅ Proxy deployment transaction submitted!");
      
      // Wait for deployment
      console.log("⏳ Waiting for deployment confirmation...");
      await proxyContract.waitForDeployment();
      
      // Get addresses
      const proxyAddress = await proxyContract.getAddress();
      implementationAddress = await upgrades.erc1967.getImplementationAddress(proxyAddress);
      
      console.log("✅ Proxy deployed to:", proxyAddress);
      console.log("✅ Implementation deployed to:", implementationAddress);
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
  
  // ===== STEP 2: GET CONTRACT ADDRESSES =====
  console.log("\n📍 Step 2: Getting contract addresses...");
  const proxyAddress = await proxyContract.getAddress();
  console.log("✅ Proxy Address:", proxyAddress);
  console.log("✅ Implementation Address:", implementationAddress);
  
  // UUPS proxies do not use a separate admin contract like Transparent proxies
  console.log("✅ Proxy Admin: N/A (UUPS)");
  
  // ===== STEP 3: GET TRANSACTION DETAILS =====
  console.log("\n🔍 Step 3: Getting transaction details...");
  const deploymentTx = proxyContract.deploymentTransaction();
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
    // Test basic contract functions through proxy
    const owner = await proxyContract.owner();
    console.log("✅ Contract owner:", owner);
    
    const treasury = await proxyContract.treasury();
    console.log("✅ Treasury address:", treasury);
    
    // Check if ETH is supported by default
    const ethSupported = await proxyContract.supportedTokens(ethers.ZeroAddress);
    console.log("✅ ETH supported:", ethSupported);
    
    // Check admin status (mapping + struct flag)
    const isAdmin = await proxyContract.isAdmin(owner);
    const ownerAdmin = await proxyContract.getAdmin(owner);
    console.log("✅ Owner admin mapping:", isAdmin);
    console.log("✅ Owner admin active flag:", ownerAdmin.isActive);
    
    // Get all admins
    const allAdmins = await proxyContract.getAllAdmins();
    console.log("✅ Total admins:", allAdmins.length);
    
    // Check pending orders count
    const pendingBuyOrders = await proxyContract.getPendingBuyOrders();
    const pendingSellOrders = await proxyContract.getPendingSellOrders();
    console.log("✅ Pending buy orders:", pendingBuyOrders.length);
    console.log("✅ Pending sell orders:", pendingSellOrders.length);
    
    console.log("✅ Basic contract verification passed!");
    
  } catch (error) {
    console.error("❌ Basic contract verification failed:", error.message);
    throw error;
  }
  
  // ===== STEP 5: ETHERSCAN VERIFICATION =====
  console.log("\n🔐 Step 5: Verifying contracts on Etherscan...");
  
  if (!etherscanApiKey) {
    console.log("⚠️  No Etherscan API key found, skipping verification");
    console.log("To verify later, run:");
    console.log(`npx hardhat verify --network ${network} ${implementationAddress}`);
    console.log(`npx hardhat verify --network ${network} ${proxyAddress}`);
  } else {
    try {
      console.log("⏳ Verifying contracts on Etherscan...");
      
      // Wait a bit for Etherscan to index the contracts
      console.log("⏳ Waiting 30 seconds for Etherscan to index...");
      await new Promise(resolve => setTimeout(resolve, 30000));
      
      // Verify implementation contract
      console.log("Verifying implementation contract...");
      await run("verify:verify", {
        address: implementationAddress,
        constructorArguments: [],
      });
      console.log("✅ Implementation contract verified!");
      
      // The proxy will be automatically verified by the upgrades plugin
      console.log("✅ Contracts verified successfully!");
      
    } catch (error) {
      console.error("❌ Verification failed:", error.message);
      console.log("You can verify manually later using:");
      console.log(`npx hardhat verify --network ${network} ${implementationAddress}`);
    }
  }
  
  // ===== STEP 6: FINAL SUMMARY =====
  console.log("\n🎉 DEPLOYMENT COMPLETE!");
  console.log("=====================================");
  console.log(`Network: ${networkName}`);
  console.log(`Proxy Address: ${proxyAddress}`);
  console.log(`Implementation Address: ${implementationAddress}`);
  console.log(`Block Explorer (Proxy): ${blockExplorer}/address/${proxyAddress}`);
  console.log(`Block Explorer (Impl): ${blockExplorer}/address/${implementationAddress}`);
  console.log(`Deployer: ${deployer.address}`);
  console.log(`Treasury: ${treasuryAddress}`);
  console.log("=====================================");
  
  // ===== STEP 7: USAGE EXAMPLES =====
  console.log("\n📡 Usage Examples:");
  
  // Contract interaction example
  console.log("\n1. Contract interaction via ethers.js (use PROXY address):");
  console.log(`const contract = new ethers.Contract("${proxyAddress}", abi, signer);`);
  console.log(`const owner = await contract.owner();`);
  console.log(`const pendingBuyOrders = await contract.getPendingBuyOrders();`);
  console.log(`const userBuyOrders = await contract.getUserBuyOrders(userAddress);`);
  
  // Buy order creation example
  console.log("\n2. Create a BUY order (user deposits crypto to get fiat):");
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
  
  // Sell order creation example
  console.log("\n3. Create a SELL order (user wants to sell crypto for fiat):");
  console.log(`const orderMetadata = JSON.stringify({`);
  console.log(`  serviceType: "onramp",`);
  console.log(`  paymentMethod: "BANK_TRANSFER",`);
  console.log(`  bankAccount: "1234567890",`);
  console.log(`  bankName: "Stanbic Bank"`);
  console.log(`});`);
  console.log(`const tx = await contract.createSellOrder(`);
  console.log(`  "0xUSDTAddress", // USDT token address`);
  console.log(`  ethers.parseUnits("100", 6), // 100 USDT`);
  console.log(`  "UGX", // Source currency`);
  console.log(`  "370000", // 370,000 UGX`);
  console.log(`  orderMetadata`);
  console.log(`);`);
  
  // Admin functions
  console.log("\n4. Admin functions:");
  console.log(`// Fill a buy order (after sending fiat to user)`);
  console.log(`await contract.fillBuyOrder(orderId, "Sent 100,000 UGX via MTN Mobile Money");`);
  console.log(`// Fill a sell order (after receiving fiat from user)`);
  console.log(`await contract.fillSellOrder(orderId, "Received 370,000 UGX via bank transfer");`);
  console.log(`// Refund a buy order`);
  console.log(`await contract.refundBuyOrder(orderId, "Unable to process payment");`);
  
  // Update metadata and delete
  console.log("\n5. Update metadata or delete orders:");
  console.log(`// Update buy order metadata`);
  console.log(`await contract.updateBuyOrderMetadata(orderId, newMetadata);`);
  console.log(`// Delete buy order (only if metadata NOT updated)`);
  console.log(`await contract.deleteBuyOrder(orderId);`);
  console.log(`// Delete sell order (only if metadata NOT updated)`);
  console.log(`await contract.deleteSellOrder(orderId);`);
  
  // Rate and fee management
  console.log("\n6. Set exchange rates and fees (Admin only):");
  console.log(`// Set exchange rate`);
  console.log(`await contract.setExchangeRate(`);
  console.log(`  "0xUSDTAddress", // token`);
  console.log(`  "UGX", // currency`);
  console.log(`  3700000, // rate (3700.000 with 3 decimals)`);
  console.log(`  3 // decimals`);
  console.log(`);`);
  console.log(`// Set fee configuration`);
  console.log(`await contract.setFeeConfig(`);
  console.log(`  "0xUSDTAddress", // token`);
  console.log(`  50, // 0.5% buy fee (50 basis points)`);
  console.log(`  50, // 0.5% sell fee`);
  console.log(`  ethers.parseUnits("1", 6), // min fee: 1 USDT`);
  console.log(`  ethers.parseUnits("100", 6) // max fee: 100 USDT`);
  console.log(`);`);
  
  // Upgrade example
  console.log("\n7. Upgrade contract (Owner only):");
  console.log(`const LaitV3 = await ethers.getContractFactory("LaitV3");`);
  console.log(`const upgraded = await upgrades.upgradeProxy("${proxyAddress}", LaitV3);`);
  console.log(`console.log("Upgraded to:", await upgraded.getAddress());`);
  
  // Next steps
  console.log("\n📋 Next Steps:");
  console.log("1. Add supported tokens using setSupportedToken()");
  console.log("   Example: await contract.setSupportedToken('0xUSDTAddress', true)");
  console.log("2. Set exchange rates using setExchangeRate()");
  console.log("   Example: await contract.setExchangeRate('0xUSDTAddress', 'UGX', 3700000, 3)");
  console.log("3. Configure fees using setFeeConfig()");
  console.log("   Example: await contract.setFeeConfig('0xUSDTAddress', 50, 50, minFee, maxFee)");
  console.log("4. Set order limits using setOrderLimits()");
  console.log("   Example: await contract.setOrderLimits('0xUSDTAddress', minAmount, maxAmount)");
  console.log("5. Add additional admins using addAdmin()");
  console.log("   Example: await contract.addAdmin('0xAdminAddress', 'Admin Name')");
  console.log("6. Test buy and sell order flows");
  console.log("7. Update treasury address if needed using updateTreasury()");
  
  // Example service types
  console.log("\n🛍️ Example Service Types in Order Metadata:");
  
  console.log("\n• Buy Order - Off-ramp (Crypto to Mobile Money):");
  console.log(`{`);
  console.log(`  "serviceType": "offramp",`);
  console.log(`  "paymentMethod": "MTN_MOMO",`);
  console.log(`  "phoneNumber": "+256123456789",`);
  console.log(`  "recipientName": "John Doe"`);
  console.log(`}`);
  
  console.log("\n• Sell Order - On-ramp (Fiat to Crypto):");
  console.log(`{`);
  console.log(`  "serviceType": "onramp",`);
  console.log(`  "paymentMethod": "BANK_TRANSFER",`);
  console.log(`  "bankAccount": "1234567890",`);
  console.log(`  "bankName": "Stanbic Bank",`);
  console.log(`  "accountName": "Jane Smith"`);
  console.log(`}`);
  
  console.log("\n• Buy Order - Utility Payment:");
  console.log(`{`);
  console.log(`  "serviceType": "utility",`);
  console.log(`  "utilityType": "electricity",`);
  console.log(`  "accountNumber": "12345678",`);
  console.log(`  "providerName": "UMEME"`);
  console.log(`}`);
  
  console.log("\n• Buy Order - Send to Someone:");
  console.log(`{`);
  console.log(`  "serviceType": "transfer",`);
  console.log(`  "paymentMethod": "MOBILE_MONEY",`);
  console.log(`  "recipientPhone": "+256987654321",`);
  console.log(`  "recipientName": "Jane Smith"`);
  console.log(`}`);
  
  // Save deployment info
  const deploymentInfo = {
    network: networkName,
    chainId: chainId,
    proxyAddress: proxyAddress,
    implementationAddress: implementationAddress,
    proxyExplorer: `${blockExplorer}/address/${proxyAddress}`,
    implementationExplorer: `${blockExplorer}/address/${implementationAddress}`,
    deployer: deployer.address,
    treasury: treasuryAddress,
    deploymentTime: new Date().toISOString(),
    transactionHash: deploymentTx?.hash,
    contractType: "LaitV2",
    proxyType: "UUPS",
    isUpgradeable: true,
    minRefundTimeHours: 2,
    features: [
      "UUPS Upgradeable Proxy Pattern",
      "Buy orders (crypto to fiat)",
      "Sell orders (fiat to crypto)",
      "Configurable fees per token",
      "Manual exchange rate management",
      "Order amount limits (min/max)",
      "Enhanced admin system with stats",
      "Metadata update and delete functionality",
      "Fee collection system",
      "Multi-admin support",
      "ETH and ERC20 token support"
    ],
    orderTypes: [
      "BUY: User deposits crypto → Admin sends fiat → Treasury receives crypto",
      "SELL: User wants to sell crypto → Admin pays fiat → Treasury receives crypto from user"
    ]
  };
  
  console.log("\n💾 Deployment Info (save this):");
  console.log(JSON.stringify(deploymentInfo, null, 2));
  
  // Write deployment info to file
  const fs = require('fs');
  const deploymentFile = `deployments/${network}-laitv2-proxy-${Date.now()}.json`;
  
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
  
  // Important notes
  console.log("\n⚠️  IMPORTANT NOTES:");
  console.log("1. ALWAYS interact with the PROXY address, NOT the implementation");
  console.log("2. The proxy address will remain the same even after upgrades");
  console.log("3. To upgrade: use upgrades.upgradeProxy() from @openzeppelin/hardhat-upgrades");
  console.log("4. Only the owner can upgrade the contract");
  console.log("5. Sell orders require user approval before fillSellOrder() can transfer tokens");
  console.log("6. Delete orders only works if metadata has NOT been updated");
  console.log("7. Set exchange rates before accepting orders");
  console.log("8. Configure fees to collect service charges");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });