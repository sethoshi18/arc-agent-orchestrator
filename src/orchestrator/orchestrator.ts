/**
 * AgentOrchestratorClient
 *
 * Provides typed methods for interacting with the AgentOrchestrator smart contract
 * on the Arc Testnet. Supports orchestra management, job lifecycle, USDC approvals,
 * and sub-deliverable workflows for multi-agent revenue splitting.
 *
 * Pattern mirrors AgentMarketClient from arc-agent-market.
 */

import {
  createPublicClient,
  createWalletClient,
  http,
  parseAbi,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { config, arcTestnet } from "../config.js";

// ---------------------------------------------------------------------------
// Status label lookup maps
// ---------------------------------------------------------------------------

export const ORCHESTRA_STATUS = {
  0: "Pending",
  1: "Active",
  2: "Disbanded",
} as const;

export const JOB_STATUS = {
  0: "Created",
  1: "InProgress",
  2: "Completed",
  3: "Disputed",
  4: "Cancelled",
} as const;

export const SUBTASK_STATUS = {
  0: "Pending",
  1: "Submitted",
  2: "Approved",
  3: "Disputed",
} as const;

// ---------------------------------------------------------------------------
// ABI definitions (human-readable)
// ---------------------------------------------------------------------------

const orchestratorAbi = parseAbi([
  // Orchestra management
  "function createOrchestra(uint256 leadAgentId, uint256[] subAgentIds, uint256[] splitBps, string description) returns (uint256 orchestraId)",
  "function acceptOrchestraRole(uint256 orchestraId, uint256 agentTokenId)",
  "function disbandOrchestra(uint256 orchestraId)",
  "function getOrchestra(uint256 orchestraId) view returns ((uint256 id, uint256 leadAgentId, string description, uint8 status, uint256 createdAt, uint256 memberCount, uint256 acceptedCount))",
  "function getOrchestraMembers(uint256 orchestraId) view returns ((uint256 agentTokenId, uint256 splitBps, bool accepted)[])",
  "function getOrchestrasByAgent(uint256 agentTokenId) view returns (uint256[])",

  // Job management
  "function createOrchestratedJob(uint256 orchestraId, uint256 totalAmount, string description) returns (uint256 jobId)",
  "function submitSubDeliverable(uint256 jobId, uint256 agentTokenId, bytes32 deliverableHash)",
  "function approveSubDeliverable(uint256 jobId, uint256 agentTokenId)",
  "function disputeSubDeliverable(uint256 jobId, uint256 agentTokenId, string reason)",
  "function completeOrchestratedJob(uint256 jobId)",
  "function cancelOrchestratedJob(uint256 jobId)",
  "function getOrchestratedJob(uint256 jobId) view returns ((uint256 id, uint256 orchestraId, address client, uint256 totalAmount, string description, uint8 status, uint256 createdAt, uint256 completedAt, uint256 approvedCount, uint256 totalMembers))",
  "function getSubTask(uint256 jobId, uint256 agentTokenId) view returns ((bytes32 deliverableHash, uint8 status, uint256 submittedAt))",
  "function getJobsByClient(address client) view returns (uint256[])",
  "function getJobsByOrchestra(uint256 orchestraId) view returns (uint256[])",

  // Events
  "event OrchestraCreated(uint256 indexed orchestraId, uint256 indexed leadAgentId, string description)",
  "event OrchestratedJobCreated(uint256 indexed jobId, uint256 indexed orchestraId, address indexed client, uint256 totalAmount)",
  "event SubDeliverableSubmitted(uint256 indexed jobId, uint256 indexed agentTokenId, bytes32 deliverableHash)",
  "event SubDeliverableApproved(uint256 indexed jobId, uint256 indexed agentTokenId)",
  "event JobCompleted(uint256 indexed jobId, uint256 totalPaid)",
  "event PaymentSplit(uint256 indexed jobId, uint256 indexed agentTokenId, address recipient, uint256 amount)",
  "event JobCancelled(uint256 indexed jobId)",
]);

const erc20Abi = parseAbi([
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
]);

// ---------------------------------------------------------------------------
// Helper: convert human-readable USDC amount to 6-decimal bigint
// ---------------------------------------------------------------------------

function toUsdcUnits(amount: number): bigint {
  return BigInt(Math.round(amount * 1_000_000));
}

// ---------------------------------------------------------------------------
// AgentOrchestratorClient
// ---------------------------------------------------------------------------

export class AgentOrchestratorClient {
  private readonly publicClient;
  private readonly walletClient;
  private readonly account;

  /** Address of the deployed AgentOrchestrator contract. */
  private readonly orchestratorAddress: `0x${string}`;

  constructor() {
    if (!config.wallet.privateKey) {
      throw new Error("AGENT_PRIVATE_KEY is not set in environment");
    }
    if (!config.contracts.agentOrchestrator) {
      throw new Error("AGENT_ORCHESTRATOR_ADDRESS is not set in environment");
    }

    this.account = privateKeyToAccount(config.wallet.privateKey);
    this.orchestratorAddress = config.contracts.agentOrchestrator;

    this.publicClient = createPublicClient({
      chain: arcTestnet,
      transport: http(config.arc.rpcUrl),
    });

    this.walletClient = createWalletClient({
      account: this.account,
      chain: arcTestnet,
      transport: http(config.arc.rpcUrl),
    });
  }

  // -------------------------------------------------------------------------
  // Internal helpers
  // -------------------------------------------------------------------------

  /**
   * Simulate then write a transaction, then wait for receipt.
   * Returns the transaction hash.
   */
  private async sendTx(args: Parameters<typeof this.walletClient.writeContract>[0]): Promise<`0x${string}`> {
    // Simulate first to surface revert reasons before submitting
    await this.publicClient.simulateContract({
      ...args,
      account: this.account,
    } as Parameters<typeof this.publicClient.simulateContract>[0]);

    const hash = await this.walletClient.writeContract(args as Parameters<typeof this.walletClient.writeContract>[0]);
    await this.publicClient.waitForTransactionReceipt({ hash });
    return hash;
  }

  /**
   * Ensure the wallet has approved at least `amount` USDC for the orchestrator.
   * Only sends an approval transaction when the current allowance is insufficient.
   */
  private async ensureUsdcAllowance(amount: bigint): Promise<void> {
    const allowance = await this.publicClient.readContract({
      address: config.contracts.usdc,
      abi: erc20Abi,
      functionName: "allowance",
      args: [this.account.address, this.orchestratorAddress],
    });

    if (allowance >= amount) return;

    console.log(`🔑  Approving ${amount} USDC (6 decimals) for orchestrator…`);
    const hash = await this.sendTx({
      address: config.contracts.usdc,
      abi: erc20Abi,
      functionName: "approve",
      args: [this.orchestratorAddress, amount],
    });
    console.log(`✅  USDC approval confirmed (tx: ${hash})`);
  }

  // -------------------------------------------------------------------------
  // Orchestra management
  // -------------------------------------------------------------------------

  /**
   * Create a new orchestra with a lead agent and one or more sub-agents.
   *
   * @param leadAgentId    Token ID of the lead agent (receives residual bps).
   * @param subAgentIds    Token IDs of sub-agents in the orchestra.
   * @param splitBps       Basis-point allocations matching subAgentIds order.
   *                       The contract typically requires they sum to ≤10000.
   * @param description    Human-readable description of the orchestra's purpose.
   * @returns Object containing the new orchestraId (bigint) and transaction hash.
   */
  async createOrchestra(
    leadAgentId: bigint,
    subAgentIds: bigint[],
    splitBps: number[],
    description: string,
  ): Promise<{ orchestraId: bigint; hash: `0x${string}` }> {
    console.log(`🎻  Creating orchestra — lead: ${leadAgentId}, members: [${subAgentIds.join(", ")}]`);

    const splitBpsBigInt = splitBps.map(BigInt);

    // Simulate to extract the return value (orchestraId)
    const { result: orchestraId } = await this.publicClient.simulateContract({
      address: this.orchestratorAddress,
      abi: orchestratorAbi,
      functionName: "createOrchestra",
      args: [leadAgentId, subAgentIds, splitBpsBigInt, description],
      account: this.account,
    });

    const hash = await this.walletClient.writeContract({
      address: this.orchestratorAddress,
      abi: orchestratorAbi,
      functionName: "createOrchestra",
      args: [leadAgentId, subAgentIds, splitBpsBigInt, description],
    });

    await this.publicClient.waitForTransactionReceipt({ hash });
    console.log(`✅  Orchestra created — id: ${orchestraId}, tx: ${hash}`);
    return { orchestraId, hash };
  }

  /**
   * Accept an orchestra role on behalf of the specified agent.
   *
   * @param orchestraId  ID of the orchestra to join.
   * @param agentTokenId Token ID of the agent accepting the role.
   * @returns Transaction hash.
   */
  async acceptOrchestraRole(orchestraId: bigint, agentTokenId: bigint): Promise<`0x${string}`> {
    console.log(`🤝  Accepting orchestra role — orchestra: ${orchestraId}, agent: ${agentTokenId}`);

    const hash = await this.sendTx({
      address: this.orchestratorAddress,
      abi: orchestratorAbi,
      functionName: "acceptOrchestraRole",
      args: [orchestraId, agentTokenId],
    });

    console.log(`✅  Orchestra role accepted — tx: ${hash}`);
    return hash;
  }

  /**
   * Disband an existing orchestra (lead agent only).
   *
   * @param orchestraId ID of the orchestra to disband.
   * @returns Transaction hash.
   */
  async disbandOrchestra(orchestraId: bigint): Promise<`0x${string}`> {
    console.log(`🔇  Disbanding orchestra ${orchestraId}…`);

    const hash = await this.sendTx({
      address: this.orchestratorAddress,
      abi: orchestratorAbi,
      functionName: "disbandOrchestra",
      args: [orchestraId],
    });

    console.log(`✅  Orchestra disbanded — tx: ${hash}`);
    return hash;
  }

  /**
   * Fetch on-chain metadata for an orchestra.
   *
   * @param orchestraId ID of the orchestra to look up.
   * @returns Orchestra struct data with an additional human-readable `statusLabel`.
   */
  async getOrchestra(orchestraId: bigint) {
    const data = await this.publicClient.readContract({
      address: this.orchestratorAddress,
      abi: orchestratorAbi,
      functionName: "getOrchestra",
      args: [orchestraId],
    });

    return {
      ...data,
      statusLabel: ORCHESTRA_STATUS[data.status as keyof typeof ORCHESTRA_STATUS] ?? "Unknown",
    };
  }

  /**
   * Fetch the member list for an orchestra.
   *
   * @param orchestraId ID of the orchestra.
   * @returns Array of member structs (agentTokenId, splitBps, accepted).
   */
  async getOrchestraMembers(orchestraId: bigint) {
    return this.publicClient.readContract({
      address: this.orchestratorAddress,
      abi: orchestratorAbi,
      functionName: "getOrchestraMembers",
      args: [orchestraId],
    });
  }

  /**
   * Fetch all orchestra IDs that include the given agent.
   *
   * @param agentTokenId Token ID of the agent.
   * @returns Array of orchestra IDs.
   */
  async getOrchestrasByAgent(agentTokenId: bigint): Promise<readonly bigint[]> {
    return this.publicClient.readContract({
      address: this.orchestratorAddress,
      abi: orchestratorAbi,
      functionName: "getOrchestrasByAgent",
      args: [agentTokenId],
    });
  }

  // -------------------------------------------------------------------------
  // Job management
  // -------------------------------------------------------------------------

  /**
   * Create a new orchestrated job and fund it with USDC.
   * Automatically approves the orchestrator to spend USDC if necessary.
   *
   * @param orchestraId      ID of the orchestra that will execute the job.
   * @param totalAmountUsdc  Human-readable USDC amount (e.g. 10.0 for 10 USDC).
   * @param description      Human-readable job description.
   * @returns Object containing the new jobId (bigint) and transaction hash.
   */
  async createOrchestratedJob(
    orchestraId: bigint,
    totalAmountUsdc: number,
    description: string,
  ): Promise<{ jobId: bigint; hash: `0x${string}` }> {
    const totalAmount = toUsdcUnits(totalAmountUsdc);
    console.log(`💼  Creating orchestrated job — orchestra: ${orchestraId}, amount: ${totalAmountUsdc} USDC`);

    // Ensure the orchestrator can pull funds from the caller's wallet
    await this.ensureUsdcAllowance(totalAmount);

    // Simulate to capture the returned jobId
    const { result: jobId } = await this.publicClient.simulateContract({
      address: this.orchestratorAddress,
      abi: orchestratorAbi,
      functionName: "createOrchestratedJob",
      args: [orchestraId, totalAmount, description],
      account: this.account,
    });

    const hash = await this.walletClient.writeContract({
      address: this.orchestratorAddress,
      abi: orchestratorAbi,
      functionName: "createOrchestratedJob",
      args: [orchestraId, totalAmount, description],
    });

    await this.publicClient.waitForTransactionReceipt({ hash });
    console.log(`✅  Orchestrated job created — id: ${jobId}, tx: ${hash}`);
    return { jobId, hash };
  }

  /**
   * Submit a deliverable hash for a sub-task within a job.
   *
   * @param jobId            ID of the orchestrated job.
   * @param agentTokenId     Token ID of the submitting agent.
   * @param deliverableHash  Keccak-256 hash (bytes32) of the deliverable content.
   * @returns Transaction hash.
   */
  async submitSubDeliverable(
    jobId: bigint,
    agentTokenId: bigint,
    deliverableHash: `0x${string}`,
  ): Promise<`0x${string}`> {
    console.log(`📤  Submitting deliverable — job: ${jobId}, agent: ${agentTokenId}`);

    const hash = await this.sendTx({
      address: this.orchestratorAddress,
      abi: orchestratorAbi,
      functionName: "submitSubDeliverable",
      args: [jobId, agentTokenId, deliverableHash],
    });

    console.log(`✅  Deliverable submitted — tx: ${hash}`);
    return hash;
  }

  /**
   * Approve a sub-deliverable, moving the sub-task to Approved status.
   *
   * @param jobId        ID of the orchestrated job.
   * @param agentTokenId Token ID of the agent whose deliverable is being approved.
   * @returns Transaction hash.
   */
  async approveSubDeliverable(jobId: bigint, agentTokenId: bigint): Promise<`0x${string}`> {
    console.log(`👍  Approving deliverable — job: ${jobId}, agent: ${agentTokenId}`);

    const hash = await this.sendTx({
      address: this.orchestratorAddress,
      abi: orchestratorAbi,
      functionName: "approveSubDeliverable",
      args: [jobId, agentTokenId],
    });

    console.log(`✅  Deliverable approved — tx: ${hash}`);
    return hash;
  }

  /**
   * Raise a dispute for a sub-deliverable.
   *
   * @param jobId        ID of the orchestrated job.
   * @param agentTokenId Token ID of the agent whose deliverable is disputed.
   * @param reason       Human-readable reason for the dispute.
   * @returns Transaction hash.
   */
  async disputeSubDeliverable(
    jobId: bigint,
    agentTokenId: bigint,
    reason: string,
  ): Promise<`0x${string}`> {
    console.log(`⚠️   Disputing deliverable — job: ${jobId}, agent: ${agentTokenId}`);

    const hash = await this.sendTx({
      address: this.orchestratorAddress,
      abi: orchestratorAbi,
      functionName: "disputeSubDeliverable",
      args: [jobId, agentTokenId, reason],
    });

    console.log(`✅  Dispute raised — tx: ${hash}`);
    return hash;
  }

  /**
   * Mark an orchestrated job as complete and trigger payment splits.
   *
   * @param jobId ID of the job to complete.
   * @returns Transaction hash.
   */
  async completeOrchestratedJob(jobId: bigint): Promise<`0x${string}`> {
    console.log(`🏁  Completing orchestrated job ${jobId}…`);

    const hash = await this.sendTx({
      address: this.orchestratorAddress,
      abi: orchestratorAbi,
      functionName: "completeOrchestratedJob",
      args: [jobId],
    });

    console.log(`✅  Job completed — tx: ${hash}`);
    return hash;
  }

  /**
   * Cancel an orchestrated job and return funds to the client.
   *
   * @param jobId ID of the job to cancel.
   * @returns Transaction hash.
   */
  async cancelOrchestratedJob(jobId: bigint): Promise<`0x${string}`> {
    console.log(`❌  Cancelling orchestrated job ${jobId}…`);

    const hash = await this.sendTx({
      address: this.orchestratorAddress,
      abi: orchestratorAbi,
      functionName: "cancelOrchestratedJob",
      args: [jobId],
    });

    console.log(`✅  Job cancelled — tx: ${hash}`);
    return hash;
  }

  /**
   * Fetch on-chain metadata for an orchestrated job.
   *
   * @param jobId ID of the job to look up.
   * @returns Job struct data with an additional human-readable `statusLabel`.
   */
  async getOrchestratedJob(jobId: bigint) {
    const data = await this.publicClient.readContract({
      address: this.orchestratorAddress,
      abi: orchestratorAbi,
      functionName: "getOrchestratedJob",
      args: [jobId],
    });

    return {
      ...data,
      statusLabel: JOB_STATUS[data.status as keyof typeof JOB_STATUS] ?? "Unknown",
    };
  }

  /**
   * Fetch the sub-task record for a specific agent within a job.
   *
   * @param jobId        ID of the orchestrated job.
   * @param agentTokenId Token ID of the agent.
   * @returns Sub-task struct with deliverableHash, status, submittedAt, and `statusLabel`.
   */
  async getSubTask(jobId: bigint, agentTokenId: bigint) {
    const data = await this.publicClient.readContract({
      address: this.orchestratorAddress,
      abi: orchestratorAbi,
      functionName: "getSubTask",
      args: [jobId, agentTokenId],
    });

    return {
      ...data,
      statusLabel: SUBTASK_STATUS[data.status as keyof typeof SUBTASK_STATUS] ?? "Unknown",
    };
  }

  /**
   * Fetch all job IDs created by a given client address.
   *
   * @param client Optional client address; defaults to the wallet's own address.
   * @returns Array of job IDs.
   */
  async getJobsByClient(client?: `0x${string}`): Promise<readonly bigint[]> {
    const address = client ?? this.account.address;
    return this.publicClient.readContract({
      address: this.orchestratorAddress,
      abi: orchestratorAbi,
      functionName: "getJobsByClient",
      args: [address],
    });
  }

  /**
   * Fetch all job IDs associated with a given orchestra.
   *
   * @param orchestraId ID of the orchestra.
   * @returns Array of job IDs.
   */
  async getJobsByOrchestra(orchestraId: bigint): Promise<readonly bigint[]> {
    return this.publicClient.readContract({
      address: this.orchestratorAddress,
      abi: orchestratorAbi,
      functionName: "getJobsByOrchestra",
      args: [orchestraId],
    });
  }
}
