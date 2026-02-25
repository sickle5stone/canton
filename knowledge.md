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
