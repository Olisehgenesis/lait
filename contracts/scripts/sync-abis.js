import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const artifactsDir = './artifacts';
const outputDir = './deployments/abis';

// Create output directory if it doesn't exist
if (!fs.existsSync(outputDir)) {
  fs.mkdirSync(outputDir, { recursive: true });
}

// Read all contract artifacts from contracts subdirectory
const contractsDir = path.join(artifactsDir, 'contracts');
fs.readdirSync(contractsDir, { withFileTypes: true }).forEach(dirent => {
  if (dirent.isDirectory()) {
    const contractDir = path.join(contractsDir, dirent.name);
    
    // Look for JSON files in each contract directory
    fs.readdirSync(contractDir).forEach(file => {
      if (file.endsWith('.json') && !file.includes('artifacts.d.ts')) {
        const artifactPath = path.join(contractDir, file);
        const artifact = JSON.parse(fs.readFileSync(artifactPath, 'utf8'));
        
        // Extract ABI if it exists
        if (artifact.abi && artifact.abi.length > 0) {
          const contractName = dirent.name.replace('.sol', '');
          const abiPath = path.join(outputDir, `${contractName}.json`);
          fs.writeFileSync(abiPath, JSON.stringify(artifact.abi, null, 2));
          console.log(`✓ Synced ABI for ${contractName}`);
        }
      }
    });
  }
});

console.log(`\n🎉 ABIs synced to ${outputDir}/`);
