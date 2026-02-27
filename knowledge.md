# Canton Protocol — Deep Technical Knowledge Base

> Verified against Canton 3.4.11 (latest release: Feb 16, 2026) and docs.digitalasset.com 3.4/3.5 documentation.
> Last updated: 2026-02-25

---

## 1. Terminology (Canton 3.x, as of 2026)

| Deprecated Term | Current Term (3.x) | Notes |
|---|---|---|
| Domain / Sync Domain | **Synchronizer** | Canonical in all 3.x docs |
| Domain Topology Manager | **Synchronizer Manager** | Sub-component of synchronizer |
| Transfer / Transfer-out / Transfer-in | **Reassignment** / Unassignment / Assignment | Cross-synchronizer contract movement |
| Application ID | **User ID** | In Ledger API v2 |
| `domain_id` | `synchronizer_id` | In proto messages |
| `event_id` | `offset` + `node_id` | Split in v2 |
| Participant Node | **Validator Node** (network-level) / **Participant** (protocol-level) | Both valid; context-dependent |

---

## 2. Architecture Overview

### 2.1 Participant (Validator) Node — Internal Components

A participant is a JVM/Scala process backed by **PostgreSQL** (only supported production DB in 3.x; Oracle/H2 dropped).

| Component | Role |
|---|---|
| **Daml Execution Engine** | Interprets Daml-LF, creates/exercises/archives contracts deterministically |
| **Private Contract Store (PCS)** | Stores decrypted contracts with full payload; only stakeholder participants retain data |
| **Active Contract Journal (ACJ)** | Tracks contract status (active/archived/locked) per synchronizer connection |
| **Sync Service / SyncDomain** | Per-synchronizer connection manager; drives protocol processing pipeline |
| **Sequencer Client** (`SequencerClient`) | gRPC connection to synchronizer's sequencer; handles subscription, reconnection, failover |
| **Identity Client** | Processes topology transactions, verifies identity changes from synchronizer |
| **MessageDispatcher** | Routes incoming sequenced messages to appropriate protocol processor |
| **TransactionProcessor** (`Phase37Processor`) | Handles confirmation requests through commit protocol phases |
| **ConflictDetector / ContractStateManager** | In-flight activeness checks, contract locking |
| **RecordOrderPublisher** | Ensures events are emitted to Ledger API in sequencer-timestamp order |
| **Ledger API Server** | Exposes gRPC Ledger API to client applications |
| **Multi-Sync-Domain Event Log** | Merged ordering of events from all connected synchronizers |

### 2.2 Synchronizer — Three Sub-Components

#### Sequencer

Provides **global total-order multicast**:
- Events are uniquely timestamped with monotonically growing timestamps
- All members derive global ordering from these timestamps
- Message contents are encrypted — sequencer cannot decrypt or inspect payloads
- Provides cryptographic proof of authenticity for every message batch
- Sender identity is anonymous to recipients (except co-recipients on shared messages)

gRPC services exposed:
1. `SequencerConnectService` — version handshake, service discovery
2. `SequencerAuthenticationService` — challenge-response auth yielding access token
3. `SequencerService` — main message send/subscribe service

Sequencer store persists: all processed messages, subscription status, topology snapshots, previous timestamps per member, BFT ordering blocks (when using BFT Orderer), authentication keys.

Enterprise variants support alternative backends: Oracle, Hyperledger Fabric, Ethereum for blockchain-based sequencing.

**BFT Sequencer**: Shipped and live on the Global Synchronizer since July 2024. Uses 2/3 majority Byzantine Fault Tolerant consensus. Operated by Super Validator Collective (SVC).

#### Mediator

Acts as **transaction commit coordinator**:
- Registers new transaction requests
- Collects `ConfirmationResponse` messages from validating participants
- Computes final verdict (Approve / MediatorReject / Timeout) using quorum-based confirmation policy
- Distributes `ConfirmationResultMessage` to all informees
- Provides privacy between stakeholders (they never communicate directly)
- Persists every received message for auditability

Mediator store persists: verdicts, topology state, deduplication records, authentication keys.

Multiple mediator groups per synchronizer via `MediatorSynchronizerState` topology mappings.

#### Synchronizer Manager

- Verifies validity of topology changes before distribution
- Provides bootstrap topology state to newly connecting participants
- Validates topology transactions sequentially and deterministically
- **Not a separate entity** — topology management is a distributed function embedded in all Canton nodes; each node maintains a local deterministic state machine

---

## 3. The Canton Commit Protocol

A **two-phase commit variant** adapted for privacy. Described as 5-7 operational steps depending on the documentation source. The whitepaper uses a two-layer model: 2PC layer (replication) + sequencing layer (total-order conflict resolution).

### Phase 1: Submission

The **submitting participant**:
1. Executes the Daml command locally → produces a transaction tree
2. Decomposes the tree into **views** (one view per distinct set of informees)
3. Encrypts each view: generates random seed → derives symmetric key via HKDF → compresses + encrypts view
4. Encrypts the seed under each recipient participant's public encryption key
5. Constructs the **confirmation request batch**:
   - `EncryptedViewMessage` per view (addressed to relevant participants)
   - `InformeeMessage` (informee tree, sent to mediator)
   - `RootHashMessage` per receiving participant (Merkle root hash, addressed to both participant and mediator)
6. Sends entire batch to sequencer as single submission

### Phase 2: Sequencing

The sequencer:
- Assigns unique monotonic timestamp → becomes `RequestId`
- Delivers each message within the batch to its stated recipients
- Provides cryptographic proof of ordering

### Phase 3: Mediator Registration

The mediator:
- Receives `InformeeMessage` + `RootHashMessage`(s) from sequencer
- Registers the transaction request
- Validates all expected participants received their `RootHashMessage`
- Verifies all root hashes are equal
- Begins waiting for confirmation responses (configurable `participantResponseTimeout`)

### Phase 4: Participant Validation

Each validating participant:
- Receives `EncryptedViewMessage`(s) and `RootHashMessage`
- Decrypts symmetric view key using private encryption key
- Decrypts and decompresses the view
- Verifies Merkle tree root hash matches `RootHashMessage`
- Validates transaction against Daml semantics, authorization rules, local ledger state
- **Activeness check**: attempts to lock each contract consumed by the transaction
  - Contract already locked by pending earlier transaction → **negative** `ConfirmationResponse` (`LocalReject`)
  - Validation fails → **negative** `ConfirmationResponse` (`LocalReject`)
  - All checks pass → locks contracts, sends **positive** `ConfirmationResponse` (`LocalApprove`)
  - May send `LocalAbstain` in certain cases

### Phase 5: Mediator Aggregation

The mediator:
- Collects all `ConfirmationResponse` messages
- Aggregates per `ConfirmationPolicy` (quorum-based, per view)
- Quorum: maps `partyId → weight` with threshold; view confirmed if sum of approving party weights >= threshold
- Multiple quorums per view; **any one satisfied** is sufficient
- Built-in policies: **Signatory** (default), **Full Informee**, **VIP**
- Computes final `Verdict`: `Approve`, `MediatorReject`, or `Timeout`
- Constructs `ConfirmationResultMessage`, signs, sends via sequencer

### Phase 6: Sequencing of Result

Sequencer timestamps and delivers `ConfirmationResultMessage` to all informee participants.

### Phase 7: Result Processing

Each participant:
- **Approved**: atomically commits (creates new contracts, archives consumed), releases locks, publishes via `RecordOrderPublisher`
- **Rejected/Timeout**: releases all locks, records rollback
- `RecordOrderPublisher` ensures sequencer-timestamp ordering even with parallel validation

### Protocol Message Types

| Message Type | Description | Sender → Recipient |
|---|---|---|
| `TransactionConfirmationRequest` | Full confirmation request batch | Submitter → Sequencer → all |
| `EncryptedViewMessage[VT]` | Encrypted view tree with session keys and view hash | Submitter → per-view participants |
| `InformeeMessage` | Informee tree; extends `MediatorConfirmationRequest` | Submitter → Mediator |
| `RootHashMessage` | Root hash + payload per participant | Submitter → each participant + mediator |
| `ConfirmationResponse` | Participant's verdict on a view | Participant → Mediator |
| `ConfirmationResponses` | Batch of multiple `ConfirmationResponse` | Participant → Mediator |
| `ConfirmationResultMessage` | Mediator's final verdict | Mediator → all informees |
| `Verdict` (sealed trait) | `Approve`, `MediatorReject`, `ParticipantReject` | — |
| `LocalVerdict` (sealed trait) | `LocalApprove`, `LocalReject`, `LocalAbstain` | — |
| `SignedProtocolMessage[M]` | Wrapper adding cryptographic signatures | — |
| `AcsCommitment` | ACS commitment hash shared between participant pairs | Participant ↔ Participant |
| `TopologyTransactionsBroadcast` | Signed topology transactions | → All synchronizer members |
| `SetTrafficPurchasedMessage` | Traffic quota purchase | — |

All protocol messages extend `ProtocolMessage` (sealed trait).

---

## 4. Identity and Topology

### Unique Identifiers (UIDs)

Every Canton entity is identified by a **UID**: `identifier_string::namespace`

- **Identifier string** (`X`): human-readable (e.g., `jane_doe`)
- **Namespace** (`N`): fingerprint (cryptographic hash) of a root public key
- Format: `X::N` (e.g., `jane_doe::abc123def456...`)
- Combination `(X, N)` is globally unique

### Namespaces and Root of Trust

A namespace is defined by a self-signed root certificate where namespace, target key, and signing key are all the same. The corresponding private key is the root of trust for everything in that namespace.

### Topology Transactions

Signed state changes broadcast to all synchronizer members. Each has:
- **Serial number** (monotonically incrementing from 1, no gaps)
- **Change operation**: `REPLACE` (create/update) or `REMOVE` (deactivate)
- **Unique key** specific to its mapping type
- One or more cryptographic **signatures**

| Mapping Type | Description |
|---|---|
| `NamespaceDelegation` | Delegates namespace auth to another key. Permissions: `CanSignAllMappings`, `CanSignAllButNamespaceDelegations`, `CanSignSpecificMappings` |
| `OwnerToKeyMapping` | Declares signing and encryption keys for Canton nodes |
| `PartyToKeyMapping` | Declares keys for external parties |
| `PartyToParticipant` | Maps parties to hosting participants. Permissions: `Observation`, `Confirmation`, `Submission` |
| `SynchronizerTrustCertificate` | Participant's explicit membership signal for a synchronizer |
| `SequencerSynchronizerState` | Lists synchronizer sequencers |
| `MediatorSynchronizerState` | Lists mediator groups for the synchronizer |
| `VettedPackages` | Declares which Daml packages a participant agrees to execute |

### Distribution

- Topology transactions broadcast to `AllMembersOfSynchronizer` (sequencer resolves group at sequencing time)
- Validation is strictly sequential and deterministic across all nodes
- **Effective time** = sequencing time + configurable topology change delay (epsilon)
- Partially authorized transactions stored as **proposals** until sufficient signatures accumulate

### Trust Levels

Parties assigned trust levels: **ordinary** or **VIP**. VIP indicates trusted to act honestly (e.g., trusted market operator). VIP trust enables the VIP confirmation policy.

---

## 5. Ledger API / gRPC (v2, package: `com.daml.ledger.api.v2`)

### Core Services

| Service | Proto File | Key Methods | Notes |
|---|---|---|---|
| `CommandService` | `command_service.proto` | `SubmitAndWait`, `SubmitAndWaitForTransaction` | Synchronous submit+wait. `SubmitAndWaitForTransactionTree` removed in 3.4 |
| `CommandSubmissionService` | `command_submission_service.proto` | `Submit` | Fire-and-forget async |
| `CommandCompletionService` | `command_completion_service.proto` | `CompletionStream` | Server-streaming completion statuses |
| `UpdateService` | `update_service.proto` | `GetUpdates`, `GetUpdateByOffset`, `GetUpdateById` | Replaces v1 `TransactionService`. `GetUpdateTrees`/`GetTransactionTreeBy*` removed in 3.4 |
| `StateService` | `state_service.proto` | `GetActiveContracts`, `GetLedgerEnd` | Replaces v1 `ActiveContractsService` |
| `EventQueryService` | `event_query_service.proto` | `GetEventsByContractId`, `GetEventsByContractKey` | Party-specific event queries |
| `PackageService` | `package_service.proto` | `ListPackages`, `GetPackage`, `GetPackageStatus`, `ListVettedPackages` | `ListVettedPackages` added in 3.4 |
| `VersionService` | `version_service.proto` | `GetLedgerApiVersion` | API version + feature flags |
| `TimeService` | `time_service.proto` | `GetTime`, `SetTime` | Testing only (static time mode) |

### Interactive Submission Service (`com.daml.ledger.api.v2.interactive`)

Two-step externally-signed transaction flow:

| Method | Description |
|---|---|
| `PrepareSubmission` | Prepare transaction on participant; returns `CostEstimation` (traffic cost) as of 3.4 |
| `ExecuteSubmission` | Submit externally-signed transaction |
| `ExecuteSubmissionAndWait` | Added in 3.4 |
| `ExecuteSubmissionAndWaitForTransaction` | Added in 3.4 |
| `GetPreferredPackages` | Replaces deprecated `GetPreferredPackageVersion` in 3.4 |

### Admin Services (`com.daml.ledger.api.v2.admin`)

| Service | Key Methods |
|---|---|
| `PartyManagementService` | `GetParticipantId`, `GetParties`, `ListKnownParties`, `AllocateParty`, `AllocateExternalParty`, `UpdatePartyDetails`, `UpdatePartyIdentityProviderId`, `GenerateExternalPartyTopology` |
| `UserManagementService` | `CreateUser`, `GetUser`, `UpdateUser`, `DeleteUser`, `ListUsers`, `GrantUserRights`, `RevokeUserRights`, `ListUserRights`, `UpdateUserIdentityProviderId` |
| `IdentityProviderConfigService` | `CreateIdentityProviderConfig`, `GetIdentityProviderConfig`, `UpdateIdentityProviderConfig`, `ListIdentityProviderConfigs`, `DeleteIdentityProviderConfig` |
| `PackageManagementService` | `ListKnownPackages`, `UploadDarFile`, `ValidateDarFile`, `UpdateVettedPackages` |
| `ParticipantPruningService` | `Prune` |
| `CommandInspectionService` | `GetCommandStatus` (alpha/debug) |

### Command Flow: Submission to Completion

1. Application calls `CommandService.SubmitAndWait` (or `CommandSubmissionService.Submit` for async)
2. **Change ID** computed from: `(act_as parties, user_id, command_id)` — used for deduplication
3. Participant parses and validates command locally
4. Daml engine interprets command → produces transaction tree
5. Participant runs Canton commit protocol (phases 1-7)
6. On commit, event written to multi-sync-domain event log
7. Parallel indexer reads event, writes to indexer store
8. `CompletionService` emits completion status (or synchronous `CommandService` returns)
9. `UpdateService` streams committed transaction to subscribed applications

### Key Concepts

- **Offsets** are participant-local; same literal offset means different things across participants
- **Transaction shapes**: `TRANSACTION_SHAPE_ACS_DELTA` (ACS changes) or `TRANSACTION_SHAPE_LEDGER_EFFECTS` (full trees)
- **Deduplication** only applies within a single participant node
- **Explicit contract disclosure** (Canton 2.7+) — attach disclosed contracts from third parties

---

## 6. Inter-Node Communication

### Transport

All inter-node communication uses **gRPC over TLS**. The sequencer is the hub — nodes never communicate directly with each other. Every message between participants, mediators, and topology managers flows through the sequencer.

### Sequencer Connection Lifecycle

1. `SequencerConnectService` — protocol version handshake + service discovery
2. `SequencerAuthenticationService` — challenge-response → access token
3. `SequencerService` — main connection using access token
4. `SequencerClient` manages reconnection/failover

### Message Delivery Types

| Type | Description |
|---|---|
| `Deliver` | Successful delivery: timestamp, sender, recipients, encrypted envelopes |
| `DeliverError` | Delivery failure notification |

Wrapped in `SignedContent` providing cryptographic proof of authenticity and ordering.

### Envelope Structure

| Type | Description |
|---|---|
| `ClosedEnvelope` | Encrypted, as stored in sequencer |
| `OpenEnvelope` | Decrypted by recipient |
| `DefaultOpenEnvelope` | Type alias for `OpenEnvelope[ProtocolMessage]` |

A submitter sends a `Batch` of envelopes atomically; sequencer timestamps the entire batch and delivers individual envelopes to respective recipients.

### Conflict Detection at Participant

- **Pessimistic locking**: on valid confirmation request, immediately lock all consumed contracts
- Second request consuming a locked contract → immediately rejected (`LocalReject`)
- On `ConfirmationResultMessage`:
  - Approved → locks become permanent archives
  - Rejected/Timeout → locks released
- No central coordinator for ACS state; safe because sequencer enforces **total ordering** — all honest participants process requests in same sequence
- Known trade-off: **phantom rejections** when transaction A is later rolled back but already caused B to be rejected

---

## 7. Storage Architecture

### Participant Storage

| Store | Contents |
|---|---|
| **Private Contract Store (PCS)** | Decrypted contract instances with full payload (stakeholder parties only) |
| **Active Contract Journal** | Contract status per synchronizer (active/archived/locked) |
| **Sync Service Linear Event Log** | Full decrypted transactions per synchronizer |
| **Multi-Sync-Domain Event Log** | Merged ordering from all synchronizers; committed requests + rollbacks |
| **Indexer Events Table** | Read-optimized projection for Ledger API queries |
| **Command Deduplication Store** | Change IDs and deduplication windows |
| **Topology State Store** | Historical topology snapshots for validation |
| **Crypto Key Store** | Private signing/encryption keys (DB, KMS, or in-memory) |
| **In-Flight Submission Tracker** | Pending command submissions awaiting completion |
| **Reassignment Store** | In-flight contract reassignments between synchronizers |

### Sequencer Storage

| Store | Contents |
|---|---|
| **Message Store** | All processed messages (encrypted envelopes, view seeds, symmetric keys, root hashes, recipient IDs) |
| **Subscription Status Store** | Per-member subscription state and counters |
| **Topology Snapshot Store** | Historical and current topology state |
| **Previous Timestamp Store** | Last-seen timestamp per member (gap detection) |
| **BFT Ordering Layer Store** | Ordered blocks (when using BFT Orderer) |
| **Authentication Key Store** | Node authentication material |

### Mediator Storage

| Store | Contents |
|---|---|
| **Verdict Store** | Verdicts sent to participants per request |
| **Topology State Store** | Synchronizer topology information |
| **Deduplication Store** | Transaction replay prevention records |
| **Authentication Key Store** | Node authentication material |

### ACS Commitments

Pairs of participants **periodically exchange ACS commitments** — cryptographic hashes of the active contract set for mutual counterparties:
- Ensures diverging views detected within commitment period
- `AcsCommitment` contains: synchronizer ID, participant IDs, time period, commitment hash
- `CommitmentPeriod` defines reconciliation interval (configurable via `StaticDomainParameters`)
- Pruning of historical data requires cryptographic proof via ACS commitments

### Storage Duplication

Both sync service and indexer store events (linear event log + read-optimized projection). Digital Asset has noted plans to reduce this duplication.

---

## 8. Sub-Transaction Privacy

### Transaction Decomposition into Views

A Daml transaction tree is decomposed into **views**, where each view corresponds to a subtransaction visible to a specific set of **informees**.

Informees determined by Daml authorization/privacy model:
- **Signatories** and **observers** of created/consumed contracts
- **Controllers** of exercised choices
- **ConfirmingParty** — parties that must actively confirm (with quorum weights)
- **PlainInformee** — informed but do not confirm

### Merkle Tree Structure

Top-level: `GenTransactionTree` (`com.digitalasset.canton.data`)

```
GenTransactionTree
 ├── submitterMetadata:   MerkleTree[SubmitterMetadata]
 ├── commonMetadata:      MerkleTree[CommonMetadata]
 ├── participantMetadata: MerkleTree[ParticipantMetadata]
 └── rootViews:           MerkleSeq[TransactionView]
      └── TransactionView (MerkleTreeInnerNode)
           ├── viewCommonData:      MerkleTree[ViewCommonData]
           ├── viewParticipantData: MerkleTree[ViewParticipantData]
           └── subviews:            TransactionSubviews (recursive)
```

Tree types:
- `FullTransactionViewTree` — exactly one view (+ subviews) unblinded; sent to each participant
- `LightTransactionViewTree` — one view unblinded, direct subviews blinded
- `FullInformeeTree` — CommonMetadata unblinded, ParticipantMetadata + SubmitterMetadata blinded; sent to mediator

Blinding: `BlindedNode[A]` replaces subtrees with hash. All versions share same `RootHash`.

### View Encryption (HKDF-Based Hybrid)

1. Generate random **seed** (`SecureRandomness`) per view
2. Derive **symmetric key** from seed using **HKDF** (RFC 5869)
3. **Compress** the view, then encrypt once with symmetric key (AES-GCM via `SymmetricKeyScheme`)
4. Encrypt the seed under each recipient participant's **asymmetric public encryption key**
5. Only encrypted seed is duplicated per recipient — O(N) seed encryptions, O(1) view encryption

For **nested subviews**: child view's seed derived from parent view's seed via PRF — no separate per-recipient key distribution needed.

Session encryption keys further optimize: participants maintain short-lived session keys in memory (ephemeral, never persisted).

### Practical Example: Delivery-vs-Payment

- **Bank** sees only cash transfer view ($10k), not shares
- **Registrar** sees only shares transfer view (100 shares), not cash
- **Seller, Buyer, Trading App** see both views

---

## 9. Multi-Synchronizer (Cross-Domain)

### Architecture

A participant connects to **multiple synchronizers simultaneously**. Each connection managed by its own `SyncDomain` instance (own sequencer client, protocol processor, sync service). The `Multi-Sync-Domain Event Log` merges events into single ordered stream for Ledger API.

### Cross-Synchronizer Transactions

Allowed when there exists **at least one synchronizer to which all participants in a transaction are connected**.

### Contract Reassignment Protocol (Two-Step)

**Unassignment (on source synchronizer):**
- Submitter sends `UnassignmentMediatorMessage` containing `UnassignmentViewTree` (blindable Merkle tree)
- View includes `UnassignmentData` (source domain, target domain, contract details)
- After mediator approval → contract deactivated on source synchronizer
- `UnassignmentData` stored for passing to target

**Assignment (on target synchronizer):**
- Submitter sends `AssignmentMediatorMessage` containing `AssignmentViewTree`
- Includes proof of unassignment from source
- After mediator approval → contract activated on target synchronizer

Key types: `ReassignmentViewTree`, `UnassignmentViewTree`, `AssignmentViewTree`, `ReassignmentCommonData`, `UnassignmentData`, `TransferId` (source domain + request timestamp)

### Global Synchronizer

For workflows spanning multiple consortiums, the **Global Synchronizer** coordinates the overarching 2PC protocol, stitching cross-domain transactions atomically without forcing domains to merge.

- **Live since July 2024**
- Operated by Super Validator Collective (SVC)
- BFT consensus (2/3 majority)
- Governed by Global Synchronizer Foundation (GSF) under Linux Foundation

---

## 10. Crash Recovery and Repair

### Four Recovery Layers

**Layer 1: Automated Self-Healing** — retry DB/network outages automatically; warnings only

**Layer 2: Crash/Restart Recovery** — on restart, re-create consistent state from persisted stores; replay transactions from synchronizer; command deduplication functional after catch-up

**Layer 3: Standard Disaster Recovery** — restore from DB backup; participant replays missing data from synchronizer; ACS commitments provide cryptographic proof of expected state

**Layer 4: Manual Corruption Recovery** — requires `features.enable-repair-commands = yes`; participant must be disconnected from affected synchronizer; no in-flight requests

### Repair Console Commands

| Command | Description |
|---|---|
| `participant.repair.add_contracts` | Manually add contracts to ACS; repair service re-computes metadata |
| `participant.repair.purge_contracts` | Remove contracts from ACS (last resort for corruption) |
| `participant.repair.change_domain` | Move contracts to different synchronizer (migration) |
| `participant.repair.ignore_events` | Skip faulty transactions during recovery |
| `participant.repair.download` / `upload` | Export/import ACS snapshots |

### Repair Workflow for Synchronizer Loss

1. Set up new synchronizer
2. Participants connect temporarily (initialize identity state)
3. Disconnect participants
4. `repair.change_domain` to reassign contracts from old to new synchronizer
5. Reconnect participants

---

## 11. Key Scala Packages (Source Code Reference)

| Package | Contents |
|---|---|
| `com.digitalasset.canton.data` | `TransactionView`, `GenTransactionTree`, `InformeeTree`, `MerkleTree`, `ViewCommonData`, `ViewParticipantData`, `CommonMetadata`, `ParticipantMetadata`, `SubmitterMetadata`, `ActionDescription`, `Witnesses`, `ViewPosition`, `CantonTimestamp`, `Informee`, `ConfirmingParty`, `PlainInformee`, `Quorum`, reassignment view trees |
| `com.digitalasset.canton.protocol` | `TransactionId`, `RequestId`, `RootHash`, `ViewHash`, `Unicum`, `SerializableContract`, `ContractMetadata`, `DynamicDomainParameters`, `StaticDomainParameters`, `ConfirmationPolicy`, `WellFormedTransaction`, `Phase37Processor`, `RequestProcessor` |
| `com.digitalasset.canton.protocol.messages` | `ProtocolMessage`, `SignedProtocolMessage`, `EncryptedViewMessage`, `InformeeMessage`, `RootHashMessage`, `ConfirmationResponse`, `ConfirmationResultMessage`, `Verdict`, `LocalVerdict`, `AcsCommitment`, `TopologyTransactionsBroadcast`, `TransactionConfirmationRequest` |
| `com.digitalasset.canton.sequencing.protocol` | `SequencedEvent`, `Deliver`, `DeliverError`, `SignedContent` |
| `com.digitalasset.canton.participant.protocol.conflictdetection` | `ContractStateManager`, `ActivationKind`, `ConflictDetector` |
| `com.digitalasset.canton.topology.transaction` | Topology transaction types, namespace delegations |

---

## 12. Canton Network Status (as of Feb 2026)

| Item | Status |
|---|---|
| Latest Canton version | **3.4.11** (released Feb 16, 2026) |
| Canton 3.5 | Docs exist, no software release yet |
| Global Synchronizer | **Live** since July 2024 |
| Canton Coin (CC) | **Live**; ~22B CC in circulation; incentive model simplified Jan 2, 2026 |
| BFT Sequencer | **Shipped**, live on Global Synchronizer |
| Database support | PostgreSQL 14-17 only (Oracle/H2 dropped in 3.x) |
| Governance | Canton Foundation + Global Synchronizer Foundation (Linux Foundation) |

---

## 13. Node Hosting and Third-Party Providers

### Approved Node-as-a-Service Providers

The Canton Foundation maintains a list of approved providers: Blockdaemon, BCW StakeFI, Copper, Dfns, DSRV, Everstake, Figment, Kiln, P2P.org, and others. These offer Validator-as-a-Service for institutions that do not want to run their own infrastructure.

### Blockdaemon

Blockdaemon's Canton offering includes:
1. **Validator Infrastructure** — 99.9% uptime SLA, 24/7 monitoring, governance participation support
2. **Super Validator Partnership** — streamlined SV onboarding (early 2026)
3. **Canton Wallet via Institutional Vault** — MPC-secured wallet for receiving, storing, transferring CC; on-premises wallet option available
4. **Canton Tokenization** — privacy-first tokenization services

Certifications: ISO 27001, SOC 2 Type II. Blockdaemon has integrated CC into their Institutional Vault for treasury management and traffic fee payments.

### What a Third-Party Host Can Access

**Without external KMS (Model A):**
- Private encryption keys → can decrypt all transaction views for hosted parties
- Private signing keys → can sign topology transactions and protocol messages
- Private Contract Store (PCS) in PostgreSQL → full decrypted contract payloads
- Active Contract Journal → contract status (active/archived/locked)
- All transaction metadata — counterparties, timestamps, amounts

**With external KMS (Model B — recommended for regulated entities):**
- Physically hosts compute and database but cannot independently decrypt or sign
- Bank's KMS (CloudHSM, Azure Key Vault, etc.) handles all crypto operations
- Provider sees encrypted data at rest; useful access requires KMS authorization
- Network traffic patterns (metadata: envelope sizes, timing) still observable

In both models, the **root namespace key** should be retained by the bank in cold storage. The root key is the trust anchor for all identity operations — loss of it means loss of namespace authority.

### Onboarding Process

1. Request access through an existing Super Validator, validator, app provider, or the Global Synchronizer Foundation
2. Prepare container environment (VM or Kubernetes) in cloud or own data center
3. Configure fixed egress IP; submit to sponsor for whitelisting
4. Set up OIDC authentication (coordinate with enterprise identity provider)
5. Download packages from sponsoring Super Validator with onboarding secret
6. Deploy to DevNet first, then request TestNet/MainNet access

### Infrastructure Requirements for Self-Hosting

| Component | Requirement |
|---|---|
| Database | PostgreSQL 14-17 (only production DB in Canton 3.x) |
| Runtime | JVM/Scala process |
| Orchestration | Kubernetes recommended (Docker Compose also supported) |
| Networking | Fixed egress IP (whitelisted by Super Validators); gRPC over TLS |
| Auth | OIDC integration |
| Compute | Configurable per deployment; depends on transaction volume and party count |

---

## 14. Canton Coin (CC) and Traffic System

### Canton Coin Basics

- **No staking or locking requirement** — fundamental difference from PoS chains
- No risk of slashing
- CC is needed only for purchasing **traffic** (paying for sequencer message delivery)
- CC is earned passively through **liveness rewards**
- Total supply cap: **100 billion CC** mintable in first 10 years, no pre-mine
- Current circulation: ~22 billion CC (early 2025)
- Annual issuance/burn target: ~2.5 billion CC in equilibrium

### Traffic System — Detailed

Traffic management protects the sequencer from abuse. Every message submission consumes traffic balance.

**Two types of traffic:**

1. **Base Rate Traffic (free tier)**
   - Accumulates passively based on synchronizer time
   - Parameters: `burstAmount` (e.g., 400,000 bytes) and `burstWindow` (e.g., 1,200 seconds / 20 min)
   - Fully replenishes after complete inactivity during the burst window
   - Always consumed **first** before extra traffic

2. **Extra Traffic (purchased with CC)**
   - Purchased by calling `SetTrafficPurchased` RPC on at least `threshold` sequencers
   - Priced in USD per MB (e.g., **$60.00/MB**), settled by burning CC at current USD exchange rate
   - Minimum top-up: `minTopupAmount` (e.g., 200,000 bytes)
   - The request sets an absolute total value, not a delta
   - Each request needs a serial number for idempotency

**Traffic cost calculation:**

```
storage_cost = envelope.payload_bytes
network_cost = envelope.payload_bytes * recipients.count * read_vs_write_scaling_factor / 10000
total_cost = storage_cost + network_cost + base_event_cost
```

Example: `readVsWriteScalingFactor = 4`, sending 1 MB to 10 recipients → cost = 1,040,000 bytes.

**When traffic is exhausted:** The sequencer denies further submissions until balance recovers (base rate replenishment) or is topped up (extra traffic purchase).

**Automatic top-up:** The validator app includes built-in automation that configures target throughput and automatically purchases traffic to sustain it, preventing submission failures.

**Special cases:**
- Super Validator components (participants, mediators, sequencers) have **unlimited traffic** — no fees
- Confirmation responses can optionally be free via `free_confirmation_responses` parameter

### Fee Economics — Burn-Mint Model

- Fees are denominated in **USD** but settled by **burning CC** at market rate
- Burned CC is removed from circulation permanently
- New CC is minted and distributed as rewards
- Supply grows or shrinks based on real network usage
- Avoids gas market volatility seen in ETH/BTC

### Reward System

Mining rounds occur every **10 minutes**. Stakeholders receive coupons redeemable for CC minting. **Critical: coupons must be redeemed in the following mining round or they are permanently lost.**

| Reward Type | Who Earns | Mechanism |
|---|---|---|
| Validator Liveness | All validators | Binary proof-of-life: online and connected to Global Synchronizer |
| Validator Activeness | Active validators | Discounts on self-purchased traffic |
| Transaction Rewards | Validators with active parties | Portion of fees returned when hosted parties transact ("cashback") |
| App Provider Rewards | App developers | Based on traffic generated by their applications ("perpetual grant program") |
| Super Validator Rewards | Super Validators only | For securing Global Synchronizer infrastructure |

**Reward distribution phases:**

| Phase | Period | Super Validators | App Providers | Validators/Users |
|---|---|---|---|---|
| Initial | Jul-Dec 2024 | ~80% | ~15% | ~5% |
| Current | 2025 — mid-2029 | 20% | up to 62% | remaining |
| Long-term | Post-2029 | Further reduction | Dominant share | Growing share |

Top applications have earned 100M-500M CC per month (Hashnote USYC, 3Trade, Brale cited as examples).

---

## 15. Cryptographic Key Architecture and Trust Boundaries

### Key Types

| Key Type | Purpose | Where Stored |
|---|---|---|
| Root namespace key | Trust anchor for entire namespace; signs NamespaceDelegation | Cold storage (HSM in separate facility) — **never on the running node** |
| Intermediate delegation keys | Delegated authority with restrictions | Secure storage; can be on-node or in KMS |
| Signing keys | Authorize topology transactions, sign protocol messages | Node-local or external KMS |
| Encryption keys | Decrypt transaction views, protect confidentiality | Node-local or external KMS |
| Session encryption keys | Short-lived ephemeral keys for optimized encryption | In-memory only; never persisted |

### Delegation Hierarchy

```
Root Certificate (self-signed: namespace = target key = signing key)
  └─ NamespaceDelegation (CanSignAllMappings)
       └─ NamespaceDelegation (CanSignAllButNamespaceDelegations)  ← daily operational key
            └─ NamespaceDelegation (CanSignSpecificMappings)       ← compartmentalized
                 └─ OwnerToKeyMapping (declares signing + encryption keys for node)
```

### Trust Boundary Analysis — Who Holds What

| Entity | Keys Held | Data Accessible |
|---|---|---|
| Bank (party owner) | Root namespace key (always); operational keys if self-hosted or via KMS | All contract data for own parties |
| Hosting provider (Model A) | Signing + encryption keys on their infra | Full PCS, ACJ, decrypted views — same as the bank |
| Hosting provider (Model B/KMS) | No key material; calls bank KMS for every op | Encrypted DB contents; cannot decrypt independently |
| Synchronizer sequencer | Own authentication keys only | Encrypted envelopes, timestamps, recipient IDs — **no payloads** |
| Synchronizer mediator | Own authentication keys only | Informee tree (who confirms), root hashes, confirmation responses — **no view contents** |
| Other participants | Own keys only | Only views they are informees of |

### Key Loss Implications

- **Root namespace key loss**: Cannot perform namespace-level operations (delegations, identity changes). Existing operations continue but namespace authority is permanently lost.
- **Encryption key loss**: Cannot decrypt future transaction views. Past data in PCS remains accessible (already decrypted and stored).
- **Signing key loss**: Cannot authorize transactions or topology changes. Must rotate to new keys using higher-level delegation.
- **All keys lost**: Party identity effectively destroyed. Assets may require counterparty coordination to recover.

### Recommended Key Architecture for Banks

1. Root namespace key → geographically redundant HSMs (2+ locations), offline
2. Intermediate delegation key (CanSignAllButNamespaceDelegations) → online KMS with audit logging
3. Operational signing/encryption keys → KMS with IAM-controlled access; validator node calls KMS APIs
4. Session keys → in-memory on validator; ephemeral, auto-rotated

---

## 16. Node Resiliency and Disaster Recovery — Technical Details

### Recovery Layer Details

**Layer 1 — Automated Self-Healing:**
- `SequencerClient` manages automatic reconnection and failover
- DB transient failures retried with backoff
- Warnings emitted; no operator intervention needed

**Layer 2 — Crash/Restart Recovery:**
- On JVM restart, node re-creates consistent state from persisted PostgreSQL stores
- Replays from last processed sequencer timestamp
- Command deduplication table ensures no duplicate processing after catch-up
- In-flight submissions may time out at mediator during downtime → recorded as rollbacks

**Layer 3 — Standard Disaster Recovery:**
- Restore PostgreSQL from backup (must be **< 30 days old** — sequencer prunes beyond this)
- Node resubscribes to synchronizer → replays all committed transactions since backup timestamp
- ACS commitments (periodic crypto hashes between participant pairs) verify recovered state matches counterparty's view
- Recovery validation: search logs for `CommitmentPeriod` entries; target "Commitment correct for sender" messages

**Layer 4 — Manual Repair:**
- Requires `features.enable-repair-commands = yes` in canton config
- Participant **must be disconnected** from affected synchronizer
- No in-flight requests allowed

Available commands:
| Command | Use Case |
|---|---|
| `participant.repair.add_contracts` | Manually add contracts to ACS (re-computes metadata) |
| `participant.repair.purge_contracts` | Remove contracts from ACS (last resort for corruption) |
| `participant.repair.change_domain` | Move contracts to different synchronizer (migration) |
| `participant.repair.ignore_events` | Skip faulty transactions during recovery |
| `participant.repair.import_acs()` | Import ACS snapshot (from scan APIs — disaster recovery) |
| `participant.repair.download` / `upload` | Export/import ACS snapshots |

### 30-Day Backup Window — Critical Constraint

The synchronizer prunes transaction history after ~30 days. If a database backup is older than 30 days, the synchronizer cannot provide the missing transaction history for replay. This results in:
- **Standard replay impossible** — the gap between backup and current state cannot be bridged
- Must fall back to Layer 4 repair: import ACS from scan APIs (if available), manual contract reconciliation
- **Operational imperative**: Enforce backup cadence with monitoring and alerting; never let backups exceed 25 days as safety margin

### Synchronizer Failure Scenarios

**Partial sequencer failure (BFT):**
- Global Synchronizer uses 2/3 majority BFT consensus
- Tolerates up to 1/3 of sequencer nodes failing
- Remaining honest sequencers continue ordering

**Full synchronizer failure:**
- All participants connected to that synchronizer are stalled
- Pending transactions time out at mediator
- Contracts remain in last committed state

**Permanent synchronizer loss — recovery workflow:**
1. Deploy new synchronizer
2. Participants connect temporarily (initialize identity state on new synchronizer)
3. Disconnect all participants
4. Run `repair.change_domain` on each participant to reassign contracts from old → new synchronizer
5. Reconnect participants to new synchronizer

### Super Validator Disaster Recovery

Three documented approaches:

1. **Single node corruption**: Restore from backups, scale K8s to zero, restore storage, scale back up, allow catch-up from peers
2. **Catastrophic SV failure**: Extract identities from backup (`jq '.identities.participant' backup.json`), wait for governance vote to offboard, deploy standalone validator with extracted identities, transfer assets to newly onboarded SV
3. **Network-wide CometBFT failure**: Coordinate all SVs on single recovery timestamp, dump data from SV app API, construct migration dump, redeploy

**Caveat**: Single-node restoration from backups is documented as "not yet tested enough to be advisable for production" (current Splice docs).

### Recommended Safeguarding Architecture for Banks

1. **PostgreSQL HA**: Streaming replication with automatic failover (managed cloud PG or Patroni)
2. **Backup cadence**: Daily backups, weekly tested restores, strict < 25-day age enforcement
3. **ACS commitment monitoring**: Alert on mismatches — early detection of state divergence between participants
4. **Key backup**: Root key in geographically redundant HSMs; operational keys in replicated KMS with audit trails
5. **Multi-region standby**: For critical deployments, secondary-region standby node with replicated database (warm standby)
6. **Monitoring dashboards**: Traffic consumption (prevent denial from exhaustion), node liveness, sequencer subscription health, ACS commitment status, reward coupon redemption (avoid permanent loss from missed 10-min window)
7. **Runbook**: Documented procedures for each recovery layer with tested playbooks

---

## 17. Regulatory Considerations for Node Hosting

### Why Hosting Location Matters for Banks

**Data Residency:**
- Canton distributes data on need-to-know basis (unlike public blockchains with global replication)
- Self-hosted: bank chooses jurisdiction directly
- Third-party hosted: must contractually enforce data location; verify provider's data center locations
- Relevant frameworks: GDPR, MAS TRM (Singapore), SAMA data sovereignty (Saudi), HKMA, OCC (US)

**Key Custody:**
- Root namespace key = trust anchor for all identity operations
- Loss of private keys = inability to prove asset ownership; potential permanent loss of access
- Regulators expect institutions to maintain exclusive control over material signing keys
- External KMS with audit logging provides both control and evidence trail

**Operational Risk:**
- Validator downtime = bank's parties cannot transact
- Liveness rewards stop during downtime (binary)
- Third-party provider failure = concentration risk
- Some regulators require multi-vendor or self-hosted strategies for critical infrastructure

### Canton's Regulatory Design Principles

Canton operates on the principle: **"same risk, same activity, same regulation"** — designed to function under existing models of regulation without requiring new frameworks.

Key regulatory features:
- **Supervisory access**: Regulators can be permissioned as **observer parties** with real-time, immutable, read-only view of all supervised transactions
- **Automated regulatory reporting**: Every trade/settlement can auto-generate cryptographically proven reports sent directly to the relevant regulator
- **KYC/AML compliance**: Selective connection capability; institutions control which parties they transact with
- **Participant screening**: All participants screened before network connection (invite-only / sponsorship model)
- **Audit trail**: Tamper-proof, cryptographically verifiable transaction history
- **Basel compliance**: Tokenized assets designed to meet Basel Committee criteria; institutions never lose control of assets or data

---

## Sources

- [Canton Whitepaper](https://www.canton.io/publications/canton-whitepaper.pdf)
- [Canton Protocol Overview](https://www.canton.network/protocol)
- [Topology Management (3.4)](https://docs.digitalasset.com/overview/3.4/explanations/canton/topology.html)
- [gRPC Ledger API Services (3.5)](https://docs.digitalasset.com/build/3.5/explanations/ledger-api-services.html)
- [gRPC Ledger API Proto Reference (3.4)](https://docs.digitalasset.com/build/3.4/reference/lapi-proto-docs.html)
- [Canton Pruning (3.4)](https://docs.digitalasset.com/overview/3.4/explanations/canton/pruning.html)
- [Canton Security/Keys (3.4)](https://docs.digitalasset.com/overview/3.4/explanations/canton/security.html)
- [Canton Scaladoc — data package (3.5)](https://docs.digitalasset.com/operate/3.5/scaladoc/com/digitalasset/canton/data/index.html)
- [Canton Scaladoc — messages package (3.5)](https://docs.digitalasset.com/operate/3.5/scaladoc/com/digitalasset/canton/protocol/messages/index.html)
- [Canton Domain Architecture](https://docs.daml.com/canton/architecture/domains/domains.html)
- [Canton Repair Nodes](https://docs.daml.com/canton/usermanual/repairing.html)
- [Canton Identity Management (3.4)](https://docs.digitalasset.com/operate/3.4/howtos/operate/identity_management.html)
- [Canton GitHub Releases](https://github.com/digital-asset/canton/releases)
- [Canton 3.4 Release Notes](https://blog.digitalasset.com/developers/release-notes/canton-3.4-release-notes-for-splice-0.5.0)
- [Global Synchronizer](https://www.canton.network/global-synchronizer)
- [Canton Key Concepts (3.4)](https://docs.digitalasset.com/build/3.4/overview/key_concepts.html)
- [Ledger API Migration Guide (3.4)](https://docs.digitalasset.com/build/3.4/reference/lapi-migration-guide.html)
- [Canton Foundation Validators](https://canton.foundation/validators/)
- [Blockdaemon Canton](https://www.blockdaemon.com/protocols/canton)
- [Blockdaemon Institutional Vault — Canton](https://www.blockdaemon.com/blog/blockdaemon-expands-institutional-access-to-the-canton-network-with-institutional-vault-tm-2)
- [How Canton Works — Blockdaemon](https://www.blockdaemon.com/blog/how-canton-works)
- [Canton Coin: Rewarding Utility](https://www.canton.network/blog/canton-coin-rewarding-utility)
- [Canton FAQ](https://www.canton.network/faq)
- [Canton Traffic Management (3.4)](https://docs.digitalasset.com/overview/3.4/explanations/canton/traffic-management.html)
- [Global Synchronizer Traffic Fees](https://docs.sync.global/deployment/traffic.html)
- [Canton Tokenomics and Rewards](https://docs.digitalasset.com/integrate/devnet/tokenomics-and-rewards/index.html)
- [Canton Regulatory Perspective](https://www.canton.network/blog/the-canton-network-a-regulatory-perspective-1)
- [Canton Institutional Privacy](https://www.canton.network/blog/how-canton-network-delivers-institutional-grade-privacy)
- [How to Get Started with a Validator](https://www.canton.network/blog/how-to-get-started-with-a-validator-on-canton)
- [Validator Disaster Recovery](https://docs.sync.global/validator_operator/validator_disaster_recovery.html)
- [SV Restore](https://docs.dev.sync.global/sv_operator/sv_restore.html)
