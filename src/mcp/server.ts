/**
 * Arc Agent Orchestrator MCP Server
 *
 * Layer 4: Multi-agent revenue splitting tools.
 * Create orchestras, manage jobs, approve sub-deliverables, auto-distribute USDC.
 *
 * Add to Claude Desktop:
 * {
 *   "mcpServers": {
 *     "arc-orchestrator": {
 *       "command": "npx",
 *       "args": ["tsx", "/path/to/arc-agent-orchestrator/src/mcp/server.ts"],
 *       "env": { "AGENT_PRIVATE_KEY": "0x...", "AGENT_ORCHESTRATOR_ADDRESS": "0x..." }
 *     }
 *   }
 * }
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { AgentOrchestratorClient, ORCHESTRA_STATUS, JOB_STATUS, SUBTASK_STATUS } from "../orchestrator/orchestrator.js";
import "dotenv/config";

const client = new AgentOrchestratorClient();
const server = new Server({ name: "arc-agent-orchestrator", version: "0.1.0" }, { capabilities: { tools: {} } });

// ---------------------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------------------

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "arc_create_orchestra",
      description:
        "Create a multi-agent orchestra with defined USDC revenue splits. Lead agent is included as the first member.",
      inputSchema: {
        type: "object",
        properties: {
          leadAgentId: {
            type: "number",
            description: "Token ID of the lead agent.",
          },
          subAgentIds: {
            type: "array",
            items: { type: "number" },
            description: "Token IDs of sub-agents in the orchestra.",
          },
          splitBps: {
            type: "array",
            items: { type: "number" },
            description: "Basis points for each member, lead first. Must sum to 10000.",
          },
          description: {
            type: "string",
            description: "Human-readable description of the orchestra's purpose.",
          },
        },
        required: ["leadAgentId", "subAgentIds", "splitBps", "description"],
      },
    },
    {
      name: "arc_get_orchestra",
      description:
        "Get full details of an orchestra including status, members, and their revenue splits.",
      inputSchema: {
        type: "object",
        properties: {
          orchestraId: {
            type: "number",
            description: "ID of the orchestra to look up.",
          },
        },
        required: ["orchestraId"],
      },
    },
    {
      name: "arc_accept_orchestra_role",
      description: "Accept an invitation to join an orchestra as a sub-agent.",
      inputSchema: {
        type: "object",
        properties: {
          orchestraId: {
            type: "number",
            description: "ID of the orchestra to join.",
          },
          agentTokenId: {
            type: "number",
            description: "Token ID of the agent accepting the role.",
          },
        },
        required: ["orchestraId", "agentTokenId"],
      },
    },
    {
      name: "arc_create_orchestrated_job",
      description:
        "Fund an orchestrated job — USDC is escrowed and will be auto-split among orchestra members on completion.",
      inputSchema: {
        type: "object",
        properties: {
          orchestraId: {
            type: "number",
            description: "ID of the orchestra that will execute the job.",
          },
          totalAmountUsdc: {
            type: "number",
            description: "Total USDC to escrow (e.g. 10.0).",
          },
          description: {
            type: "string",
            description: "Human-readable job description.",
          },
        },
        required: ["orchestraId", "totalAmountUsdc", "description"],
      },
    },
    {
      name: "arc_get_orchestrated_job",
      description:
        "Get orchestrated job details including sub-task status for each member.",
      inputSchema: {
        type: "object",
        properties: {
          jobId: {
            type: "number",
            description: "ID of the orchestrated job.",
          },
        },
        required: ["jobId"],
      },
    },
    {
      name: "arc_submit_sub_deliverable",
      description: "Submit a deliverable hash for your portion of an orchestrated job.",
      inputSchema: {
        type: "object",
        properties: {
          jobId: {
            type: "number",
            description: "ID of the orchestrated job.",
          },
          agentTokenId: {
            type: "number",
            description: "Token ID of the submitting agent.",
          },
          deliverableHash: {
            type: "string",
            description: "keccak256 hash of deliverable content.",
          },
        },
        required: ["jobId", "agentTokenId", "deliverableHash"],
      },
    },
    {
      name: "arc_approve_sub_deliverable",
      description:
        "Lead agent approves a sub-agent's deliverable. Once all approved, client can complete the job.",
      inputSchema: {
        type: "object",
        properties: {
          jobId: {
            type: "number",
            description: "ID of the orchestrated job.",
          },
          agentTokenId: {
            type: "number",
            description: "Token ID of the agent whose deliverable is being approved.",
          },
        },
        required: ["jobId", "agentTokenId"],
      },
    },
    {
      name: "arc_complete_orchestrated_job",
      description:
        "Finalize an orchestrated job — triggers automatic USDC distribution to all orchestra members per their split percentages.",
      inputSchema: {
        type: "object",
        properties: {
          jobId: {
            type: "number",
            description: "ID of the job to complete.",
          },
        },
        required: ["jobId"],
      },
    },
    {
      name: "arc_list_orchestras_by_agent",
      description: "List all orchestras an agent belongs to (as lead or sub-agent).",
      inputSchema: {
        type: "object",
        properties: {
          agentTokenId: {
            type: "number",
            description: "Token ID of the agent.",
          },
        },
        required: ["agentTokenId"],
      },
    },
    {
      name: "arc_dispute_sub_deliverable",
      description:
        "Dispute a sub-agent's deliverable. Puts the job into Disputed status and penalizes the agent's reputation.",
      inputSchema: {
        type: "object",
        properties: {
          jobId: {
            type: "number",
            description: "ID of the orchestrated job.",
          },
          agentTokenId: {
            type: "number",
            description: "Token ID of the agent whose deliverable is disputed.",
          },
          reason: {
            type: "string",
            description: "Human-readable reason for the dispute.",
          },
        },
        required: ["jobId", "agentTokenId", "reason"],
      },
    },
  ],
}));

// ---------------------------------------------------------------------------
// Formatting helpers
// ---------------------------------------------------------------------------

/** Map a SUBTASK_STATUS label to a display icon. */
function subtaskIcon(statusLabel: string): string {
  switch (statusLabel) {
    case "Approved":  return "Approved ✅";
    case "Submitted": return "Submitted ⏳";
    case "Disputed":  return "Disputed ❌";
    default:          return "Pending ⏱️";
  }
}

/** Map an accepted boolean to a checkmark. */
function acceptedIcon(accepted: boolean): string {
  return accepted ? "✅" : "⏳";
}

/** Format a basis-point value as a percentage string, e.g. 5000 -> "50.00%" */
function bpsToPercent(bps: bigint): string {
  return (Number(bps) / 100).toFixed(2) + "%";
}

/** Format a raw USDC amount (6 decimals) as a human-readable string, e.g. 10000000 -> "10.00 USDC" */
function formatUsdc(raw: bigint): string {
  return (Number(raw) / 1_000_000).toFixed(2) + " USDC";
}

/** ArcScan transaction URL */
function txUrl(hash: string): string {
  return `https://testnet.arcscan.app/tx/${hash}`;
}

// ---------------------------------------------------------------------------
// Tool call handler
// ---------------------------------------------------------------------------

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  try {
    switch (name) {
      // -----------------------------------------------------------------------
      case "arc_create_orchestra": {
        const { leadAgentId, subAgentIds, splitBps, description } = args as {
          leadAgentId: number;
          subAgentIds: number[];
          splitBps: number[];
          description: string;
        };

        const { orchestraId, hash } = await client.createOrchestra(
          BigInt(leadAgentId),
          subAgentIds.map(BigInt),
          splitBps,
          description,
        );

        return {
          content: [
            {
              type: "text",
              text: [
                `Orchestra created successfully.`,
                ``,
                `Orchestra ID : ${orchestraId}`,
                `Lead Agent   : #${leadAgentId}`,
                `Members      : ${subAgentIds.length + 1} (including lead)`,
                `Description  : "${description}"`,
                ``,
                `Transaction  : ${txUrl(hash)}`,
              ].join("\n"),
            },
          ],
        };
      }

      // -----------------------------------------------------------------------
      case "arc_get_orchestra": {
        const { orchestraId } = args as { orchestraId: number };

        const [orchestra, members] = await Promise.all([
          client.getOrchestra(BigInt(orchestraId)),
          client.getOrchestraMembers(BigInt(orchestraId)),
        ]);

        const statusLabel = ORCHESTRA_STATUS[orchestra.status as keyof typeof ORCHESTRA_STATUS] ?? "Unknown";

        const memberLines = members.map((m, i) => {
          const isLead = m.agentTokenId === orchestra.leadAgentId;
          const role = isLead ? " (Lead)" : "";
          return `  Agent #${m.agentTokenId}${role} — ${bpsToPercent(m.splitBps)} ${acceptedIcon(m.accepted)}`;
        });

        return {
          content: [
            {
              type: "text",
              text: [
                `Orchestra #${orchestraId} — "${orchestra.description}"`,
                `Status: ${statusLabel} | Members: ${orchestra.acceptedCount}/${orchestra.memberCount} accepted`,
                ``,
                ...memberLines,
              ].join("\n"),
            },
          ],
        };
      }

      // -----------------------------------------------------------------------
      case "arc_accept_orchestra_role": {
        const { orchestraId, agentTokenId } = args as {
          orchestraId: number;
          agentTokenId: number;
        };

        const hash = await client.acceptOrchestraRole(
          BigInt(orchestraId),
          BigInt(agentTokenId),
        );

        return {
          content: [
            {
              type: "text",
              text: [
                `Orchestra role accepted.`,
                ``,
                `Orchestra ID : #${orchestraId}`,
                `Agent        : #${agentTokenId}`,
                ``,
                `Transaction  : ${txUrl(hash)}`,
              ].join("\n"),
            },
          ],
        };
      }

      // -----------------------------------------------------------------------
      case "arc_create_orchestrated_job": {
        const { orchestraId, totalAmountUsdc, description } = args as {
          orchestraId: number;
          totalAmountUsdc: number;
          description: string;
        };

        const { jobId, hash } = await client.createOrchestratedJob(
          BigInt(orchestraId),
          totalAmountUsdc,
          description,
        );

        return {
          content: [
            {
              type: "text",
              text: [
                `Orchestrated job created and funded.`,
                ``,
                `Job ID       : ${jobId}`,
                `Orchestra    : #${orchestraId}`,
                `Escrowed     : ${totalAmountUsdc.toFixed(2)} USDC`,
                `Description  : "${description}"`,
                ``,
                `Transaction  : ${txUrl(hash)}`,
              ].join("\n"),
            },
          ],
        };
      }

      // -----------------------------------------------------------------------
      case "arc_get_orchestrated_job": {
        const { jobId } = args as { jobId: number };

        const job = await client.getOrchestratedJob(BigInt(jobId));

        const [members, orchestra] = await Promise.all([
          client.getOrchestraMembers(job.orchestraId),
          client.getOrchestra(job.orchestraId),
        ]);

        const totalRaw = job.totalAmount;

        const subtasks = await Promise.all(
          members.map((m) => client.getSubTask(BigInt(jobId), m.agentTokenId)),
        );

        const memberLines = members.map((m, i) => {
          const isLead = m.agentTokenId === orchestra.leadAgentId;
          const subtask = subtasks[i];
          const role = isLead ? " (Lead)" : "";
          const splitPct = bpsToPercent(m.splitBps);
          const splitUsdc = formatUsdc((totalRaw * m.splitBps) / 10000n);
          const statusDisplay = subtaskIcon(subtask.statusLabel);
          return `  Agent #${m.agentTokenId}${role} — ${splitPct} (${splitUsdc}) — ${statusDisplay}`;
        });

        const statusLabel = JOB_STATUS[job.status as keyof typeof JOB_STATUS] ?? "Unknown";

        return {
          content: [
            {
              type: "text",
              text: [
                `Job #${jobId} | Orchestra #${job.orchestraId} | Status: ${statusLabel}`,
                `Total: ${formatUsdc(totalRaw)} | Approved: ${job.approvedCount}/${job.totalMembers}`,
                ``,
                `Members:`,
                ...memberLines,
              ].join("\n"),
            },
          ],
        };
      }

      // -----------------------------------------------------------------------
      case "arc_submit_sub_deliverable": {
        const { jobId, agentTokenId, deliverableHash } = args as {
          jobId: number;
          agentTokenId: number;
          deliverableHash: string;
        };

        const hash = await client.submitSubDeliverable(
          BigInt(jobId),
          BigInt(agentTokenId),
          deliverableHash as `0x${string}`,
        );

        return {
          content: [
            {
              type: "text",
              text: [
                `Sub-deliverable submitted.`,
                ``,
                `Job          : #${jobId}`,
                `Agent        : #${agentTokenId}`,
                `Deliverable  : ${deliverableHash}`,
                ``,
                `Transaction  : ${txUrl(hash)}`,
              ].join("\n"),
            },
          ],
        };
      }

      // -----------------------------------------------------------------------
      case "arc_approve_sub_deliverable": {
        const { jobId, agentTokenId } = args as {
          jobId: number;
          agentTokenId: number;
        };

        const hash = await client.approveSubDeliverable(
          BigInt(jobId),
          BigInt(agentTokenId),
        );

        // Fetch updated job to show progress
        const job = await client.getOrchestratedJob(BigInt(jobId));

        return {
          content: [
            {
              type: "text",
              text: [
                `Sub-deliverable approved.`,
                ``,
                `Job          : #${jobId}`,
                `Agent        : #${agentTokenId}`,
                `Progress     : ${job.approvedCount}/${job.totalMembers} approved`,
                ``,
                `Transaction  : ${txUrl(hash)}`,
              ].join("\n"),
            },
          ],
        };
      }

      // -----------------------------------------------------------------------
      case "arc_complete_orchestrated_job": {
        const { jobId } = args as { jobId: number };

        const hash = await client.completeOrchestratedJob(BigInt(jobId));

        return {
          content: [
            {
              type: "text",
              text: [
                `Orchestrated job completed. USDC has been distributed to all orchestra members.`,
                ``,
                `Job          : #${jobId}`,
                ``,
                `Transaction  : ${txUrl(hash)}`,
              ].join("\n"),
            },
          ],
        };
      }

      // -----------------------------------------------------------------------
      case "arc_list_orchestras_by_agent": {
        const { agentTokenId } = args as { agentTokenId: number };

        const orchestraIds = await client.getOrchestrasByAgent(BigInt(agentTokenId));

        if (orchestraIds.length === 0) {
          return {
            content: [
              {
                type: "text",
                text: `Agent #${agentTokenId} is not a member of any orchestras.`,
              },
            ],
          };
        }

        const orchestras = await Promise.all(
          orchestraIds.map((id) => client.getOrchestra(id)),
        );

        const lines: string[] = [
          `Orchestras for Agent #${agentTokenId} (${orchestraIds.length} total):`,
          ``,
        ];

        orchestras.forEach((o, i) => {
          const id = orchestraIds[i];
          const isLead = o.leadAgentId === BigInt(agentTokenId);
          const role = isLead ? "Lead" : "Sub-agent";
          const statusLabel = ORCHESTRA_STATUS[o.status as keyof typeof ORCHESTRA_STATUS] ?? "Unknown";
          lines.push(
            `  Orchestra #${id} — "${o.description}"`,
            `    Role: ${role} | Status: ${statusLabel} | Members: ${o.acceptedCount}/${o.memberCount} accepted`,
            ``,
          );
        });

        return {
          content: [{ type: "text", text: lines.join("\n") }],
        };
      }

      // -----------------------------------------------------------------------
      case "arc_dispute_sub_deliverable": {
        const { jobId, agentTokenId, reason } = args as {
          jobId: number;
          agentTokenId: number;
          reason: string;
        };

        const hash = await client.disputeSubDeliverable(
          BigInt(jobId),
          BigInt(agentTokenId),
          reason,
        );

        return {
          content: [
            {
              type: "text",
              text: [
                `Sub-deliverable disputed. Job is now in Disputed status.`,
                ``,
                `Job          : #${jobId}`,
                `Agent        : #${agentTokenId}`,
                `Reason       : "${reason}"`,
                ``,
                `Transaction  : ${txUrl(hash)}`,
              ].join("\n"),
            },
          ],
        };
      }

      // -----------------------------------------------------------------------
      default:
        return {
          content: [{ type: "text", text: `Error: Unknown tool "${name}"` }],
          isError: true,
        };
    }
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return {
      content: [{ type: "text", text: `Error: ${message}` }],
      isError: true,
    };
  }
});

// ---------------------------------------------------------------------------
// Start server
// ---------------------------------------------------------------------------

const transport = new StdioServerTransport();
await server.connect(transport);
