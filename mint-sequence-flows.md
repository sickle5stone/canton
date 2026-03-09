# Mint Sequence Flows — Vault Signing + Blockdaemon Interactive Submission

## Canton Network | `deposit_token` Instrument on Registry Utility

**Version 1.0 | March 2026 | CONFIDENTIAL — Internal Use Only**

---

## Table of Contents

- [Mint Sequence Flows — Vault Signing + Blockdaemon Interactive Submission](#mint-sequence-flows--vault-signing--blockdaemon-interactive-submission)
  - [Canton Network | `deposit_token` Instrument on Registry Utility](#canton-network--deposit_token-instrument-on-registry-utility)
  - [Table of Contents](#table-of-contents)
  - [1. Happy Path — Full E2E Mint](#1-happy-path--full-e2e-mint)
  - [2. Detailed Internal — PrepareSubmission to Signing](#2-detailed-internal--preparesubmission-to-signing)
  - [3. Error Flow — Vault Signing Failures](#3-error-flow--vault-signing-failures)
  - [4. Error Flow — PrepareSubmission Failures](#4-error-flow--preparesubmission-failures)
  - [5. Error Flow — Prepared TX Expiry](#5-error-flow--prepared-tx-expiry)
  - [6. Error Flow — ExecuteSubmission Failures](#6-error-flow--executesubmission-failures)
  - [7. Error Flow — Canton Protocol Rejection](#7-error-flow--canton-protocol-rejection)
  - [8. Rollback \& Compensation](#8-rollback--compensation)
  - [9. Error Decision Matrix](#9-error-decision-matrix)

---

## 1. Happy Path — Full E2E Mint

Unified flow from client request through off-chain settlement, interactive submission (Prepare → Sign → Execute), Canton confirmation protocol, and off-chain finalization.

```mermaid
sequenceDiagram
    autonumber
    participant Client as Corporate Client
    participant ITS as Core Banking
    participant IL as Internal Ledger
    participant Kafka as Event Bus (Kafka)
    participant Orch as Token Orchestrator
    participant Vault as HashiCorp Vault<br/>(Transit Engine / HSM)
    participant BD as Blockdaemon<br/>Validator Node
    participant SEQ as Canton Sequencer
    participant VAL as Stakeholder<br/>Validators
    participant MED as Canton Mediator

    Note over Client,MED: PHASE 1 — Off-Chain Settlement

    Client->>ITS: Mint Request (5M deposit_token for Acme)
    ITS->>ITS: Validate DDA balance >= $5M
    ITS->>ITS: Debit DDA (Acme) $5M
    ITS->>ITS: Credit Reserve Account $5M
    ITS->>IL: POST /v1/tokens/mint<br/>{owner: "acme", amount: 5000000, currency: "USD"}
    IL->>IL: Record position (PENDING_MINT)<br/>Assign txn_ref: TXN-MINT-20260301-A7F3
    IL->>Kafka: Emit MintRequested event<br/>{txn_ref, owner, amount, timestamp}
    Kafka->>Orch: Consume MintRequested

    Note over Orch,MED: PHASE 2 — Prepare (Blockdaemon)

    Orch->>Orch: Construct Daml CreateCommand<br/>template: Instrument (deposit_token)<br/>args: {issuer, owner, amount, registry: RegistryUtility}
    Orch->>BD: InteractiveSubmissionService.PrepareSubmission<br/>{commands: [CreateCommand], act_as: ["bank::issuer"],<br/>command_id: "CMD-MINT-20260301-A7F3E9",<br/>workflow_id: "WF-MINT-TXN-A7F3"}
    BD->>BD: Parse & validate Daml command
    BD->>BD: Execute Daml interpretation engine<br/>Compute full transaction tree
    BD->>BD: Decompose into participant views
    BD->>BD: Serialize prepared tx + SHA-256 hash
    BD->>BD: Identify signing requirements<br/>Estimate traffic cost
    BD-->>Orch: PreparedTransaction<br/>{prepared_transaction_data: bytes,<br/>transaction_hash: 0xa3f2b1...(32 bytes),<br/>hash_algorithm: "SHA256",<br/>signature_requirements: [{party: "bank::issuer",<br/>key_fingerprints: ["fp:ab12cd..."]}],<br/>cost_estimation: {traffic_cost_bytes: 1024},<br/>registry: "RegistryUtility"}

    Note over Orch,Vault: PHASE 3 — Sign (HashiCorp Vault)

    Orch->>Orch: Extract transaction_hash<br/>Base64-encode: b64(0xa3f2b1...)
    Orch->>Vault: POST /v1/transit/sign/canton-signing-key<br/>Headers: {X-Vault-Token, X-Vault-Namespace: bank/canton-prod}<br/>Body: {input: "<b64_hash>", hash_algorithm: "sha2-256",<br/>prehashed: true, marshaling_algorithm: "asn1"}
    Vault->>Vault: Route to HSM backend<br/>ECDSA P-256 sign<br/>(FIPS 140-2 L3, key never leaves HSM)
    Vault-->>Orch: 200 OK<br/>{data: {signature: "vault:v1:MEUC...", key_version: 3}}
    Orch->>Orch: Strip "vault:v1:" prefix<br/>Base64-decode to raw DER bytes<br/>Construct signature envelope

    Note over Orch,MED: PHASE 4 — Execute (Blockdaemon to Canton)

    Orch->>BD: InteractiveSubmissionService.ExecuteSubmission<br/>{prepared_transaction_data: bytes,<br/>party_signatures: [{party: "bank::issuer",<br/>signatures: [{signature: DER_bytes,<br/>signed_by: "fp:ab12cd...",<br/>format: SIGNATURE_FORMAT_RAW}]}]}
    BD->>BD: Retrieve in-memory prepared tx (by hash)
    BD->>BD: Verify signature against registered public key
    BD->>BD: Attach signature to transaction tree
    BD->>BD: Encrypt views (HKDF seed per view,<br/>AES-GCM encryption, seed encrypted per recipient)
    BD->>BD: Construct ConfirmationRequest batch

    Note over BD,MED: PHASE 5 — Canton Confirmation Protocol

    BD->>SEQ: ConfirmationRequest<br/>(EncryptedViewMessage + InformeeMessage + RootHashMessage)
    SEQ->>SEQ: Assign monotonic timestamp

    par Distribute to stakeholders
        SEQ->>VAL: Encrypted views (need-to-know)
        SEQ->>MED: Encrypted metadata (InformeeMessage)
    end

    VAL->>VAL: Decrypt views with party encryption key
    VAL->>VAL: Execute Daml locally (re-interpret)
    VAL->>VAL: Validate authorization rules
    VAL->>VAL: Fetch owner Credential from ACS
    VAL->>VAL: Check: kycStatus == ACTIVE
    VAL->>VAL: Check: deposit_token in permissionedInstruments
    VAL->>VAL: Check: credential not expired
    VAL->>VAL: Check: jurisdiction not sanctioned
    VAL->>SEQ: ConfirmationResponse (LocalApprove)
    SEQ->>MED: Forward confirmation responses
    MED->>MED: All stakeholders approved<br/>Compute Approval verdict
    MED->>SEQ: ConfirmationResultMessage (APPROVE)

    par Distribute verdict
        SEQ->>BD: Verdict: APPROVED
        SEQ->>VAL: Verdict: APPROVED
    end

    BD->>BD: Commit deposit_token instrument to ACS<br/>(Active Contract Set on Registry Utility)
    BD-->>Orch: TransactionResult<br/>{transaction_id: "tx-abc123",<br/>offset: "000000000042",<br/>effective_at: "2026-03-01T10:00:02Z",<br/>events: [CreatedEvent{contract_id: "00a3f2..."}]}

    Note over Orch,IL: PHASE 6 — Off-Chain Finalization

    Orch->>IL: PUT /v1/tokens/TXN-MINT-20260301-A7F3/status<br/>{status: "MINTED", contract_id: "00a3f2...",<br/>canton_tx_id: "tx-abc123", offset: "000000000042"}
    IL->>IL: Update position: PENDING_MINT to MINTED<br/>Record on-chain contract_id + tx_id
    IL-->>ITS: Confirmation callback
    ITS-->>Client: Mint Complete — 5M deposit_token instrument issued on Registry Utility
```

---

## 2. Detailed Internal — PrepareSubmission to Signing

Zoomed-in view of the Orchestrator's internal flow from constructing the Daml command, requesting a prepared transaction from Blockdaemon, through to signing via the Transit Engine (vault-as-a-service) and assembling the signature envelope for execution.

```mermaid
sequenceDiagram
    autonumber
    participant Kafka as Event Bus (Kafka)
    participant Orch as Token Orchestrator
    participant BD as Blockdaemon<br/>Validator Node
    participant Transit as Transit Engine<br/>(Signing-as-a-Service)

    Note over Kafka,Orch: Trigger

    Kafka->>Orch: Consume MintRequested event<br/>{txn_ref: "TXN-MINT-20260301-A7F3",<br/>owner: "acme", amount: 5000000}

    Note over Orch,Transit: STEP 1 — Onboard Signing Keys

    Orch->>Transit: POST /v1/api/onboard-keys<br/>{key_name: "canton-signing-key",<br/>key_type: "ecdsa-p256",<br/>usage: "signing"}
    Transit-->>Orch: 200 OK<br/>{key_name: "canton-signing-key",<br/>public_key: "MFkwEwYHKoZIzj0C...",<br/>key_version: 3,<br/>fingerprint: "fp:ab12cd..."}
    Orch->>Orch: Cache key metadata<br/>Verify fingerprint matches Canton topology

    Note over Orch: STEP 2 — Build Daml Command

    Orch->>Orch: Resolve party identifiers from config<br/>issuer = "bank::issuer"<br/>owner = "acme_corp::ns_acme"
    Orch->>Orch: Construct CreateCommand<br/>template: RegistryUtility.Instrument (deposit_token)<br/>args: {issuer, owner, amount: 5000000,<br/>currency: "USD", registry: "RegistryUtility"}
    Orch->>Orch: Assign command metadata<br/>command_id: "CMD-MINT-20260301-A7F3E9"<br/>workflow_id: "WF-MINT-TXN-A7F3"<br/>dedupliation_period: 24h

    Note over Orch,BD: STEP 3 — Request Prepared Transaction

    Orch->>BD: InteractiveSubmissionService.PrepareSubmission<br/>{commands: [CreateCommand],<br/>act_as: ["bank::issuer"],<br/>command_id, workflow_id}
    BD->>BD: Validate command + interpret Daml<br/>Compute transaction tree<br/>Decompose into participant views
    BD-->>Orch: PreparedTransaction<br/>{prepared_transaction_data: bytes,<br/>transaction_hash: 0xa3f2b1...(32 bytes),<br/>hash_algorithm: "SHA256",<br/>signature_requirements: [{<br/>  party: "bank::issuer",<br/>  key_fingerprints: ["fp:ab12cd..."]}],<br/>cost_estimation: {traffic_cost_bytes: 1024}}

    Orch->>Orch: Record prepare_timestamp = now()<br/>Start 30s expiry countdown

    Note over Orch,Transit: STEP 4 — Sign via Transit Engine

    Orch->>Orch: Extract transaction_hash (32 bytes SHA-256)<br/>Base64-encode: b64_hash = base64(0xa3f2b1...)
    Orch->>Orch: Resolve signing key name from config<br/>key_name = "canton-signing-key"

    Orch->>Transit: POST /v1/transit/sign/{key_name}<br/>{input: "{b64_hash}",<br/>hash_algorithm: "sha2-256",<br/>prehashed: true,<br/>marshaling_algorithm: "asn1"}
    Transit-->>Orch: 200 OK<br/>{data: {<br/>  signature: "vault:v1:MEUCIQDh8kF2n...",<br/>  key_version: 3}}

    Note over Orch: STEP 5 — Assemble Signature Envelope

    Orch->>Orch: Strip "vault:v1:" prefix<br/>Base64-decode to raw DER bytes<br/>(ASN.1 SEQUENCE of two INTEGERs: r, s)
    Orch->>Orch: Look up key fingerprint from Canton topology<br/>key_fp = "fp:ab12cd..."
    Orch->>Orch: Check elapsed time since prepare<br/>If >= 25s → must re-Prepare before Execute

    Orch->>Orch: Construct PartySignatures envelope:<br/>{party: "bank::issuer",<br/>signatures: [{<br/>  signature: raw_DER_bytes,<br/>  signed_by: "fp:ab12cd...",<br/>  format: SIGNATURE_FORMAT_RAW}]}

    Note over Orch: Ready for ExecuteSubmission →<br/>See Section 1 Phase 4
```

---

## 3. Error Flow — Vault Signing Failures

```mermaid
sequenceDiagram
    autonumber
    participant Orch as Token Orchestrator
    participant Vault as HashiCorp Vault
    participant IL as Internal Ledger
    participant Alert as Alert System (PagerDuty)

    Note over Orch: Vault signing attempt after PrepareSubmission

    alt 403 Forbidden — Token expired or policy denied
        Orch->>Vault: POST /v1/transit/sign/canton-signing-key
        Vault-->>Orch: 403 {errors: ["permission denied"]}
        Orch->>Orch: Error: KMS-6001 VAULT_AUTH_FAILURE
        Orch->>Orch: Attempt AppRole re-authentication
        Orch->>Vault: POST /v1/auth/approle/login<br/>{role_id, secret_id}
        alt Re-auth succeeds
            Vault-->>Orch: 200 {auth: {client_token: "hvs.new..."}}
            Orch->>Vault: POST /v1/transit/sign/canton-signing-key<br/>(with new token)
            Vault-->>Orch: 200 {data: {signature: "vault:v1:..."}}
            Note over Orch: Resume normal flow
        else Re-auth fails
            Vault-->>Orch: 403
            Orch->>IL: PATCH /v1/tokens/{txn_ref}/status<br/>{status: "MINT_FAILED", error: "KMS-6001"}
            Orch->>Alert: CRITICAL: Vault auth failure<br/>All signing operations halted
            Note over Orch: Circuit breaker OPEN — halt mint operations
        end

    else 404 Not Found — Key doesn't exist
        Orch->>Vault: POST /v1/transit/sign/canton-signing-key
        Vault-->>Orch: 404 {errors: ["key not found"]}
        Orch->>Orch: Error: KMS-6002 KEY_NOT_FOUND
        Orch->>IL: PATCH /v1/tokens/{txn_ref}/status<br/>{status: "MINT_FAILED", error: "KMS-6002"}
        Orch->>Alert: CRITICAL: Canton signing key missing<br/>Possible misconfiguration or key deletion
        Note over Orch: No retry — requires manual investigation

    else 429 Rate Limited
        Orch->>Vault: POST /v1/transit/sign/canton-signing-key
        Vault-->>Orch: 429 Too Many Requests
        Orch->>Orch: Error: KMS-6003 RATE_LIMITED
        loop Retry with exponential backoff (max 3 attempts)
            Orch->>Orch: Wait: 200ms, 400ms, 800ms
            Orch->>Vault: POST /v1/transit/sign/canton-signing-key
            alt Success
                Vault-->>Orch: 200 {data: {signature: "vault:v1:..."}}
                Note over Orch: Resume normal flow
            else Still rate limited
                Vault-->>Orch: 429
            end
        end
        Orch->>IL: PATCH /v1/tokens/{txn_ref}/status<br/>{status: "MINT_FAILED", error: "KMS-6003"}
        Orch->>Alert: WARN: Vault rate limit — check request volume

    else 500/503 — Vault or HSM unavailable
        Orch->>Vault: POST /v1/transit/sign/canton-signing-key
        Vault-->>Orch: 503 Service Unavailable
        Orch->>Orch: Error: KMS-6004 HSM_UNAVAILABLE
        loop Retry with exponential backoff (max 3, 500ms base)
            Orch->>Orch: Wait: 500ms, 1s, 2s
            Orch->>Vault: POST /v1/transit/sign/canton-signing-key
            alt Vault recovers
                Vault-->>Orch: 200 {data: {signature: "vault:v1:..."}}
                Note over Orch: Resume normal flow
            else Still down
                Vault-->>Orch: 503
            end
        end
        Orch->>IL: PATCH /v1/tokens/{txn_ref}/status<br/>{status: "MINT_FAILED", error: "KMS-6004"}
        Orch->>Alert: CRITICAL: HSM/Vault cluster unavailable

    else Timeout (>5s signing latency)
        Orch->>Vault: POST /v1/transit/sign/canton-signing-key
        Note over Vault: HSM latency spike or network issue
        Orch->>Orch: Timeout after 5s<br/>Error: KMS-6005 SIGNING_TIMEOUT
        Orch->>Orch: WARNING: PreparedTransaction may expire<br/>(30s window from PrepareSubmission)
        Orch->>Orch: Retry once with 3s timeout
        alt Retry succeeds within total 30s window
            Orch->>Vault: POST /v1/transit/sign/canton-signing-key
            Vault-->>Orch: 200 {data: {signature: "vault:v1:..."}}
            Note over Orch: Check elapsed time since Prepare<br/>If < 25s: proceed to Execute<br/>If >= 25s: re-Prepare first
        else Retry fails or 30s window exceeded
            Orch->>Orch: PreparedTransaction likely expired
            Orch->>IL: PATCH /v1/tokens/{txn_ref}/status<br/>{status: "MINT_FAILED", error: "KMS-6005"}
            Orch->>Alert: WARN: Vault signing timeout — check HSM health
        end
    end
```

---

## 4. Error Flow — PrepareSubmission Failures

```mermaid
sequenceDiagram
    autonumber
    participant Orch as Token Orchestrator
    participant BD as Blockdaemon<br/>Validator Node
    participant IL as Internal Ledger
    participant Alert as Alert System

    Note over Orch,BD: Orchestrator sends PrepareSubmission to Blockdaemon

    alt INVALID_ARGUMENT — Malformed Daml command
        Orch->>BD: PrepareSubmission(commands)
        BD-->>Orch: PrepareError<br/>{code: INVALID_ARGUMENT,<br/>message: "Template Instrument field 'amount' must be > 0"}
        Orch->>Orch: Error: BD-7001 INVALID_COMMAND
        Orch->>IL: PATCH status: MINT_FAILED<br/>{error: "BD-7001", detail: "invalid amount"}
        Note over Orch: No retry — payload must be fixed upstream

    else PARTY_NOT_AUTHORIZED — act_as party not hosted
        Orch->>BD: PrepareSubmission(act_as: ["bank::issuer"])
        BD-->>Orch: PrepareError<br/>{code: PARTY_NOT_AUTHORIZED,<br/>message: "Party bank::issuer not hosted on this participant"}
        Orch->>Orch: Error: BD-7002 PARTY_NOT_HOSTED
        Orch->>IL: PATCH status: MINT_FAILED<br/>{error: "BD-7002"}
        Orch->>Alert: CRITICAL: Party hosting configuration error
        Note over Orch: No retry — topology misconfiguration

    else PACKAGE_NOT_FOUND — Daml package not uploaded
        Orch->>BD: PrepareSubmission(commands)
        BD-->>Orch: PrepareError<br/>{code: PACKAGE_NOT_FOUND,<br/>message: "Package RegistryUtility-1.0 not found"}
        Orch->>Orch: Error: BD-7003 PACKAGE_MISSING
        Orch->>IL: PATCH status: MINT_FAILED<br/>{error: "BD-7003"}
        Orch->>Alert: CRITICAL: Registry Utility Daml package not deployed<br/>Upload via PackageManagementService
        Note over Orch: No retry — package must be uploaded

    else gRPC UNAVAILABLE — Blockdaemon node unreachable
        Orch->>BD: PrepareSubmission(commands)
        BD-->>Orch: gRPC Status: UNAVAILABLE
        Orch->>Orch: Error: BD-7010 NODE_UNAVAILABLE
        loop Exponential backoff (max 3, 100ms base, jitter 0.2)
            Orch->>Orch: Wait: ~100ms, ~200ms, ~400ms
            Orch->>BD: PrepareSubmission(commands) [retry]
            alt Node recovers
                BD-->>Orch: PreparedTransaction
                Note over Orch: Resume: proceed to Vault signing
            else Still unavailable
                BD-->>Orch: gRPC UNAVAILABLE
            end
        end
        Orch->>IL: PATCH status: MINT_FAILED<br/>{error: "BD-7010"}
        Orch->>Alert: CRITICAL: Blockdaemon node unreachable

    else gRPC DEADLINE_EXCEEDED — Prepare timed out
        Orch->>BD: PrepareSubmission(commands)
        Note over BD: Daml interpretation taking too long<br/>(complex contract graph)
        BD-->>Orch: gRPC Status: DEADLINE_EXCEEDED
        Orch->>Orch: Error: BD-7011 PREPARE_TIMEOUT
        Orch->>BD: PrepareSubmission(commands) [retry once]
        alt Success
            BD-->>Orch: PreparedTransaction
            Note over Orch: Resume normal flow
        else Timeout again
            BD-->>Orch: gRPC DEADLINE_EXCEEDED
            Orch->>IL: PATCH status: MINT_FAILED<br/>{error: "BD-7011"}
            Orch->>Alert: WARN: Prepare timeout — check node performance
        end
    end
```

---

## 5. Error Flow — Prepared TX Expiry

The PreparedTransaction is cached in the validator's memory for ~30 seconds. If Vault signing or any intermediate step exceeds this window, ExecuteSubmission will fail with `PREPARED_TX_NOT_FOUND`. The Orchestrator must detect this and re-Prepare.

```mermaid
sequenceDiagram
    autonumber
    participant Orch as Token Orchestrator
    participant Vault as HashiCorp Vault
    participant BD as Blockdaemon<br/>Validator Node
    participant SEQ as Canton Sequencer
    participant IL as Internal Ledger

    Orch->>BD: PrepareSubmission(commands)
    BD-->>Orch: PreparedTransaction<br/>{transaction_hash: 0xa3f2b1...}
    Orch->>Orch: Record prepare_timestamp = T0

    Orch->>Vault: POST /v1/transit/sign/canton-signing-key
    Note over Vault: Slow response — HSM latency spike<br/>or multi-approval policy delay
    Vault-->>Orch: 200 OK (signature) — but took 28 seconds

    Orch->>Orch: Check elapsed: now - T0 = 28s<br/>WARNING: approaching 30s expiry
    Orch->>Orch: Elapsed >= 25s threshold<br/>Decision: prepared tx likely expired or about to

    alt Strategy A: Attempt Execute anyway (elapsed < 30s)
        Orch->>BD: ExecuteSubmission(prepared_tx, signature)
        BD-->>Orch: ExecuteError<br/>{code: PREPARED_TX_NOT_FOUND,<br/>message: "No prepared transaction found for hash"}
        Note over Orch: Confirmed: prepared tx expired
    end

    Note over Orch,BD: RECOVERY: Re-Prepare with same command_id

    Orch->>BD: PrepareSubmission(commands)<br/>[same command_id for idempotency]
    BD-->>Orch: PreparedTransaction<br/>{transaction_hash: 0xb4e3c2...(new hash)}
    Orch->>Orch: Record new prepare_timestamp = T1

    Note over Orch: Signature from old hash is INVALID for new hash<br/>Must re-sign with the new transaction_hash

    Orch->>Vault: POST /v1/transit/sign/canton-signing-key<br/>{input: b64(0xb4e3c2...), prehashed: true}
    Vault-->>Orch: 200 OK {signature: "vault:v1:MEYCIQDx..."}
    Orch->>Orch: Elapsed since T1: 2s (well within 30s)

    Orch->>BD: ExecuteSubmission(new_prepared_tx, new_signature)
    BD->>BD: Verify signature + encrypt views
    BD->>SEQ: ConfirmationRequest
    SEQ-->>BD: Verdict: APPROVED
    BD-->>Orch: TransactionResult {transaction_id: "tx-def456"}

    Orch->>IL: PATCH status: MINTED<br/>{canton_tx_id: "tx-def456"}
    Note over Orch: Recovery successful

    Note over Orch,IL: If re-Prepare also fails or total retries > 2:<br/>Mark MINT_FAILED, alert ops team
```

---

## 6. Error Flow — ExecuteSubmission Failures

```mermaid
sequenceDiagram
    autonumber
    participant Orch as Token Orchestrator
    participant BD as Blockdaemon<br/>Validator Node
    participant SEQ as Canton Sequencer
    participant IL as Internal Ledger
    participant Alert as Alert System

    Note over Orch,BD: Orchestrator calls ExecuteSubmission with signed tx

    alt INVALID_SIGNATURE — Signature doesn't match registered key
        Orch->>BD: ExecuteSubmission(prepared_tx, signatures)
        BD->>BD: Verify signature against<br/>public key in Canton topology
        BD-->>Orch: ExecuteError<br/>{code: INVALID_SIGNATURE,<br/>message: "Signature verification failed for fp:ab12cd"}
        Orch->>Orch: Error: BD-7020 SIGNATURE_MISMATCH
        Orch->>IL: PATCH status: MINT_FAILED<br/>{error: "BD-7020"}
        Orch->>Alert: CRITICAL: Signature mismatch<br/>Vault key may be out of sync with Canton topology
        Note over Orch: No retry — key registration must be verified<br/>Check: Vault key version matches OwnerToKeyMapping

    else SIGNATURE_KEY_UNKNOWN — Fingerprint not in topology
        Orch->>BD: ExecuteSubmission(prepared_tx, signatures)
        BD-->>Orch: ExecuteError<br/>{code: SIGNATURE_KEY_UNKNOWN,<br/>message: "Key fp:xy99zz not registered"}
        Orch->>Orch: Error: BD-7021 KEY_NOT_REGISTERED
        Orch->>IL: PATCH status: MINT_FAILED<br/>{error: "BD-7021"}
        Orch->>Alert: CRITICAL: Signing key not in Canton topology<br/>Register via OwnerToKeyMapping topology tx
        Note over Orch: No retry — topology admin must register key

    else PREPARED_TX_NOT_FOUND — Expired (>30s)
        Orch->>BD: ExecuteSubmission(prepared_tx, signatures)
        BD-->>Orch: ExecuteError<br/>{code: PREPARED_TX_NOT_FOUND}
        Note over Orch: See Section 5 for full recovery flow
        Orch->>Orch: Initiate re-Prepare + re-Sign cycle

    else SEQUENCER_UNAVAILABLE — Canton sequencer down
        Orch->>BD: ExecuteSubmission(prepared_tx, signatures)
        BD->>BD: Verify signature (OK)
        BD->>BD: Encrypt views (OK)
        BD->>SEQ: ConfirmationRequest
        Note over SEQ: Sequencer unreachable
        BD-->>Orch: ExecuteError<br/>{code: SEQUENCER_UNAVAILABLE}
        Orch->>Orch: Error: BD-7030 SEQUENCER_DOWN
        loop Retry with backoff (max 3, 1s base)
            Note over Orch: Prepared tx may still be in memory<br/>if within 30s window
            Orch->>BD: ExecuteSubmission(prepared_tx, signatures) [retry]
            alt Sequencer recovers
                BD->>SEQ: ConfirmationRequest
                SEQ-->>BD: Verdict: APPROVED
                BD-->>Orch: TransactionResult
                Note over Orch: Success — resume finalization
            else Still unavailable
                BD-->>Orch: SEQUENCER_UNAVAILABLE
            end
        end
        Orch->>IL: PATCH status: MINT_FAILED<br/>{error: "BD-7030"}
        Orch->>Alert: CRITICAL: Canton sequencer unavailable

    else TRAFFIC_LIMIT_EXCEEDED — Insufficient Canton Coin
        Orch->>BD: ExecuteSubmission(prepared_tx, signatures)
        BD-->>Orch: ExecuteError<br/>{code: TRAFFIC_LIMIT_EXCEEDED,<br/>message: "Insufficient traffic credit: need 1024, have 512"}
        Orch->>Orch: Error: BD-7040 INSUFFICIENT_TRAFFIC
        Orch->>IL: PATCH status: MINT_FAILED<br/>{error: "BD-7040"}
        Orch->>Alert: WARN: Canton Coin balance low<br/>Top up via Global Synchronizer
        Note over Orch: No retry — requires CC top-up
    end
```

---

## 7. Error Flow — Canton Protocol Rejection

Failures that occur after the transaction has been submitted to the Canton network (post-sequencer).

```mermaid
sequenceDiagram
    autonumber
    participant Orch as Token Orchestrator
    participant BD as Blockdaemon<br/>Validator Node
    participant SEQ as Canton Sequencer
    participant VAL as Stakeholder<br/>Validators
    participant MED as Canton Mediator
    participant IL as Internal Ledger
    participant Alert as Alert System

    Orch->>BD: ExecuteSubmission(prepared_tx, signatures)
    BD->>SEQ: ConfirmationRequest (encrypted envelopes)
    SEQ->>SEQ: Assign timestamp

    par Distribute
        SEQ->>VAL: Encrypted views
        SEQ->>MED: Encrypted metadata
    end

    alt LocalReject — Credential validation failed
        VAL->>VAL: Decrypt views
        VAL->>VAL: Execute Daml locally
        VAL->>VAL: Fetch owner Credential from ACS
        Note over VAL: Credential check FAILS<br/>(expired, suspended, wrong token type, or missing)
        VAL->>SEQ: ConfirmationResponse<br/>(LocalReject: CREDENTIAL_VALIDATION_FAILED)
        SEQ->>MED: Forward rejection
        MED->>MED: Rejection received<br/>Compute REJECT verdict
        MED->>SEQ: ConfirmationResultMessage (REJECT)
        par Distribute verdict
            SEQ->>BD: Verdict: REJECTED
            SEQ->>VAL: Verdict: REJECTED
        end
        BD-->>Orch: ExecuteError<br/>{code: MEDIATOR_REJECT,<br/>reason: "LocalReject: CREDENTIAL_VALIDATION_FAILED",<br/>party: "acme_corp::ns_acme"}

        Orch->>Orch: Error: CN-8001 CREDENTIAL_REJECTED
        Orch->>IL: PATCH status: MINT_FAILED<br/>{error: "CN-8001",<br/>detail: "owner credential expired/suspended"}
        Orch->>Alert: WARN: Mint rejected — credential issue<br/>Owner: acme_corp, Reason: CREDENTIAL_EXPIRED
        Note over Orch: No retry — credential must be renewed first<br/>Orchestrator may trigger credential refresh workflow

    else LocalReject — Sanctions violation
        VAL->>VAL: Decrypt + validate
        VAL->>VAL: Check jurisdiction against sanctions list
        Note over VAL: Jurisdiction flagged
        VAL->>SEQ: ConfirmationResponse<br/>(LocalReject: SANCTIONS_VIOLATION)
        SEQ->>MED: Forward rejection
        MED->>SEQ: ConfirmationResultMessage (REJECT)
        SEQ->>BD: Verdict: REJECTED
        BD-->>Orch: ExecuteError<br/>{code: MEDIATOR_REJECT,<br/>reason: "SANCTIONS_VIOLATION"}

        Orch->>Orch: Error: CN-8002 SANCTIONS_BLOCK
        Orch->>IL: PATCH status: MINT_FAILED<br/>{error: "CN-8002", detail: "sanctions hit"}
        Orch->>Alert: CRITICAL: Sanctions violation detected<br/>Escalate to Compliance immediately
        Note over Orch: NO retry — compliance escalation required

    else MediatorReject — Conflict detection (double-spend)
        VAL->>VAL: Decrypt + validate
        VAL->>VAL: Attempt to lock input contracts
        Note over VAL: Contract already locked by concurrent tx
        VAL->>SEQ: ConfirmationResponse (LocalReject: CONTRACT_LOCKED)
        SEQ->>MED: Forward
        MED->>SEQ: REJECT
        SEQ->>BD: Verdict: REJECTED
        BD-->>Orch: ExecuteError<br/>{code: MEDIATOR_REJECT,<br/>reason: "CONFLICT_DETECTION"}

        Orch->>Orch: Error: CN-8003 CONTENTION
        Orch->>IL: PATCH status: MINT_FAILED<br/>{error: "CN-8003"}
        Note over Orch: For mint (create): contention is rare<br/>For transfer/redeem: may retry with fresh ACS read

    else Timeout — Mediator didn't respond in time
        VAL->>SEQ: ConfirmationResponse (LocalApprove)
        SEQ->>MED: Forward
        Note over MED: Mediator overloaded or partitioned<br/>No verdict within 30s
        BD-->>Orch: ExecuteError<br/>{code: TIMEOUT,<br/>message: "No mediator verdict within deadline"}

        Orch->>Orch: Error: CN-8010 VERDICT_TIMEOUT
        Orch->>Orch: Check CompletionStream for async result
        Orch->>BD: CompletionService.CompletionStream<br/>{command_id: "CMD-MINT-20260301-A7F3E9"}

        alt Late completion arrives
            BD-->>Orch: Completion {status: OK, tx_id: "tx-abc123"}
            Orch->>IL: PATCH status: MINTED
            Note over Orch: Transaction succeeded despite timeout
        else No completion found
            Orch->>Orch: Retry once with NEW command_id<br/>(to avoid duplicate if original eventually commits)
            Orch->>BD: PrepareSubmission (new cmd_id)<br/>→ Sign → ExecuteSubmission
            alt Retry succeeds
                BD-->>Orch: TransactionResult
                Orch->>IL: PATCH status: MINTED
            else Retry also times out
                Orch->>IL: PATCH status: MINT_FAILED<br/>{error: "CN-8010"}
                Orch->>Alert: CRITICAL: Canton mediator timeout<br/>Check synchronizer health
            end
        end
    end
```

---

## 8. Rollback & Compensation

When a mint fails after off-chain settlement has already occurred (DDA debited, reserve credited), the system must reverse the off-chain positions.

```mermaid
sequenceDiagram
    autonumber
    participant Orch as Token Orchestrator
    participant IL as Internal Ledger
    participant ITS as Core Banking
    participant Alert as Alert System

    Note over Orch: Mint failed at any on-chain stage<br/>(Vault error, Blockdaemon error, Canton rejection)

    Orch->>IL: PATCH /v1/tokens/{txn_ref}/status<br/>{status: "MINT_FAILED", error_code, error_detail}

    IL->>IL: Check position state: PENDING_MINT
    IL->>IL: Create compensation entry:<br/>REVERSAL of original mint position

    rect rgb(255, 240, 240)
        Note over IL,ITS: Off-Chain Reversal
        IL->>ITS: POST /v1/reversals<br/>{original_txn_ref, reason: "MINT_FAILED",<br/>error_code: "CN-8001"}
        ITS->>ITS: Credit DDA (Acme) $5M<br/>(reverse the debit)
        ITS->>ITS: Debit Reserve Account $5M<br/>(reverse the credit)
        ITS-->>IL: Reversal confirmed<br/>{reversal_ref: "REV-20260301-B8G4"}
    end

    IL->>IL: Update position:<br/>PENDING_MINT to REVERSED<br/>Link reversal_ref

    alt Auto-retry eligible (transient errors only)
        Note over Orch: Errors BD-7010, BD-7011, KMS-6003,<br/>KMS-6004, CN-8010 may be retried
        Orch->>Orch: Schedule retry after cooldown (30s)
        Orch->>ITS: New mint initiation<br/>(fresh txn_ref, new DDA debit)
        Note over Orch: Full flow restarts from Phase 1
    else Non-retryable (config/credential/sanctions errors)
        Note over Orch: Errors KMS-6001, KMS-6002, BD-7001,<br/>BD-7002, BD-7003, CN-8001, CN-8002
        Orch->>Alert: Mint failed — manual intervention required<br/>{txn_ref, error_code, owner, amount}
        Note over Orch: Halt — awaiting operator resolution
    end
```

---

## 9. Error Decision Matrix

Summary of all error codes, their source, retryability, and required action.

| Code | Error | Source | Retryable | Max Retries | Action |
|---|---|---|---|---|---|
| **KMS-6001** | Vault auth failure | Vault 403 | Re-auth once | 1 | Re-authenticate AppRole; if fails, circuit break + alert InfoSec |
| **KMS-6002** | Key not found | Vault 404 | No | 0 | Alert InfoSec — verify key name and Transit engine config |
| **KMS-6003** | Rate limited | Vault 429 | Yes | 3 | Exponential backoff (200ms base); consider Vault perf replication |
| **KMS-6004** | HSM unavailable | Vault 503 | Yes | 3 | Backoff (500ms base); check Vault cluster health |
| **KMS-6005** | Signing timeout | Vault >5s | Yes | 1 | Re-sign; if total > 25s, re-Prepare first |
| **BD-7001** | Invalid command | Prepare INVALID_ARGUMENT | No | 0 | Fix Daml command payload upstream |
| **BD-7002** | Party not hosted | Prepare PARTY_NOT_AUTHORIZED | No | 0 | Verify topology — party hosting on Blockdaemon node |
| **BD-7003** | Package missing | Prepare PACKAGE_NOT_FOUND | No | 0 | Upload Daml package via admin API |
| **BD-7010** | Node unavailable | Prepare gRPC UNAVAILABLE | Yes | 3 | Backoff (100ms base, jitter 0.2) |
| **BD-7011** | Prepare timeout | Prepare DEADLINE_EXCEEDED | Yes | 1 | Retry once; check node performance |
| **BD-7020** | Signature mismatch | Execute INVALID_SIGNATURE | No | 0 | Verify Vault key version matches Canton topology |
| **BD-7021** | Key not registered | Execute SIGNATURE_KEY_UNKNOWN | No | 0 | Register public key via OwnerToKeyMapping |
| **BD-7030** | Sequencer down | Execute SEQUENCER_UNAVAILABLE | Yes | 3 | Backoff (1s base); check Canton sequencer status |
| **BD-7040** | Traffic exceeded | Execute TRAFFIC_LIMIT_EXCEEDED | No | 0 | Top up Canton Coin balance |
| **CN-8001** | Credential rejected | Canton LocalReject | No | 0 | Renew/reactivate owner credential |
| **CN-8002** | Sanctions violation | Canton LocalReject | No | 0 | Escalate to Compliance — do NOT retry |
| **CN-8003** | Conflict/contention | Canton MediatorReject | Conditional | 1 | Rare for mint; retry with fresh ACS read for transfer/redeem |
| **CN-8010** | Verdict timeout | Canton Timeout | Yes | 1 | Check CompletionStream first; retry with new command_id |
