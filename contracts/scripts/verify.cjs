const { readFileSync, existsSync, readdirSync } = require('fs');
const { join } = require('path');
const https = require('https');
require('dotenv').config();



function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// Load deployment data from JSON file
function loadDeploymentData(network = null) {
  const deploymentsDir = join(__dirname, '../deployments');
  
  if (!existsSync(deploymentsDir)) {
    throw new Error('Deployments directory not found. Run deployment script first.');
  }
  
  const files = readdirSync(deploymentsDir).filter(file => 
    file.endsWith('.json') && file.includes('lightv2')
  );
  
  if (files.length === 0) {
    throw new Error('No LightV2 deployment files found in deployments directory.');
  }
  
  // If network specified, find matching file
  let deploymentFile;
  if (network) {
    deploymentFile = files.find(file => file.toLowerCase().includes(network.toLowerCase()));
    if (!deploymentFile) {
      console.log(`Available deployment files:`);
      files.forEach(file => console.log(`  - ${file}`));
      throw new Error(`No deployment file found for network: ${network}`);
    }
  } else {
    // Use the most recent file
    deploymentFile = files.sort().pop();
    console.log(`Using most recent deployment: ${deploymentFile}`);
  }
  
  const deploymentPath = join(deploymentsDir, deploymentFile);
  const deploymentData = JSON.parse(readFileSync(deploymentPath, 'utf8'));
  
  console.log(`📄 Loaded deployment data:`);
  console.log(`  Contract: ${deploymentData.contractAddress}`);
  console.log(`  Network: ${deploymentData.network}`);
  console.log(`  Deployed: ${deploymentData.deploymentTime}`);
  
  return deploymentData;
}

// Direct API verification using BaseScan/Etherscan API
async function verifyContractDirect(deploymentData) {
  const { contractAddress, network, chainId, constructorArguments } = deploymentData;
  
  console.log(`🔍 Verifying LightV2 at ${contractAddress} on ${network}...`);
  
  try {
    // Read the contract artifact
    const artifactsPath = join(__dirname, '../artifacts/contracts');
    const contractPath = join(artifactsPath, 'LightV2.sol', 'LightV2.json');
    
    let contractArtifact;
    try {
      contractArtifact = JSON.parse(readFileSync(contractPath, 'utf8'));
    } catch (error) {
      console.log(`❌ Could not find LightV2 contract artifact`);
      return { success: false, message: "Contract artifact not found" };
    }

    // Network-specific settings
    let apiUrl, browserUrl, apiKey;
    
    if (chainId === 8453) { // Base Mainnet
      apiUrl = "https://api.etherscan.io/v2/api";
      browserUrl = "https://basescan.org";
      apiKey = process.env.BASESCAN_API_KEY || process.env.ETHERSCAN_API_KEY;
    } else if (chainId === 84532) { // Base Sepolia
      apiUrl = "https://api.etherscan.io/v2/api";
      browserUrl = "https://sepolia.basescan.org";
      apiKey = process.env.BASESCAN_API_KEY || process.env.ETHERSCAN_API_KEY;
    } else {
      throw new Error(`Unsupported chain ID: ${chainId}`);
    }
    
    if (!apiKey) {
      throw new Error('API key not found. Set BASESCAN_API_KEY or ETHERSCAN_API_KEY in environment.');
    }

    // Extract Solidity version
    let solcVersion = "v0.8.24+commit.e11b9ed9"; // fallback
    
    // Get constructor arguments as hex string
    let constructorArgs = "";
    if (constructorArguments && constructorArguments.length > 0) {
      // Encode constructor arguments
      const { ethers } = require('ethers');
      const abiCoder = ethers.AbiCoder.defaultAbiCoder();
      
      // LightV2 constructor takes (address _treasury)
      const encodedArgs = abiCoder.encode(['address'], constructorArguments);
      // Remove the '0x' prefix for BaseScan
      constructorArgs = encodedArgs.slice(2);
      
      console.log(`📝 Constructor arguments: ${constructorArguments[0]}`);
      console.log(`📝 Encoded arguments: ${constructorArgs}`);
    }

    // Get source code from build info
    let sourceCode = "";
    try {
      // Find the latest build info file
      const buildInfoDir = join(__dirname, '../artifacts/build-info');
      if (existsSync(buildInfoDir)) {
        const buildFiles = readdirSync(buildInfoDir).filter(file => file.endsWith('.json'));
        if (buildFiles.length > 0) {
          // Use the most recent build file
          const buildFile = buildFiles.sort().pop();
          const buildInfoPath = join(buildInfoDir, buildFile);
          const buildInfo = JSON.parse(readFileSync(buildInfoPath, 'utf8'));
          sourceCode = JSON.stringify(buildInfo.input);
          console.log(`📝 Using build info: ${buildFile}`);
        }
      }
      
      if (!sourceCode) {
        throw new Error('Could not find build info for source code');
      }
    } catch (error) {
      console.log(`⚠️  Could not read build info: ${error.message}`);
      throw error;
    }

    // Prepare verification data (chainid goes in URL, not body)
    const verificationData = {
      apikey: apiKey,
      module: "contract",
      action: "verifysourcecode",
      contractaddress: contractAddress,
      sourcecode: sourceCode,
      codeformat: "solidity-standard-json-input",
      contractname: "contracts/LightV2.sol:LightV2",
      compilerversion: solcVersion,
      optimizationUsed: "0", // Assuming no optimization
      runs: "200",
      constructorArguments: constructorArgs,
      evmversion: "shanghai",
      licenseType: "MIT"
    };

    console.log(`📝 Verification details:`);
    console.log(`📝 Solidity version: ${verificationData.compilerversion}`);
    console.log(`📝 Optimization: ${verificationData.optimizationUsed === "1" ? 'Enabled' : 'Disabled'}`);
    console.log(`📝 Constructor args length: ${constructorArgs.length / 2} bytes`);

    // Submit verification using HTTPS POST
    const postData = new URLSearchParams(verificationData).toString();
    
    // Parse API URL and add chainid as query parameter
    const apiUrlObj = new URL(apiUrl);
    apiUrlObj.searchParams.set('chainid', chainId);
    
    const options = {
      hostname: apiUrlObj.hostname,
      port: 443,
      path: apiUrlObj.pathname + apiUrlObj.search,
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'Content-Length': Buffer.byteLength(postData)
      }
    };

    return new Promise((resolve) => {
      const req = https.request(options, (res) => {
        let data = '';
        
        res.on('data', (chunk) => {
          data += chunk;
        });
        
        res.on('end', () => {
          try {
            const result = JSON.parse(data);
            
            if (result.status === "1") {
              console.log(`✅ Verification submitted successfully`);
              console.log(`📋 GUID: ${result.result}`);
              
              // Poll for verification status
              pollVerificationStatus(result.result, contractAddress, chainId, browserUrl, apiKey)
                .then(resolve)
                .catch(resolve);
            } else {
              // Check if already verified
              if (result.result && result.result.includes("already verified")) {
                console.log(`✅ Contract is already verified`);
                resolve({
                  success: true,
                  message: "Already verified",
                  url: `${browserUrl}/address/${contractAddress}`
                });
              } else {
                console.log(`❌ Verification submission failed: ${result.result}`);
                resolve({
                  success: false,
                  message: result.result || "Verification submission failed"
                });
              }
            }
          } catch (error) {
            console.log(`❌ Failed to parse response: ${error.message}`);
            resolve({
              success: false,
              message: `Failed to parse response: ${error.message}`
            });
          }
        });
      });

      req.on('error', (error) => {
        console.log(`❌ Request error: ${error.message}`);
        resolve({
          success: false,
          message: `Request error: ${error.message}`
        });
      });

      req.write(postData);
      req.end();
    });

  } catch (error) {
    console.log(`💥 Error verifying contract: ${error.message}`);
    return {
      success: false,
      message: error.message
    };
  }
}

async function pollVerificationStatus(guid, contractAddress, chainId, browserUrl, apiKey) {
  console.log(`⏳ Polling verification status...`);
  
  let attempts = 0;
  const maxAttempts = 30; // 5 minutes max
  
  // Determine API URL for status check
  let statusApiUrl;
  if (chainId === 8453) {
    statusApiUrl = "https://api.etherscan.io/v2/api";
  } else if (chainId === 84532) {
    statusApiUrl = "https://api.etherscan.io/v2/api";
  }
  
  while (attempts < maxAttempts) {
    await delay(10000); // Wait 10 seconds
    
    const statusParams = new URLSearchParams({
      chainid: chainId,
      apikey: apiKey,
      module: "contract",
      action: "checkverifystatus",
      guid: guid
    });
    
    const statusUrl = `${statusApiUrl}?${statusParams.toString()}`;
    
    try {
      const result = await new Promise((resolve, reject) => {
        https.get(statusUrl, (res) => {
          let data = '';
          res.on('data', (chunk) => { data += chunk; });
          res.on('end', () => {
            try {
              resolve(JSON.parse(data));
            } catch (error) {
              reject(error);
            }
          });
        }).on('error', reject);
      });
      
      if (result.status === "1") {
        console.log(`✅ Verification completed successfully!`);
        return {
          success: true,
          message: "Verification successful",
          url: `${browserUrl}/address/${contractAddress}`
        };
      } else if (result.result === "Pending in queue") {
        console.log(`⏳ Verification pending... (${attempts + 1}/${maxAttempts})`);
        attempts++;
      } else {
        console.log(`❌ Verification failed: ${result.result}`);
        return {
          success: false,
          message: result.result || "Verification failed"
        };
      }
    } catch (error) {
      console.log(`❌ Error checking status: ${error.message}`);
      return {
        success: false,
        message: `Status check error: ${error.message}`
      };
    }
  }
  
  console.log(`⏰ Verification timeout`);
  return {
    success: false,
    message: "Verification timeout"
  };
}

async function main() {
  try {
    // Get network from command line args or use null for latest
    const network = process.argv[2]; // e.g., 'baseSepolia' or 'base'
    
    console.log(`🔍 Starting LightV2 contract verification...`);
    
    // Load deployment data from JSON
    const deploymentData = loadDeploymentData(network);
    
    // Verify the contract
    const result = await verifyContractDirect(deploymentData);
    
    // Show results
    console.log("\n📊 Verification Result:");
    if (result.success) {
      console.log(`✅ Success: ${result.message}`);
      if (result.url) {
        console.log(`🔗 View on explorer: ${result.url}`);
      }
    } else {
      console.log(`❌ Failed: ${result.message}`);
      
      // Show manual verification command
      console.log(`\n🔧 Manual verification command:`);
      console.log(`npx hardhat verify --network ${deploymentData.network.toLowerCase()} ${deploymentData.contractAddress} "${deploymentData.constructorArguments[0]}"`);
    }
    
  } catch (error) {
    console.error("💥 Verification script failed:", error.message);
    
    // Show available deployment files if directory exists
    try {
      const deploymentsDir = join(__dirname, '../deployments');
      if (existsSync(deploymentsDir)) {
        const files = readdirSync(deploymentsDir).filter(file => 
          file.endsWith('.json') && file.includes('lightv2')
        );
        
        if (files.length > 0) {
          console.log(`\n📁 Available deployment files:`);
          files.forEach(file => {
            console.log(`  - ${file}`);
          });
          console.log(`\n💡 Usage: node scripts/verify-lightv2.js [network]`);
          console.log(`Example: node scripts/verify-lightv2.js baseSepolia`);
        }
      }
    } catch (e) {
      // Ignore error showing files
    }
    
    process.exit(1);
  }
}

main();