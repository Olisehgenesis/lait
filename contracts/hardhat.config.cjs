require("@nomicfoundation/hardhat-toolbox-viem");
require("@nomicfoundation/hardhat-ethers");
require("@nomicfoundation/hardhat-verify");
require("@nomicfoundation/hardhat-ignition");
require("@nomicfoundation/hardhat-ignition-ethers");
require("@openzeppelin/hardhat-upgrades");
require("dotenv/config");

// Load custom tasks
// require("./tasks/deploy-upgradeable.ts");



const config = {
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
      viaIR: true,
    },
    npmFilesToBuild: [
      "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol",
      "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol",
      "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol",
    ],
  },
  networks: {
    baseSepolia: {
      type: "http",
      url: process.env.BASE_SEPOLIA_RPC_URL || "https://sepolia.base.org",
      chainId: 84532,
      timeout: 300000, // 5 minutes timeout
      gasPrice: "auto",
      gas: "auto",
    },
    base: {
      type: "http",
      url: process.env.BASE_RPC_URL || "https://base.drpc.org",
      chainId: 8453,
      timeout: 300000, // 5 minutes timeout
      gasPrice: "auto",
      gas: "auto",
    },
  },
  etherscan: {
    apiKey: "H61R3Q6MPMFF5GGN3GP9JNBYYFT6WDDM42",
    customChains: [
      {
        network: "base",
        chainId: 8453,
        urls: {
          apiURL: "https://api.basescan.org/api",
          browserURL: "https://basescan.org",
        },
      },
      {
        network: "baseSepolia",
        chainId: 84532,
        urls: {
          apiURL: "https://api-sepolia.basescan.org/api",
          browserURL: "https://sepolia.basescan.org",
        },
      },
    ],
  },
  verify: {
    blockscout: {
      enabled: false,
    },
  },
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts",
  },
  sourcify: {
    enabled: true
  }
};

module.exports = config;
