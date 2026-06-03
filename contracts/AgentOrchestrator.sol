// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// =============================================================================
// Inline Interfaces
// =============================================================================

/**
 * @title IAgentIdentity
 * @notice Interface for the Arc Agent Identity Registry (Layer 1).
 *         Agents are ERC-721 tokens with on-chain reputation.
 */
interface IAgentIdentity {
    struct AgentIdentity {
        address owner;
        string name;
        string metadataURI;
        uint256 reputation;
        uint256 registeredAt;
        bool active;
    }

    /// @notice Returns the full identity record for a registered agent.
    /// @param tokenId The ERC-721 token ID of the agent.
    function getAgent(uint256 tokenId) external view returns (AgentIdentity memory);

    /// @notice Adjusts the reputation of an agent by a signed basis-point delta.
    /// @param tokenId The ERC-721 token ID of the agent.
    /// @param delta   Positive to increase reputation, negative to decrease.
    function adjustReputation(uint256 tokenId, int256 delta) external;
}

/**
 * @title IERC20
 * @notice Minimal ERC-20 interface used exclusively for USDC interactions.
 */
interface IERC20 {
    /// @notice Transfers `amount` tokens from `from` to `to` using the caller's allowance.
    function transferFrom(address from, address to, uint256 amount) external returns (bool);

    /// @notice Transfers `amount` tokens to `to` from the caller's balance.
    function transfer(address to, uint256 amount) external returns (bool);

    /// @notice Returns the token balance of `account`.
    function balanceOf(address account) external view returns (uint256);
}

// =============================================================================
// AgentOrchestrator
// =============================================================================

/**
 * @title AgentOrchestrator
 * @notice Layer 4 of the Arc agentic-commerce stack.
 *
 * @dev Enables groups of AI agents to form named "Orchestras", take on
 *      client jobs, collaboratively deliver sub-tasks, and automatically
 *      split USDC revenue according to pre-agreed basis-point allocations.
 *
 *      Architecture overview
 *      ─────────────────────
 *      1. A lead agent calls createOrchestra(), specifying sub-agents and
 *         their revenue splits. All splits are expressed in basis points
 *         (bps) where 10 000 bps == 100 %.
 *      2. Each sub-agent's owner calls acceptOrchestraRole() to signal
 *         readiness. Once everyone accepts, the Orchestra becomes Active.
 *      3. A client calls createOrchestratedJob(), which locks USDC in this
 *         contract for the duration of the engagement.
 *      4. Each agent submits its deliverable hash via submitSubDeliverable().
 *         The lead agent (or client) reviews and calls approveSubDeliverable()
 *         or disputeSubDeliverable().
 *      5. Once all sub-tasks are approved the client calls
 *         completeOrchestratedJob(), triggering automatic payment splitting
 *         and reputation adjustments.
 *
 *      Reputation constants (in basis points)
 *      ────────────────────────────────────────
 *      REPUTATION_COMPLETE    +100 bps  awarded to every member on completion
 *      REPUTATION_LEAD_BONUS   +50 bps  additional bonus for the lead agent
 *      REPUTATION_DISPUTE     -200 bps  penalty for a disputed deliverable
 */
contract AgentOrchestrator {
    // =========================================================================
    // Constants
    // =========================================================================

    /// @notice Arc's native gas token exposed via an ERC-20 interface (6 decimals).
    address public constant USDC = 0x3600000000000000000000000000000000000000;

    /// @notice Reputation boost awarded to every orchestra member upon job completion.
    int256 public constant REPUTATION_COMPLETE = 100;

    /// @notice Extra reputation bonus awarded exclusively to the lead agent on completion.
    int256 public constant REPUTATION_LEAD_BONUS = 50;

    /// @notice Reputation penalty applied when a sub-deliverable is disputed.
    int256 public constant REPUTATION_DISPUTE = -200;

    // =========================================================================
    // Enums
    // =========================================================================

    /**
     * @notice Lifecycle states of an Orchestra.
     *
     * Pending   – Created; waiting for all sub-agents to accept their roles.
     * Active    – All members accepted; can accept jobs.
     * Disbanded – Lead agent dissolved the orchestra; no new jobs allowed.
     */
    enum OrchestraStatus {
        Pending,
        Active,
        Disbanded
    }

    /**
     * @notice Lifecycle states of an OrchestratedJob.
     *
     * Created    – Reserved for future use / off-chain staging.
     * InProgress – USDC locked; agents are working.
     * Completed  – All sub-tasks approved; payments distributed.
     * Disputed   – At least one sub-task was disputed.
     * Cancelled  – Client cancelled; USDC refunded.
     */
    enum OrchestratedJobStatus {
        Created,
        InProgress,
        Completed,
        Disputed,
        Cancelled
    }

    /**
     * @notice Lifecycle states of an individual sub-task.
     *
     * Pending   – Not yet submitted by the assigned agent.
     * Submitted – Deliverable hash stored; awaiting lead review.
     * Approved  – Lead agent approved; counts toward job completion.
     * Disputed  – Lead or client flagged the deliverable.
     */
    enum SubTaskStatus {
        Pending,
        Submitted,
        Approved,
        Disputed
    }

    // =========================================================================
    // Structs
    // =========================================================================

    /**
     * @notice Represents a single agent's membership in an Orchestra.
     * @param agentTokenId ERC-721 token ID of the agent.
     * @param splitBps     Revenue share in basis points (1 bps = 0.01 %).
     * @param accepted     Whether this agent has accepted its role.
     */
    struct OrchestraMember {
        uint256 agentTokenId;
        uint256 splitBps;
        bool accepted;
    }

    /**
     * @notice Top-level record for an Orchestra (a standing team of agents).
     * @param id            Auto-incremented unique identifier.
     * @param leadAgentId   Token ID of the lead/orchestrator agent.
     * @param description   Human-readable purpose of the orchestra.
     * @param status        Current lifecycle status.
     * @param createdAt     Block timestamp of creation.
     * @param memberCount   Total number of members (lead + sub-agents).
     * @param acceptedCount How many members have accepted their roles so far.
     */
    struct Orchestra {
        uint256 id;
        uint256 leadAgentId;
        string description;
        OrchestraStatus status;
        uint256 createdAt;
        uint256 memberCount;
        uint256 acceptedCount;
    }

    /**
     * @notice Represents a single agent's deliverable within a job.
     * @param deliverableHash Keccak-256 hash of the off-chain deliverable.
     * @param status          Current lifecycle status of this sub-task.
     * @param submittedAt     Block timestamp when the deliverable was submitted.
     */
    struct SubTask {
        bytes32 deliverableHash;
        SubTaskStatus status;
        uint256 submittedAt;
    }

    /**
     * @notice A client-commissioned job executed by an Active Orchestra.
     * @param id           Auto-incremented unique identifier.
     * @param orchestraId  Orchestra assigned to this job.
     * @param client       Address that funded and owns this job.
     * @param totalAmount  USDC locked for distribution (6-decimal precision).
     * @param description  Human-readable job specification.
     * @param status       Current lifecycle status.
     * @param createdAt    Block timestamp of job creation.
     * @param completedAt  Block timestamp when the job was completed (0 if not yet).
     * @param approvedCount Number of sub-tasks that have been approved so far.
     * @param totalMembers  Total members in the orchestra at job creation time.
     */
    struct OrchestratedJob {
        uint256 id;
        uint256 orchestraId;
        address client;
        uint256 totalAmount;
        string description;
        OrchestratedJobStatus status;
        uint256 createdAt;
        uint256 completedAt;
        uint256 approvedCount;
        uint256 totalMembers;
    }

    // =========================================================================
    // State Variables
    // =========================================================================

    /// @notice Reference to the Arc Agent Identity Registry (Layer 1).
    IAgentIdentity public immutable identityRegistry;

    /// @notice USDC token contract (Arc native gas token with ERC-20 interface).
    IERC20 private immutable _usdc;

    /// @notice Protocol owner (reserved for future governance or fee collection).
    address public owner;

    /// @dev Auto-incrementing counter for orchestra IDs; starts at 1.
    uint256 private _nextOrchestraId;

    /// @dev Auto-incrementing counter for job IDs; starts at 1.
    uint256 private _nextJobId;

    /// @notice Primary storage for orchestras keyed by orchestraId.
    mapping(uint256 => Orchestra) public orchestras;

    /**
     * @notice Ordered list of OrchestraMember records for each orchestra.
     * @dev Index 0 is always the lead agent.
     */
    mapping(uint256 => OrchestraMember[]) public orchestraMembers;

    /**
     * @notice Reverse-lookup: orchestraId → agentTokenId → (1-based index into orchestraMembers).
     * @dev A value of 0 means the agent is not a member of that orchestra.
     *      Subtract 1 to obtain the real array index.
     */
    mapping(uint256 => mapping(uint256 => uint256)) public memberIndex;

    /// @notice Primary storage for jobs keyed by jobId.
    mapping(uint256 => OrchestratedJob) public jobs;

    /**
     * @notice Sub-task records for each (job, agent) pair.
     * @dev Keyed as subTasks[jobId][agentTokenId].
     */
    mapping(uint256 => mapping(uint256 => SubTask)) public subTasks;

    /// @notice All orchestra IDs that a given agent has joined.
    mapping(uint256 => uint256[]) public orchestrasByAgent;

    /// @notice All job IDs initiated by a given client address.
    mapping(address => uint256[]) public jobsByClient;

    /// @notice All job IDs assigned to a given orchestra.
    mapping(uint256 => uint256[]) public jobsByOrchestra;

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted when a new orchestra is created.
    event OrchestraCreated(
        uint256 indexed orchestraId,
        uint256 indexed leadAgentId,
        string description
    );

    /// @notice Emitted when a sub-agent accepts their orchestra role.
    event MemberAccepted(uint256 indexed orchestraId, uint256 indexed agentTokenId);

    /// @notice Emitted when all members have accepted and the orchestra goes Active.
    event OrchestraActivated(uint256 indexed orchestraId);

    /// @notice Emitted when the lead agent disbands an orchestra.
    event OrchestraDisbanded(uint256 indexed orchestraId);

    /// @notice Emitted when a client creates and funds a new job.
    event OrchestratedJobCreated(
        uint256 indexed jobId,
        uint256 indexed orchestraId,
        address indexed client,
        uint256 totalAmount
    );

    /// @notice Emitted when an agent submits its deliverable hash.
    event SubDeliverableSubmitted(
        uint256 indexed jobId,
        uint256 indexed agentTokenId,
        bytes32 deliverableHash
    );

    /// @notice Emitted when the lead agent approves a sub-deliverable.
    event SubDeliverableApproved(uint256 indexed jobId, uint256 indexed agentTokenId);

    /// @notice Emitted when a sub-deliverable is disputed.
    event SubDeliverableDisputed(
        uint256 indexed jobId,
        uint256 indexed agentTokenId,
        string reason
    );

    /// @notice Emitted when a job is completed and all payments are distributed.
    event JobCompleted(uint256 indexed jobId, uint256 totalPaid);

    /// @notice Emitted for each individual payment within a job completion.
    event PaymentSplit(
        uint256 indexed jobId,
        uint256 indexed agentTokenId,
        address recipient,
        uint256 amount
    );

    /// @notice Emitted when a client cancels a job and receives a refund.
    event JobCancelled(uint256 indexed jobId);

    // =========================================================================
    // Constructor
    // =========================================================================

    /**
     * @notice Deploys the AgentOrchestrator and wires up dependencies.
     * @param _identityRegistry Address of the Arc Agent Identity Registry.
     * @param usdcAddress       Address of the USDC (ERC-20) contract.
     *                          Pass address(0) to use the canonical Arc constant.
     */
    constructor(address _identityRegistry, address usdcAddress) {
        require(
            _identityRegistry != address(0),
            "AgentOrchestrator: identity registry cannot be zero address"
        );

        identityRegistry = IAgentIdentity(_identityRegistry);

        // Allow the deployer to override the USDC address for testing while
        // defaulting to the Arc canonical constant when address(0) is passed.
        address resolvedUsdc = usdcAddress == address(0) ? USDC : usdcAddress;
        _usdc = IERC20(resolvedUsdc);

        owner = msg.sender;

        // IDs start at 1 so that a mapping returning 0 unambiguously means
        // "not found".
        _nextOrchestraId = 1;
        _nextJobId = 1;
    }

    // =========================================================================
    // Internal Helpers
    // =========================================================================

    /**
     * @dev Fetches the identity of an agent and reverts if not found / inactive.
     * @param tokenId The ERC-721 token ID of the agent.
     * @return identity The full AgentIdentity record.
     */
    function _requireActiveAgent(uint256 tokenId)
        internal
        view
        returns (IAgentIdentity.AgentIdentity memory identity)
    {
        identity = identityRegistry.getAgent(tokenId);
        require(
            identity.registeredAt != 0,
            "AgentOrchestrator: agent does not exist"
        );
        require(identity.active, "AgentOrchestrator: agent is not active");
    }

    /**
     * @dev Reverts if `msg.sender` is not the owner of the given agent.
     * @param tokenId  The agent to check ownership of.
     * @param identity Pre-fetched identity record (avoids redundant external calls).
     */
    function _requireAgentOwner(
        uint256 tokenId,
        IAgentIdentity.AgentIdentity memory identity
    ) internal view {
        require(
            identity.owner == msg.sender,
            "AgentOrchestrator: caller does not own agent"
        );
        // Suppress unused-variable warning — tokenId used for contextual clarity.
        tokenId;
    }

    /**
     * @dev Returns the lead agent's owner address for a given orchestra.
     */
    function _leadOwner(uint256 orchestraId) internal view returns (address) {
        uint256 leadId = orchestras[orchestraId].leadAgentId;
        return identityRegistry.getAgent(leadId).owner;
    }

    /**
     * @dev Checks whether any jobs associated with `orchestraId` are still
     *      in an active (non-terminal) state.
     * @return hasActive True if at least one job is InProgress or Disputed.
     */
    function _hasActiveJobs(uint256 orchestraId) internal view returns (bool hasActive) {
        uint256[] storage jobIds = jobsByOrchestra[orchestraId];
        uint256 len = jobIds.length;
        for (uint256 i = 0; i < len; ) {
            OrchestratedJobStatus s = jobs[jobIds[i]].status;
            if (s == OrchestratedJobStatus.InProgress || s == OrchestratedJobStatus.Disputed) {
                return true;
            }
            unchecked { ++i; }
        }
        return false;
    }

    // =========================================================================
    // Orchestra Management
    // =========================================================================

    /**
     * @notice Creates a new Orchestra with the caller's agent as the lead.
     *
     * @dev The lead agent is automatically added as an accepted member.
     *      Sub-agents must subsequently call acceptOrchestraRole().
     *      If there are no sub-agents, the orchestra immediately becomes Active.
     *
     * @param leadAgentId  Token ID of the lead/orchestrator agent (must be owned by caller).
     * @param subAgentIds  Token IDs of sub-agents to invite (can be empty).
     * @param splitBps     Revenue splits in basis points. Length must equal
     *                     1 + subAgentIds.length. First element is the lead's split.
     *                     All elements must be > 0 and sum to exactly 10 000.
     * @param description  Human-readable description of the orchestra's purpose.
     * @return orchestraId The newly assigned orchestra ID.
     */
    function createOrchestra(
        uint256 leadAgentId,
        uint256[] calldata subAgentIds,
        uint256[] calldata splitBps,
        string calldata description
    ) external returns (uint256 orchestraId) {
        // ── Validate lead agent ──────────────────────────────────────────────
        IAgentIdentity.AgentIdentity memory leadIdentity = _requireActiveAgent(leadAgentId);
        _requireAgentOwner(leadAgentId, leadIdentity);

        // ── Validate splits array length ─────────────────────────────────────
        uint256 subCount = subAgentIds.length;
        require(
            splitBps.length == subCount + 1,
            "AgentOrchestrator: splitBps length must equal 1 + subAgentIds.length"
        );

        // ── Validate split values ────────────────────────────────────────────
        uint256 totalBps;
        for (uint256 i = 0; i < splitBps.length; ) {
            require(splitBps[i] > 0, "AgentOrchestrator: each split must be greater than zero");
            totalBps += splitBps[i];
            unchecked { ++i; }
        }
        require(totalBps == 10_000, "AgentOrchestrator: splits must sum to 10000 bps");

        // ── Validate sub-agents ───────────────────────────────────────────────
        for (uint256 i = 0; i < subCount; ) {
            require(
                subAgentIds[i] != leadAgentId,
                "AgentOrchestrator: sub-agent cannot be the same as lead agent"
            );
            _requireActiveAgent(subAgentIds[i]);

            // Check for duplicates within the sub-agent list.
            for (uint256 j = 0; j < i; ) {
                require(
                    subAgentIds[i] != subAgentIds[j],
                    "AgentOrchestrator: duplicate sub-agent in list"
                );
                unchecked { ++j; }
            }
            unchecked { ++i; }
        }

        // ── Assign orchestra ID ───────────────────────────────────────────────
        orchestraId = _nextOrchestraId++;

        // ── Determine initial status ──────────────────────────────────────────
        // If there are no sub-agents the lead is the sole member and the
        // orchestra is immediately Active.
        OrchestraStatus initialStatus = (subCount == 0)
            ? OrchestraStatus.Active
            : OrchestraStatus.Pending;

        uint256 totalMembers = subCount + 1;

        // ── Persist orchestra record ──────────────────────────────────────────
        orchestras[orchestraId] = Orchestra({
            id: orchestraId,
            leadAgentId: leadAgentId,
            description: description,
            status: initialStatus,
            createdAt: block.timestamp,
            memberCount: totalMembers,
            acceptedCount: 1 // lead is pre-accepted
        });

        // ── Add lead as first member (auto-accepted, index 0) ─────────────────
        orchestraMembers[orchestraId].push(
            OrchestraMember({
                agentTokenId: leadAgentId,
                splitBps: splitBps[0],
                accepted: true
            })
        );
        // memberIndex stores 1-based index; 0 means "not a member".
        memberIndex[orchestraId][leadAgentId] = 1;
        orchestrasByAgent[leadAgentId].push(orchestraId);

        // ── Add sub-agents (not yet accepted) ────────────────────────────────
        for (uint256 i = 0; i < subCount; ) {
            uint256 subId = subAgentIds[i];
            orchestraMembers[orchestraId].push(
                OrchestraMember({
                    agentTokenId: subId,
                    splitBps: splitBps[i + 1],
                    accepted: false
                })
            );
            // Array has length (i + 2) after the push; 1-based index is (i + 2).
            memberIndex[orchestraId][subId] = i + 2;
            orchestrasByAgent[subId].push(orchestraId);
            unchecked { ++i; }
        }

        // ── Emit events ───────────────────────────────────────────────────────
        emit OrchestraCreated(orchestraId, leadAgentId, description);

        if (initialStatus == OrchestraStatus.Active) {
            emit OrchestraActivated(orchestraId);
        }
    }

    /**
     * @notice A sub-agent owner accepts their membership in a Pending orchestra.
     *
     * @dev Once all members have accepted, the orchestra automatically transitions
     *      to Active status and the OrchestraActivated event is emitted.
     *
     * @param orchestraId  The ID of the orchestra to join.
     * @param agentTokenId The token ID of the accepting agent.
     */
    function acceptOrchestraRole(uint256 orchestraId, uint256 agentTokenId) external {
        Orchestra storage orch = orchestras[orchestraId];

        require(
            orch.id != 0,
            "AgentOrchestrator: orchestra does not exist"
        );
        require(
            orch.status == OrchestraStatus.Pending,
            "AgentOrchestrator: orchestra is not in Pending status"
        );

        // ── Verify membership ─────────────────────────────────────────────────
        uint256 idx1 = memberIndex[orchestraId][agentTokenId];
        require(idx1 != 0, "AgentOrchestrator: agent is not a member of this orchestra");

        OrchestraMember storage member = orchestraMembers[orchestraId][idx1 - 1];
        require(!member.accepted, "AgentOrchestrator: agent has already accepted this role");

        // ── Verify ownership ──────────────────────────────────────────────────
        IAgentIdentity.AgentIdentity memory identity = _requireActiveAgent(agentTokenId);
        _requireAgentOwner(agentTokenId, identity);

        // ── Accept ────────────────────────────────────────────────────────────
        member.accepted = true;
        orch.acceptedCount++;

        emit MemberAccepted(orchestraId, agentTokenId);

        // ── Activate if all accepted ──────────────────────────────────────────
        if (orch.acceptedCount == orch.memberCount) {
            orch.status = OrchestraStatus.Active;
            emit OrchestraActivated(orchestraId);
        }
    }

    /**
     * @notice Disbands an orchestra, preventing it from accepting new jobs.
     *
     * @dev Only the lead agent's owner may disband. Disbanding is blocked while
     *      any job is still InProgress or Disputed.
     *
     * @param orchestraId The ID of the orchestra to disband.
     */
    function disbandOrchestra(uint256 orchestraId) external {
        Orchestra storage orch = orchestras[orchestraId];

        require(orch.id != 0, "AgentOrchestrator: orchestra does not exist");
        require(
            orch.status != OrchestraStatus.Disbanded,
            "AgentOrchestrator: orchestra is already disbanded"
        );

        // ── Only lead agent owner ─────────────────────────────────────────────
        require(
            msg.sender == _leadOwner(orchestraId),
            "AgentOrchestrator: caller is not the lead agent owner"
        );

        // ── No active jobs ────────────────────────────────────────────────────
        require(
            !_hasActiveJobs(orchestraId),
            "AgentOrchestrator: orchestra has active jobs and cannot be disbanded"
        );

        orch.status = OrchestraStatus.Disbanded;
        emit OrchestraDisbanded(orchestraId);
    }

    // =========================================================================
    // Job Lifecycle
    // =========================================================================

    /**
     * @notice Creates a new job and locks USDC payment in this contract.
     *
     * @dev The orchestra must be Active. The caller (client) must have approved
     *      at least `totalAmount` USDC to this contract beforehand.
     *      The job is created with InProgress status — no separate "activate"
     *      step is required; agents can submit deliverables immediately.
     *
     * @param orchestraId  The Active orchestra that will execute this job.
     * @param totalAmount  USDC amount (6-decimal) to lock for payment.
     * @param description  Human-readable specification of the work required.
     * @return jobId       The newly assigned job ID.
     */
    function createOrchestratedJob(
        uint256 orchestraId,
        uint256 totalAmount,
        string calldata description
    ) external returns (uint256 jobId) {
        Orchestra storage orch = orchestras[orchestraId];

        require(orch.id != 0, "AgentOrchestrator: orchestra does not exist");
        require(
            orch.status == OrchestraStatus.Active,
            "AgentOrchestrator: orchestra is not Active"
        );
        require(totalAmount > 0, "AgentOrchestrator: totalAmount must be greater than zero");

        // ── Lock USDC from client ─────────────────────────────────────────────
        bool transferred = _usdc.transferFrom(msg.sender, address(this), totalAmount);
        require(transferred, "AgentOrchestrator: USDC transferFrom failed");

        // ── Assign job ID ─────────────────────────────────────────────────────
        jobId = _nextJobId++;

        // ── Persist job ───────────────────────────────────────────────────────
        jobs[jobId] = OrchestratedJob({
            id: jobId,
            orchestraId: orchestraId,
            client: msg.sender,
            totalAmount: totalAmount,
            description: description,
            status: OrchestratedJobStatus.InProgress,
            createdAt: block.timestamp,
            completedAt: 0,
            approvedCount: 0,
            totalMembers: orch.memberCount
        });

        // ── Index by client and orchestra ─────────────────────────────────────
        jobsByClient[msg.sender].push(jobId);
        jobsByOrchestra[orchestraId].push(jobId);

        emit OrchestratedJobCreated(jobId, orchestraId, msg.sender, totalAmount);
    }

    /**
     * @notice An agent submits its deliverable hash for a specific job.
     *
     * @dev The agent must be an orchestra member and the sub-task must still
     *      be in Pending status (i.e., not yet submitted or re-submitted).
     *      Deliverable content lives off-chain; only its keccak-256 hash is
     *      stored for integrity verification.
     *
     * @param jobId           The job being worked on.
     * @param agentTokenId    The submitting agent's token ID.
     * @param deliverableHash keccak-256 hash of the off-chain deliverable.
     */
    function submitSubDeliverable(
        uint256 jobId,
        uint256 agentTokenId,
        bytes32 deliverableHash
    ) external {
        OrchestratedJob storage job = jobs[jobId];

        require(job.id != 0, "AgentOrchestrator: job does not exist");
        require(
            job.status == OrchestratedJobStatus.InProgress,
            "AgentOrchestrator: job is not InProgress"
        );

        // ── Verify agent is an orchestra member ───────────────────────────────
        uint256 orchId = job.orchestraId;
        require(
            memberIndex[orchId][agentTokenId] != 0,
            "AgentOrchestrator: agent is not a member of the job's orchestra"
        );

        // ── Verify caller owns the agent ──────────────────────────────────────
        IAgentIdentity.AgentIdentity memory identity = _requireActiveAgent(agentTokenId);
        _requireAgentOwner(agentTokenId, identity);

        // ── Sub-task must be Pending ──────────────────────────────────────────
        SubTask storage task = subTasks[jobId][agentTokenId];
        require(
            task.status == SubTaskStatus.Pending,
            "AgentOrchestrator: sub-task is not in Pending status"
        );

        // ── Record deliverable ────────────────────────────────────────────────
        task.deliverableHash = deliverableHash;
        task.status = SubTaskStatus.Submitted;
        task.submittedAt = block.timestamp;

        emit SubDeliverableSubmitted(jobId, agentTokenId, deliverableHash);
    }

    /**
     * @notice The lead agent owner approves a submitted sub-deliverable.
     *
     * @dev Only the lead agent's owner may approve. The sub-task must be in
     *      Submitted status. Each approval increments the job's approvedCount,
     *      which is checked during completeOrchestratedJob().
     *
     * @param jobId        The job containing the sub-task.
     * @param agentTokenId The agent whose deliverable is being approved.
     */
    function approveSubDeliverable(uint256 jobId, uint256 agentTokenId) external {
        OrchestratedJob storage job = jobs[jobId];

        require(job.id != 0, "AgentOrchestrator: job does not exist");
        require(
            job.status == OrchestratedJobStatus.InProgress,
            "AgentOrchestrator: job is not InProgress"
        );

        // ── Only lead agent owner ─────────────────────────────────────────────
        require(
            msg.sender == _leadOwner(job.orchestraId),
            "AgentOrchestrator: caller is not the lead agent owner"
        );

        // ── Sub-task must be Submitted ────────────────────────────────────────
        SubTask storage task = subTasks[jobId][agentTokenId];
        require(
            task.status == SubTaskStatus.Submitted,
            "AgentOrchestrator: sub-task is not in Submitted status"
        );

        task.status = SubTaskStatus.Approved;
        job.approvedCount++;

        emit SubDeliverableApproved(jobId, agentTokenId);
    }

    /**
     * @notice Disputes a sub-deliverable, flagging the job as Disputed.
     *
     * @dev Either the lead agent's owner or the client may raise a dispute.
     *      The sub-task may be in Submitted or Pending status (to allow
     *      disputing a missed deliverable). The disputed agent receives a
     *      reputation penalty.
     *
     * @param jobId        The job containing the sub-task.
     * @param agentTokenId The agent whose deliverable is being disputed.
     * @param reason       Human-readable explanation of the dispute.
     */
    function disputeSubDeliverable(
        uint256 jobId,
        uint256 agentTokenId,
        string calldata reason
    ) external {
        OrchestratedJob storage job = jobs[jobId];

        require(job.id != 0, "AgentOrchestrator: job does not exist");
        require(
            job.status == OrchestratedJobStatus.InProgress,
            "AgentOrchestrator: job is not InProgress"
        );

        // ── Only lead agent owner or client ───────────────────────────────────
        address leadOwnerAddr = _leadOwner(job.orchestraId);
        require(
            msg.sender == leadOwnerAddr || msg.sender == job.client,
            "AgentOrchestrator: caller is not the lead agent owner or client"
        );

        // ── Sub-task must be Submitted or Pending ─────────────────────────────
        SubTask storage task = subTasks[jobId][agentTokenId];
        require(
            task.status == SubTaskStatus.Submitted || task.status == SubTaskStatus.Pending,
            "AgentOrchestrator: sub-task cannot be disputed in its current status"
        );

        // ── Mark sub-task and job as Disputed ─────────────────────────────────
        task.status = SubTaskStatus.Disputed;
        job.status = OrchestratedJobStatus.Disputed;

        // ── Penalize agent reputation ─────────────────────────────────────────
        identityRegistry.adjustReputation(agentTokenId, REPUTATION_DISPUTE);

        emit SubDeliverableDisputed(jobId, agentTokenId, reason);
    }

    /**
     * @notice Finalizes the job, distributes USDC, and boosts agent reputations.
     *
     * @dev Requirements:
     *      - Job must be InProgress.
     *      - All sub-tasks must be in Approved status (approvedCount == totalMembers).
     *      - Only the client may trigger finalization.
     *
     *      Payment distribution:
     *        payout_i = (totalAmount * splitBps_i) / 10 000
     *      Payments are sent to each agent's current owner address.
     *
     *      Any dust from integer division is NOT redistributed; it remains in
     *      the contract (available to future governance). The `totalPaid` in
     *      JobCompleted reflects the actual sum transferred.
     *
     * @param jobId The job to complete.
     */
    function completeOrchestratedJob(uint256 jobId) external {
        OrchestratedJob storage job = jobs[jobId];

        require(job.id != 0, "AgentOrchestrator: job does not exist");
        require(
            job.status == OrchestratedJobStatus.InProgress,
            "AgentOrchestrator: job is not InProgress"
        );
        require(
            job.approvedCount == job.totalMembers,
            "AgentOrchestrator: not all sub-deliverables have been approved"
        );
        require(msg.sender == job.client, "AgentOrchestrator: caller is not the client");

        // ── Mark complete before transfers (checks-effects-interactions) ───────
        job.status = OrchestratedJobStatus.Completed;
        job.completedAt = block.timestamp;

        uint256 orchId = job.orchestraId;
        OrchestraMember[] storage members = orchestraMembers[orchId];
        uint256 memberCount = members.length;
        uint256 leadId = orchestras[orchId].leadAgentId;
        uint256 totalPaid;

        // ── Distribute payments and boost reputations ─────────────────────────
        for (uint256 i = 0; i < memberCount; ) {
            OrchestraMember storage m = members[i];
            uint256 agentId = m.agentTokenId;
            uint256 payout = (job.totalAmount * m.splitBps) / 10_000;

            if (payout > 0) {
                // Fetch current owner — agent ownership may have transferred.
                address recipient = identityRegistry.getAgent(agentId).owner;
                bool ok = _usdc.transfer(recipient, payout);
                require(ok, "AgentOrchestrator: USDC transfer failed");
                totalPaid += payout;

                emit PaymentSplit(jobId, agentId, recipient, payout);
            }

            // Reputation: base boost for all members, extra for the lead.
            identityRegistry.adjustReputation(agentId, REPUTATION_COMPLETE);
            if (agentId == leadId) {
                identityRegistry.adjustReputation(agentId, REPUTATION_LEAD_BONUS);
            }

            unchecked { ++i; }
        }

        emit JobCompleted(jobId, totalPaid);
    }

    /**
     * @notice Cancels a job and refunds the full USDC amount to the client.
     *
     * @dev Only the client may cancel. Cancellation is allowed when the job
     *      is InProgress (including Disputed, since job.status is set to
     *      Disputed on a dispute — callers should check for both).
     *
     *      Note: `Disputed` status is a sub-state that occurs while the job
     *      is still nominally in progress. Allowing cancellation from Disputed
     *      gives the client an exit path when a dispute cannot be resolved.
     *
     * @param jobId The job to cancel.
     */
    function cancelOrchestratedJob(uint256 jobId) external {
        OrchestratedJob storage job = jobs[jobId];

        require(job.id != 0, "AgentOrchestrator: job does not exist");
        require(
            job.status == OrchestratedJobStatus.InProgress ||
            job.status == OrchestratedJobStatus.Disputed,
            "AgentOrchestrator: job cannot be cancelled in its current status"
        );
        require(msg.sender == job.client, "AgentOrchestrator: caller is not the client");

        // ── Mark cancelled before transfer (checks-effects-interactions) ───────
        job.status = OrchestratedJobStatus.Cancelled;

        // ── Refund full amount to client ──────────────────────────────────────
        bool ok = _usdc.transfer(job.client, job.totalAmount);
        require(ok, "AgentOrchestrator: USDC refund transfer failed");

        emit JobCancelled(jobId);
    }

    // =========================================================================
    // View Functions
    // =========================================================================

    /**
     * @notice Returns the full Orchestra record for a given ID.
     * @param orchestraId The orchestra to query.
     * @return The Orchestra struct (reverts implicitly if ID is 0 / never created,
     *         returning a zero-value struct — callers should check `id != 0`).
     */
    function getOrchestra(uint256 orchestraId) external view returns (Orchestra memory) {
        return orchestras[orchestraId];
    }

    /**
     * @notice Returns the ordered array of OrchestraMember records for an orchestra.
     * @dev Index 0 is always the lead agent.
     * @param orchestraId The orchestra to query.
     * @return Array of OrchestraMember structs.
     */
    function getOrchestraMembers(uint256 orchestraId)
        external
        view
        returns (OrchestraMember[] memory)
    {
        return orchestraMembers[orchestraId];
    }

    /**
     * @notice Returns the full OrchestratedJob record for a given ID.
     * @param jobId The job to query.
     */
    function getOrchestratedJob(uint256 jobId) external view returns (OrchestratedJob memory) {
        return jobs[jobId];
    }

    /**
     * @notice Returns the SubTask record for a specific (job, agent) pair.
     * @param jobId        The job ID.
     * @param agentTokenId The agent whose sub-task to retrieve.
     */
    function getSubTask(uint256 jobId, uint256 agentTokenId)
        external
        view
        returns (SubTask memory)
    {
        return subTasks[jobId][agentTokenId];
    }

    /**
     * @notice Returns all orchestra IDs that a given agent belongs to.
     * @param agentTokenId The agent to query.
     */
    function getOrchestrasByAgent(uint256 agentTokenId)
        external
        view
        returns (uint256[] memory)
    {
        return orchestrasByAgent[agentTokenId];
    }

    /**
     * @notice Returns all job IDs created by a given client address.
     * @param client The client address to query.
     */
    function getJobsByClient(address client) external view returns (uint256[] memory) {
        return jobsByClient[client];
    }

    /**
     * @notice Returns all job IDs assigned to a given orchestra.
     * @param orchestraId The orchestra to query.
     */
    function getJobsByOrchestra(uint256 orchestraId) external view returns (uint256[] memory) {
        return jobsByOrchestra[orchestraId];
    }
}
