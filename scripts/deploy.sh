#!/usr/bin/env bash
# Deploy AgentOrchestrator to Arc Testnet
# Usage: ./scripts/deploy.sh
#
# Prerequisites:
#   1. Copy .env.example to .env and fill in AGENT_PRIVATE_KEY
#   2. Fund wallet with testnet USDC from https://faucet.circle.com
#   3. Install Foundry: curl -L https://foundry.paradigm.xyz | bash && foundryup

set -e
source .env

echo "🌐 Deploying to Arc Testnet (Chain ID 5042002)"
echo "📍 Deployer: $(cast wallet address $AGENT_PRIVATE_KEY)"

IDENTITY_ADDRESS="${AGENT_IDENTITY_REGISTRY_ADDRESS:-0x5Bef356f89425823FC7eebB3A6ED1A678F3b8233}"
USDC_ADDRESS="0x3600000000000000000000000000000000000000"

echo ""
echo "📋 Deploying AgentOrchestrator..."
ORCHESTRATOR_ADDRESS=$(forge create \
  contracts/AgentOrchestrator.sol:AgentOrchestrator \
  --rpc-url "$ARC_RPC_URL" \
  --private-key "$AGENT_PRIVATE_KEY" \
  --constructor-args "$IDENTITY_ADDRESS" "$USDC_ADDRESS" \
  --broadcast \
  --json | jq -r '.deployedTo')

echo "✅ AgentOrchestrator deployed: $ORCHESTRATOR_ADDRESS"

echo ""
echo "🔗 Authorising AgentOrchestrator as trusted reputation updater..."
cast send "$IDENTITY_ADDRESS" \
  "setTrustedUpdater(address,bool)" \
  "$ORCHESTRATOR_ADDRESS" true \
  --rpc-url "$ARC_RPC_URL" \
  --private-key "$AGENT_PRIVATE_KEY"

echo "✅ Trusted updater set"

echo ""
echo "📝 Updating .env..."
sed -i.bak "s|AGENT_ORCHESTRATOR_ADDRESS=.*|AGENT_ORCHESTRATOR_ADDRESS=$ORCHESTRATOR_ADDRESS|" .env
rm .env.bak 2>/dev/null || true

echo ""
echo "🎉 Deployment complete!"
echo "   AgentOrchestrator: $ORCHESTRATOR_ADDRESS"
echo "   View on ArcScan: https://testnet.arcscan.app/address/$ORCHESTRATOR_ADDRESS"
