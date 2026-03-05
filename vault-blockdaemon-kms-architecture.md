# Key Management Architecture: HashiCorp Vault & Blockdaemon

## Canton Network | Internal KMS (Vault) | Blockdaemon Node Services

**Version 1.0 | March 2026 | CONFIDENTIAL — Internal Use Only**

---

## 1. Overview

This document describes the interaction model between the bank's internal HashiCorp Vault (KMS) and Blockdaemon's Canton validator node infrastructure. The core principle is **key sovereignty**: the bank holds the root namespace key and all cryptographic material in Vault, while Canton (via Blockdaemon) holds only the operational references needed to invoke the Vault signing API. All transaction signing occurs internally — no private key material ever leaves the bank's trust boundary.

---

## 2. Key Hierarchy

The bank maintains a hierarchical key structure within Vault. The root namespace key is the apex of trust; all subordinate keys derive their authority from it.

```mermaid
graph TD
    subgraph VAULT["🔐 HashiCorp Vault (Bank-Operated)"]
        direction TB
        ROOT["<b>Root Namespace Key</b><br/>Ed25519 / RSA-4096<br/>Cold Storage · Air-Gapped HSM<br/>Used ONCE: bootstrap Canton identity"]

        subgraph SIGNING["Transit Secrets Engine — Signing Keys"]
            direction LR
            NSK["<b>Namespace Signing Key</b><br/>ECDSA P-256<br/>Signs topology txns<br/>(party registration,<br/>key rotation)"]
            TSK["<b>Transaction Signing Key</b><br/>ECDSA P-256<br/>Signs Daml commands<br/>(mint, transfer, redeem)"]
            ASK["<b>Authentication Key</b><br/>ECDSA P-256<br/>mTLS client cert<br/>for Ledger API"]
        end

        subgraph ENCRYPTION["Transit Secrets Engine — Encryption Keys"]
            direction LR
            VEK["<b>View Encryption Key</b><br/>AES-256-GCM / HPKE<br/>Encrypts transaction<br/>view payloads"]
            SEK["<b>Storage Encryption Key</b><br/>AES-256-GCM<br/>Encrypts PCS data<br/>at rest"]
        end

        ROOT -->|"delegates authority"| NSK
        ROOT -->|"delegates authority"| TSK
        ROOT -->|"delegates authority"| ASK
        ROOT -->|"delegates authority"| VEK
        ROOT -->|"delegates authority"| SEK
    end

    style VAULT fill:#f7f3ff,stroke:#7c3aed,stroke-width:3px
    style ROOT fill:#dc2626,stroke:#333,color:#fff
    style NSK fill:#ea580c,stroke:#333,color:#fff
    style TSK fill:#ea580c,stroke:#333,color:#fff
    style ASK fill:#ea580c,stroke:#333,color:#fff
    style VEK fill:#2563eb,stroke:#333,color:#fff
    style SEK fill:#2563eb,stroke:#333,color:#fff
```

### Key Roles

| Key | Purpose | Stored In | Used By | Rotation |
|---|---|---|---|---|
| **Root Namespace Key** | Bootstrap Canton identity; anchor of trust for the bank's namespace | Air-gapped HSM via Vault | Used once at onboarding, then cold storage | Manual ceremony (multi-custodian Shamir) |
| **Namespace Signing Key** | Sign topology transactions (party registration, key rotation, delegation) | Vault Transit Engine | Token Orchestrator | Automated (90-day), announced via topology txn |
| **Transaction Signing Key** | Sign Daml commands submitted to Ledger API | Vault Transit Engine | Token Orchestrator / Signing Module | Automated (30-day) |
| **Authentication Key** | mTLS client certificate for gRPC connection to Blockdaemon Ledger API | Vault PKI Engine | Token Orchestrator | Automated (24h short-lived certs) |
| **View Encryption Key** | Encrypt/decrypt Canton transaction views (privacy envelopes) | Vault Transit Engine | Blockdaemon Validator (via KMS API) | Automated (90-day) |
| **Storage Encryption Key** | Encrypt PCS contract data at rest in PostgreSQL | Vault Transit Engine | Blockdaemon Validator (via KMS API) | Automated (180-day) |

---

## 3. Trust Boundary Model

```mermaid
graph LR
    subgraph BANK["🔒 Bank Trust Boundary"]
        direction TB
        VAULT_SVC["<b>HashiCorp Vault</b><br/>Transit + PKI Engines<br/>FIPS 140-2 Level 3 HSM Backend"]
        SIGNER["<b>Signing Module</b><br/>Stateless Microservice<br/>Constructs & Signs Payloads"]
        ORCH["<b>Token Orchestrator</b><br/>Command Builder<br/>Event Consumer"]
        AUDIT["<b>Audit Log</b><br/>Every sign/decrypt op<br/>Tamper-evident"]

        ORCH --> SIGNER
        SIGNER -->|"vault transit/sign"| VAULT_SVC
        VAULT_SVC --> AUDIT
    end

    subgraph BD["☁️ Blockdaemon Trust Boundary"]
        direction TB
        LAPI["<b>Ledger API</b><br/>gRPC/TLS<br/>Command & Transaction Services"]
        VALIDATOR["<b>Canton Validator Node</b><br/>JVM/Scala · K8s<br/>Daml Engine · PCS · ACJ"]
        PG["<b>PostgreSQL</b><br/>Encrypted at rest<br/>(bank-held keys)"]

        LAPI --- VALIDATOR
        VALIDATOR --- PG
    end

    subgraph CANTON["🔗 Canton Network"]
        direction TB
        SEQ["<b>Sequencer</b><br/>Total-Order Multicast"]
        MED["<b>Mediator</b><br/>Confirmation Protocol"]
    end

    SIGNER -->|"signed command<br/>(gRPC/mTLS)"| LAPI
    LAPI -->|"unsigned txn<br/>(PrepareSubmission)"| SIGNER
    VALIDATOR -->|"KMS API call<br/>(encrypt/decrypt)"| VAULT_SVC
    VALIDATOR -->|"encrypted envelopes"| SEQ
    SEQ <--> MED

    style BANK fill:#ecfdf5,stroke:#059669,stroke-width:3px
    style BD fill:#fff7ed,stroke:#ea580c,stroke-width:3px
    style CANTON fill:#eff6ff,stroke:#2563eb,stroke-width:3px
    style VAULT_SVC fill:#dc2626,stroke:#333,color:#fff
    style SIGNER fill:#7c3aed,stroke:#333,color:#fff
    style SEQ fill:#2563eb,stroke:#333,color:#fff
    style MED fill:#ea580c,stroke:#333,color:#fff
```

### What Each Boundary Controls

| Aspect | Bank Controls | Blockdaemon Controls | Canton Network |
|---|---|---|---|
| **Private Key Material** | All keys — Vault only | None — zero access | None |
| **Signing Operations** | Every sign op goes through Vault | Requests signing via KMS API | N/A |
| **Decryption** | All decrypt via Vault Transit | Requests decrypt via KMS API | N/A |
| **Validator Compute** | Defines config, monitors SLA | Operates JVM, K8s, PostgreSQL | N/A |
| **Consensus** | Participates via validator | Hosts the infrastructure | Sequencer + Mediator |
| **Contract Data** | Encrypted with bank keys | Stores ciphertext only | Sees encrypted envelopes only |

---

## 4. Transaction Signing Flow

This is the core interaction: a transaction is retrieved from the Blockdaemon node via Ledger API, signed internally using the Vault-backed Signing Module, and submitted back through Ledger API with the signed payload.

```mermaid
sequenceDiagram
    autonumber
    participant ORCH as Token Orchestrator
    participant SIGNER as Signing Module
    participant VAULT as HashiCorp Vault
    participant LAPI as Ledger API<br/>(Blockdaemon)
    participant VALIDATOR as Canton Validator<br/>(Blockdaemon)
    participant CANTON as Canton Network<br/>(Sequencer + Mediator)

    Note over ORCH: Domain event received<br/>(e.g. MintRequested)

    ORCH->>LAPI: 1. PrepareSubmission(DamlCommand)
    activate LAPI
    LAPI->>VALIDATOR: Parse & validate command
    VALIDATOR-->>LAPI: Unsigned transaction envelope
    LAPI-->>ORCH: PreparedSubmission {txn_hash, serialized_txn}
    deactivate LAPI

    ORCH->>SIGNER: 2. Sign(txn_hash, key_ref="txn-signing-key")
    activate SIGNER
    SIGNER->>VAULT: POST /v1/transit/sign/txn-signing-key
    activate VAULT
    Note over VAULT: ECDSA P-256 sign<br/>HSM-backed operation<br/>Audit log written
    VAULT-->>SIGNER: {signature, key_version}
    deactivate VAULT
    SIGNER-->>ORCH: SignedPayload {signature, key_version, algorithm}
    deactivate SIGNER

    ORCH->>LAPI: 3. ExecuteSubmission(serialized_txn, signature)
    activate LAPI
    LAPI->>VALIDATOR: Submit signed transaction
    VALIDATOR->>CANTON: Encrypted envelopes via Sequencer
    activate CANTON
    Note over CANTON: Confirmation Protocol<br/>Mediator collects responses<br/>Issues verdict
    CANTON-->>VALIDATOR: Verdict (approve/reject)
    deactivate CANTON
    VALIDATOR-->>LAPI: Completion event
    LAPI-->>ORCH: 4. CompletionResponse {status, offset}
    deactivate LAPI

    Note over ORCH: Update Internal Ledger<br/>with on-chain confirmation
```

### Flow Summary

| Step | Action | Where | Detail |
|---|---|---|---|
| **1** | PrepareSubmission | Bank → Blockdaemon | Orchestrator sends Daml command; Ledger API returns unsigned txn hash |
| **2** | Sign | Bank Internal | Signing Module calls Vault Transit API; HSM signs txn hash with ECDSA P-256 |
| **3** | ExecuteSubmission | Bank → Blockdaemon | Signed payload submitted; validator forwards to Canton sequencer |
| **4** | Completion | Blockdaemon → Bank | Validator receives verdict; Ledger API streams completion to orchestrator |

---

## 5. Vault-to-Validator Crypto Operations

The Blockdaemon validator node must perform encryption/decryption for Canton protocol operations (view encryption, storage encryption). It does this by calling the bank's Vault API — it never holds key material.

```mermaid
sequenceDiagram
    autonumber
    participant VALIDATOR as Canton Validator<br/>(Blockdaemon)
    participant VAULT as HashiCorp Vault<br/>(Bank KMS)

    Note over VALIDATOR: Outbound: Encrypting a<br/>transaction view for Canton

    VALIDATOR->>VAULT: POST /v1/transit/encrypt/view-encryption-key<br/>{plaintext: base64(view_payload)}
    activate VAULT
    Note over VAULT: AES-256-GCM encrypt<br/>HSM-backed
    VAULT-->>VALIDATOR: {ciphertext: "vault:v1:...", key_version}
    deactivate VAULT
    Note over VALIDATOR: Sends encrypted envelope<br/>to Canton Sequencer

    Note over VALIDATOR: Inbound: Decrypting a<br/>received transaction view

    VALIDATOR->>VAULT: POST /v1/transit/decrypt/view-encryption-key<br/>{ciphertext: "vault:v1:..."}
    activate VAULT
    Note over VAULT: AES-256-GCM decrypt<br/>HSM-backed · Audit logged
    VAULT-->>VALIDATOR: {plaintext: base64(view_payload)}
    deactivate VAULT
    Note over VALIDATOR: Daml Engine processes<br/>decrypted view
```

---

## 6. Key Lifecycle Management

```mermaid
stateDiagram-v2
    direction LR

    [*] --> Generated: Vault generates<br/>key in HSM

    Generated --> Active: Topology txn<br/>registers public key<br/>on Canton

    Active --> Rotating: Rotation triggered<br/>(policy or manual)

    Rotating --> Active: New key version active<br/>Old version: decrypt-only

    Active --> Revoked: Compromise detected<br/>or decommission

    Revoked --> [*]: Key destroyed<br/>after retention period

    note right of Active
        • Signs/encrypts new operations
        • Vault key version = latest
        • Canton topology reflects current key
    end note

    note right of Rotating
        • New key version generated
        • Old version kept for decrypt
        • Topology txn announces rotation
        • Grace period for propagation
    end note

    note right of Revoked
        • Emergency topology txn
        • All operations halt
        • Incident response triggered
    end note
```

### Rotation Policy

| Key | Rotation Frequency | Method | Canton Impact |
|---|---|---|---|
| Root Namespace Key | Never (unless compromised) | Manual Shamir ceremony | Full re-onboarding required |
| Namespace Signing Key | 90 days | Vault auto-rotate + topology txn | Announced; grace period applies |
| Transaction Signing Key | 30 days | Vault auto-rotate + topology txn | Seamless; old version kept for verification |
| Authentication Key (mTLS) | 24 hours | Vault PKI auto-issue | Transparent; short-lived certs |
| View Encryption Key | 90 days | Vault auto-rotate | Old version kept for decryption of historical views |
| Storage Encryption Key | 180 days | Vault auto-rotate + re-wrap | Online re-encryption of PCS data |

---

## 7. What Canton (Blockdaemon) Holds vs. What Vault Holds

```mermaid
graph TB
    subgraph CANTON_HOLDS["What Canton / Blockdaemon Holds"]
        direction TB
        C1["Public keys<br/>(registered via topology txns)"]
        C2["KMS endpoint reference<br/>(Vault URL + auth token path)"]
        C3["Key aliases / references<br/>(e.g. 'txn-signing-key')"]
        C4["Encrypted contract data<br/>(PCS ciphertext)"]
        C5["Encrypted envelopes<br/>(Canton protocol)"]
    end

    subgraph VAULT_HOLDS["What Vault Holds"]
        direction TB
        V1["Root Namespace Private Key<br/>(air-gapped HSM)"]
        V2["All signing private keys<br/>(Transit engine, HSM-backed)"]
        V3["All encryption keys<br/>(Transit engine, HSM-backed)"]
        V4["TLS CA + client certs<br/>(PKI engine)"]
        V5["Key version history<br/>(for decrypt of old data)"]
        V6["Complete audit trail<br/>(every operation logged)"]
    end

    C2 -.->|"API calls<br/>(sign/encrypt/decrypt)"| V2
    C2 -.->|"API calls"| V3

    style CANTON_HOLDS fill:#fff7ed,stroke:#ea580c,stroke-width:2px
    style VAULT_HOLDS fill:#fef2f2,stroke:#dc2626,stroke-width:2px
    style V1 fill:#dc2626,stroke:#333,color:#fff
    style V2 fill:#dc2626,stroke:#333,color:#fff
    style V3 fill:#dc2626,stroke:#333,color:#fff
    style C1 fill:#ea580c,stroke:#333,color:#fff
    style C2 fill:#ea580c,stroke:#333,color:#fff
```

---

## 8. End-to-End: Mint Token with External Signing

Bringing it all together — a concrete example of minting a deposit token using the Vault-Blockdaemon architecture.

```mermaid
sequenceDiagram
    autonumber
    participant CB as Core Banking
    participant IL as Internal Ledger
    participant ORCH as Token Orchestrator
    participant SIGNER as Signing Module
    participant VAULT as HashiCorp Vault
    participant LAPI as Ledger API<br/>(Blockdaemon)
    participant CANTON as Canton Network

    CB->>IL: 1. POST /entries {debit DDA, credit DEPO suspense}
    IL-->>CB: txn_ref = TXN-20260305-001
    IL->>ORCH: 2. MintRequested event (Kafka)

    ORCH->>LAPI: 3. PrepareSubmission(CreateCommand: DepositToken)
    LAPI-->>ORCH: PreparedSubmission {txn_hash}

    ORCH->>SIGNER: 4. Sign(txn_hash)
    SIGNER->>VAULT: POST /v1/transit/sign/txn-signing-key
    VAULT-->>SIGNER: {signature}
    SIGNER-->>ORCH: SignedPayload

    ORCH->>LAPI: 5. ExecuteSubmission(signed_payload)
    LAPI->>CANTON: 6. Canton Confirmation Protocol
    CANTON-->>LAPI: 7. Verdict: APPROVE
    LAPI-->>ORCH: 8. Completion {contract_id, offset}

    ORCH->>IL: 9. POST /confirm {txn_ref, contract_id, offset}
    IL-->>CB: 10. Token minted — suspense cleared

    Note over VAULT: Audit log records:<br/>key=txn-signing-key<br/>op=sign<br/>caller=orchestrator-svc<br/>time=2026-03-05T10:30:00Z
```

---

## 9. Network Connectivity

```mermaid
graph LR
    subgraph BANK_NET["Bank Network (Private)"]
        VAULT_N["Vault Cluster<br/>10.x.x.x"]
        SIGNER_N["Signing Module<br/>10.x.x.x"]
        ORCH_N["Orchestrator<br/>10.x.x.x"]
    end

    subgraph DMZ["DMZ / API Gateway"]
        GW["mTLS Gateway<br/>IP Allowlisted"]
    end

    subgraph BD_NET["Blockdaemon (Cloud)"]
        LAPI_N["Ledger API<br/>ledger.bd.example.com:6865"]
        VAL_N["Validator Node"]
    end

    ORCH_N -->|"gRPC/mTLS"| GW
    GW -->|"gRPC/mTLS"| LAPI_N
    VAL_N -->|"HTTPS/mTLS<br/>(KMS API calls)"| GW
    GW -->|"HTTPS/mTLS"| VAULT_N

    style BANK_NET fill:#ecfdf5,stroke:#059669,stroke-width:2px
    style BD_NET fill:#fff7ed,stroke:#ea580c,stroke-width:2px
    style DMZ fill:#fefce8,stroke:#ca8a04,stroke-width:2px
    style GW fill:#ca8a04,stroke:#333,color:#fff
```

All traffic flows through an mTLS-terminating API gateway in the DMZ. The Vault cluster is never directly exposed to the internet. Blockdaemon's validator reaches Vault only through the gateway, and only for specific Transit API paths (`/v1/transit/sign/*`, `/v1/transit/encrypt/*`, `/v1/transit/decrypt/*`).
