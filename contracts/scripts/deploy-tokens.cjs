const { ethers } = require("hardhat");
const { run } = require("hardhat");
const hre = require("hardhat");
const fs = require("fs");
const path = require("path");
require("dotenv").config();

async function loadLatestCoreDeployment(network) {
  const deploymentsDir = path.join(__dirname, "../deployments");
  if (!fs.existsSync(deploymentsDir)) return null;
  const files = fs
    .readdirSync(deploymentsDir)
    .filter((f) => f.endsWith(".json") && f.includes("lightv2"));
  if (files.length === 0) return null;
  const file = files
    .filter((f) => (network ? f.includes(network) : true))
    .sort()
    .pop();
  if (!file) return null;
  const raw = fs.readFileSync(path.join(deploymentsDir, file), "utf8");
  return JSON.parse(raw);
}

async function saveTokenDeployment(network, data) {
  const deploymentsDir = path.join(__dirname, "../deployments");
  if (!fs.existsSync(deploymentsDir)) fs.mkdirSync(deploymentsDir);
  const filename = `${network}-tokens-${Date.now()}.json`;
  fs.writeFileSync(path.join(deploymentsDir, filename), JSON.stringify(data, null, 2));
  console.log(`\n📁 Token deployment info saved to: deployments/${filename}`);
}

async function maybeVerify(contractAddress, constructorArgs, network, etherscanApiKey) {
  if (!etherscanApiKey) {
    console.log("⚠️  No Etherscan API key found, skipping verification for", contractAddress);
    return;
  }
  try {
    console.log("⏳ Waiting 30 seconds before verification...");
    await new Promise((r) => setTimeout(r, 30000));
    await run("verify:verify", { address: contractAddress, constructorArguments: constructorArgs });
    console.log("✅ Verified:", contractAddress);
  } catch (e) {
    console.log("❌ Verification failed for", contractAddress, e.message);
    console.log(`You can verify later: npx hardhat verify --network ${network} ${contractAddress} ${constructorArgs.map(a=>`"${a}"`).join(" ")}`);
  }
}

async function alreadyDeployed(provider, address) {
  if (!address) return false;
  try {
    const code = await provider.getCode(address);
    return code && code !== "0x";
  } catch {
    return false;
  }
}

async function main() {
  const network = hre.network.name || "baseSepolia";
  if (!["base", "baseSepolia"].includes(network)) {
    throw new Error("Invalid network. Use 'base' or 'baseSepolia'");
  }

  if (!process.env.PRIVATE_KEY) throw new Error("PRIVATE_KEY not found in env");

  const rpcUrl = network === "base" ? (process.env.BASE_RPC_URL || "https://base.drpc.org") : (process.env.BASE_SEPOLIA_RPC_URL || "https://sepolia.base.org");
  const chainId = network === "base" ? 8453 : 84532;
  const blockExplorer = network === "base" ? "https://basescan.org" : "https://sepolia.basescan.org";
  const etherscanApiKey = process.env.ETHERSCAN_API_KEY;

  const provider = new ethers.JsonRpcProvider(rpcUrl);
  const wallet = new ethers.Wallet(process.env.PRIVATE_KEY);
  const deployer = wallet.connect(provider);
  console.log(`🚀 Deploying tokens on ${network} with ${deployer.address}`);

  const balance = await provider.getBalance(deployer.address);
  console.log("Deployer balance:", ethers.formatEther(balance), "ETH");
  if (balance === 0n) throw new Error("Account has no ETH balance");

  const core = await loadLatestCoreDeployment(network);
  if (!core) {
    console.log("⚠️  No LightV2 deployment record found. Proceeding with token-only deployment.");
  } else {
    console.log("Linked LightV2:", core.contractAddress);
  }

  const LaitUSD = await ethers.getContractFactory("LaitUSD", deployer);
  const LightToken = await ethers.getContractFactory("LightToken", deployer);

  const constructorArgs = [deployer.address];

  let lUSDAddress = process.env.LUSD_ADDRESS || "";
  let lightAddress = process.env.LIGHT_ADDRESS || "";

  if (!(await alreadyDeployed(provider, lUSDAddress))) {
    console.log("\n📦 Deploying LaitUSD...");
    const feeData = await provider.getFeeData();
    const lusd = await LaitUSD.deploy(...constructorArgs, {
      gasPrice: feeData.gasPrice ? (feeData.gasPrice * 120n) / 100n : undefined,
    });
    await lusd.waitForDeployment();
    lUSDAddress = await lusd.getAddress();
    console.log("✅ LaitUSD deployed:", lUSDAddress);
  } else {
    console.log("✅ LaitUSD already deployed:", lUSDAddress);
  }

  if (!(await alreadyDeployed(provider, lightAddress))) {
    console.log("\n📦 Deploying LightToken...");
    const feeData = await provider.getFeeData();
    const light = await LightToken.deploy(...constructorArgs, {
      gasPrice: feeData.gasPrice ? (feeData.gasPrice * 120n) / 100n : undefined,
    });
    await light.waitForDeployment();
    lightAddress = await light.getAddress();
    console.log("✅ LightToken deployed:", lightAddress);
  } else {
    console.log("✅ LightToken already deployed:", lightAddress);
  }

  // Verify
  await maybeVerify(lUSDAddress, constructorArgs, network, etherscanApiKey);
  await maybeVerify(lightAddress, constructorArgs, network, etherscanApiKey);

  // Mint 1,000,000 of each to deployer
  console.log("\n🪙 Minting to deployer...");
  const lUSD = await ethers.getContractAt("LaitUSD", lUSDAddress, deployer);
  const light = await ethers.getContractAt("LightToken", lightAddress, deployer);

  const oneMillion18 = ethers.parseUnits("1000000", 18);
  const oneMillion6 = ethers.parseUnits("1000000", 6);

  // Try/catch to keep idempotent if already minted
  try {
    const tx1 = await lUSD.mint(deployer.address, oneMillion6);
    await tx1.wait();
    console.log("✅ Minted 1,000,000 lUSD to", deployer.address);
  } catch (e) {
    console.log("⚠️  Mint lUSD skipped:", e.message);
  }

  try {
    const tx2 = await light.mint(deployer.address, oneMillion18);
    await tx2.wait();
    console.log("✅ Minted 1,000,000 LIGHT to", deployer.address);
  } catch (e) {
    console.log("⚠️  Mint LIGHT skipped:", e.message);
  }

  const result = {
    network,
    chainId,
    deployer: deployer.address,
    blockExplorer,
    tokens: {
      LaitUSD: lUSDAddress,
      LightToken: lightAddress,
    },
    linkedCore: core?.contractAddress || null,
    time: new Date().toISOString(),
  };

  await saveTokenDeployment(network, result);
  console.log("\n🎉 Token deployment script complete.");
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error(err);
    process.exit(1);
  });


