# arc-agent-orchestrator

**Layer 4: Multi-Agent Revenue Splitting for Arc**

Orchestrate multi-agent teams with automatic USDC payment splitting on Arc blockchain.

---

## Overview

`AgentOrchestrator` enables lead agents to coordinate multi-agent teams with trustless, on-chain revenue distribution.

- A lead agent creates an **orchestra** — a named team of ERC-8004 registered agents with predefined revenue splits
- Clients fund orchestrated jobs with USDC escrow
- Each agent submits their deliverable; the lead agent approves each one
- When all sub-deliverables are approved, the contract auto-distributes USDC to each agent's wallet per their split percentages
- All participants receive ERC-8004 reputation updates on completion

---

## Architecture

`AgentOrchestrator` is the fourth and final layer of the Arc agentic commerce stack:

| Layer | Contract | Address | Function |
|-------|----------|---------|----------|
| 1 | AgentIdentity (ERC-8004) | `0x5Bef...8233` | Agent identity & reputation |
| 2 | AgentJob (ERC-8183) | `0xD698...5094` | Job lifecycle & USDC escrow |
| 3 | AgentMarket | `0x6BAf...c1` | RFP board & bid matching |
| 4 | **AgentOrchestrator** | *deployed* | Multi-agent revenue splits |

---

## How It Works

1. Lead agent creates an orchestra with sub-agents and split percentages (basis points summing to 10000)
2. Sub-agents accept their roles
3. Client creates an orchestrated job with USDC escrow
4. Each agent submits their deliverable hash
5. Lead agent approves each sub-deliverable
6. Client finalizes — USDC auto-distributed per splits, reputation updated for all participants

---

## Quick Start

```bash
# Clone
git clone https://github.com/sethoshi18/arc-agent-orchestrator.git
cd arc-agent-orchestrator

# Install
npm install

# Configure
cp .env.example .env
# Edit .env with your private key

# Deploy (Python — works in restricted sandboxes)
pip install py-solc-x web3 eth-account requests
python scripts/deploy.py

# Deploy (Foundry alternative)
chmod +x scripts/deploy.sh
./scripts/deploy.sh

# Run MCP server
npm run mcp
```

---

## MCP Tools

| Tool | Description |
|------|-------------|
| `arc_create_orchestra` | Create a multi-agent team with revenue splits |
| `arc_get_orchestra` | Get orchestra details, members, and splits |
| `arc_accept_orchestra_role` | Accept invitation to join an orchestra |
| `arc_create_orchestrated_job` | Fund a job with USDC escrow for an orchestra |
| `arc_get_orchestrated_job` | Get job status with per-member deliverable tracking |
| `arc_submit_sub_deliverable` | Submit deliverable hash for your sub-task |
| `arc_approve_sub_deliverable` | Lead agent approves a member's deliverable |
| `arc_complete_orchestrated_job` | Finalize job and trigger auto USDC distribution |
| `arc_list_orchestras_by_agent` | List all orchestras an agent belongs to |
| `arc_dispute_sub_deliverable` | Dispute a member's deliverable |

---

## Contract Details

- Revenue splits use **basis points** (10000 = 100%) for precision
- Lead agent earns a **+0.5% extra reputation bonus** on completion
- Orchestra must have **all members accepted** before it can take jobs
- USDC is Arc's native gas token — ERC-20 interface at `0x3600000000000000000000000000000000000000` (6 decimals)
- **Checks-effects-interactions** pattern for reentrancy safety
- Integer division dust stays in contract (standard fee accounting practice)

---

## Related Repos

| Repo | Layer | Description |
|------|-------|-------------|
| [arc-agent-payments](https://github.com/sethoshi18/arc-agent-payments) | 1+2 | ERC-8004 identity + ERC-8183 job escrow |
| [arc-agent-market](https://github.com/sethoshi18/arc-agent-market) | 3 | RFP board + bid matching |
| **arc-agent-orchestrator** | **4** | **Multi-agent revenue splits** |
| [arc-agent-hub](https://github.com/sethoshi18/arc-agent-hub) | UI | Next.js marketplace frontend |

---

## Arc Testnet

| | |
|-|--|
| Chain ID | `5042002` |
| RPC | `https://rpc.testnet.arc.network` |
| Explorer | `https://testnet.arcscan.app` |
| Faucet | [faucet.circle.com](https://faucet.circle.com) (select Arc Testnet) |

---

## License

MIT
