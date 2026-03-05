# Key Management Architecture: HashiCorp Vault & Blockdaemon

## Canton Network | Internal KMS (Vault) | Blockdaemon Node Services

**Version 2.0 | March 2026 | CONFIDENTIAL — Internal Use Only**

---

## 1. Overview

This document describes the interaction model between the bank's internal HashiCorp Vault (KMS) and Blockdaemon's managed Canton validator node. The core principle is **one-time key provisioning with full segregation**:

1. The bank holds the **root namespace key** in Vault — the apex of trust for its Canton identity
2. Operational keys (signing, encryption) are **generated in Vault and provisioned once** to the Canton validator during onboarding or key rotation
3. After provisioning, there is **zero runtime connectivity** between Vault and the Blockdaemon validator
4. All ongoing interaction between the bank and Blockdaemon is exclusively via **Ledger API** (transactions) and **Admin API** (topology & node management)
5. Transaction signing happens inside the bank's **Signing Module**, which retrieves unsigned transactions from the Ledger API, signs them locally using Vault, and submits signed payloads back through the Ledger API

---

## 2. Key Hierarchy & Ownership

```mermaid
graph TD
    subgraph VAULT["🔐 HashiCorp Vault (Bank-Operated)"]
        direction TB
        ROOT["<b>Root Namespace Key</b><br/>Ed25519 / RSA-4096<br/>Cold Storage · Air-Gapped HSM<br/>Used ONCE: bootstrap Canton identity"]

        subgraph BANK_KEYS["Keys Retained in Vault (Never Leave)"]
            direction LR
            NSK["<b>Namespace Signing Key</b><br/>ECDSA P-256<br/>Signs topology txns via Admin API<br/>(party registration, key rotation)"]
            TSK["<b>Transaction Signing Key</b><br/>ECDSA P-256<br/>Signs Daml commands<br/>(mint, transfer, redeem)"]
        end

        subgraph PROVISIONED["Keys Generated in Vault, Provisioned Once to Validator"]
            direction LR
            VEK["<b>View Encryption Key</b><br/>AES-256-GCM / HPKE<br/>Encrypts transaction views"]
            SEK["<b>Storage Encryption Key</b><br/>AES-256-GCM<br/>Encrypts PCS data at rest"]
            NODEK["<b>Node Identity Key</b><br/>TLS cert for Canton protocol<br/>Inter-node communication"]
        end

        ROOT -->|"delegates authority"| NSK
        ROOT -->|"delegates authority"| TSK
        ROOT -->|"generates & exports"| VEK
        ROOT -->|"generates & exports"| SEK
        ROOT -->|"generates & exports"| NODEK
    end

    style VAULT fill:#f7f3ff,stroke:#7c3aed,stroke-width:3px
    style ROOT fill:#dc2626,stroke:#333,color:#fff
    style BANK_KEYS fill:#fef2f2,stroke:#dc2626,stroke-width:2px
    style PROVISIONED fill:#eff6ff,stroke:#2563eb,stroke-width:2px
    style NSK fill:#dc2626,stroke:#333,color:#fff
    style TSK fill:#dc2626,stroke:#333,color:#fff
    style VEK fill:#2563eb,stroke:#333,color:#fff
    style SEK fill:#2563eb,stroke:#333,color:#fff
    style NODEK fill:#2563eb,stroke:#333,color:#fff
```

### Key Ownership Matrix

| Key | Generated In | Resides In | Leaves Vault? | Purpose |
|---|---|---|---|---|
| **Root Namespace Key** | Vault (HSM) | Vault cold storage | Never | Bootstrap Canton identity; anchor of trust |
| **Namespace Signing Key** | Vault (Transit) | Vault only | Never | Sign topology txns submitted via Admin API |
| **Transaction Signing Key** | Vault (Transit) | Vault only | Never | Sign Daml commands submitted via Ledger API |
| **View Encryption Key** | Vault (Transit) | Validator (after one-time provisioning) | Once | Canton protocol view encryption/decryption |
| **Storage Encryption Key** | Vault (Transit) | Validator (after one-time provisioning) | Once | Encrypt PCS contract data at rest |
| **Node Identity Key** | Vault (PKI) | Validator (after one-time provisioning) | Once | mTLS for Canton inter-node protocol |

---

## 3. Segregation Model

After one-time key provisioning, the bank and Blockdaemon operate independently. No runtime KMS API calls. No gateway. The only channels are Ledger API and Admin API.

```mermaid
graph TB
    subgraph BANK["🔒 Bank Trust Boundary"]
        direction TB
        VAULT_SVC["<b>HashiCorp Vault</b><br/>Root Key + Signing Keys<br/>FIPS 140-2 Level 3 HSM"]
        SIGNER["<b>Signing Module</b><br/>Retrieves unsigned txns<br/>Signs via Vault<br/>Submits signed payloads"]
        ORCH["<b>Token Orchestrator</b><br/>Business logic<br/>Event consumer"]
        AUDIT["<b>Audit Log</b><br/>Every sign operation<br/>Tamper-evident"]

        ORCH --> SIGNER
        SIGNER -->|"transit/sign"| VAULT_SVC
        VAULT_SVC --> AUDIT
    end

    subgraph BD["☁️ Blockdaemon Trust Boundary"]
        direction TB
        LAPI["<b>Ledger API</b><br/>gRPC/TLS :6865<br/>Command + Transaction Services"]
        AAPI["<b>Admin API</b><br/>gRPC/TLS<br/>Topology + Node Mgmt"]
        VALIDATOR["<b>Canton Validator</b><br/>Provisioned encryption keys<br/>Provisioned node identity<br/>JVM/Scala · K8s"]
        PG["<b>PostgreSQL</b><br/>Encrypted at rest<br/>(provisioned storage key)"]

        LAPI --- VALIDATOR
        AAPI --- VALIDATOR
        VALIDATOR --- PG
    end

    subgraph CANTON["🔗 Canton Network"]
        direction TB
        SEQ["<b>Sequencer</b>"]
        MED["<b>Mediator</b>"]
        SEQ <--> MED
    end

    SIGNER <-->|"Ledger API<br/>retrieve unsigned txn<br/>submit signed txn"| LAPI
    SIGNER <-->|"Admin API<br/>topology txns<br/>(signed with NSK)"| AAPI
    VALIDATOR <-->|"Canton Protocol<br/>(encrypted envelopes)"| SEQ

    linkStyle 5 stroke:#059669,stroke-width:3px
    linkStyle 6 stroke:#059669,stroke-width:3px

    style BANK fill:#ecfdf5,stroke:#059669,stroke-width:3px
    style BD fill:#fff7ed,stroke:#ea580c,stroke-width:3px
    style CANTON fill:#eff6ff,stroke:#2563eb,stroke-width:3px
    style VAULT_SVC fill:#dc2626,stroke:#333,color:#fff
    style SIGNER fill:#7c3aed,stroke:#333,color:#fff
    style LAPI fill:#059669,stroke:#333,color:#fff
    style AAPI fill:#059669,stroke:#333,color:#fff
    style SEQ fill:#2563eb,stroke:#333,color:#fff
    style MED fill:#ea580c,stroke:#333,color:#fff
```

### Segregation Rules

| Aspect | Bank Side (Vault) | Blockdaemon Side (Validator) | Connection |
|---|---|---|---|
| **Signing Keys** | Retained forever — never exported | No access | None at runtime |
| **Encryption Keys** | Generated, then provisioned once | Holds provisioned copies | One-time transfer only |
| **Transaction Signing** | Signing Module signs locally via Vault | Receives pre-signed payloads | Ledger API |
| **Topology Changes** | Signs topology txns via Vault | Receives pre-signed topology txns | Admin API |
| **Runtime KMS Calls** | N/A | N/A | **None — fully segregated** |
| **Protocol Encryption** | N/A (delegated at provisioning) | Uses provisioned encryption keys locally | N/A |

---

## 4. One-Time Key Provisioning Ceremony

This is the only moment where key material crosses the trust boundary.

```mermaid
sequenceDiagram
    autonumber
    participant ADMIN as Bank Key Custodians<br/>(Multi-Party Ceremony)
    participant VAULT as HashiCorp Vault<br/>(Bank HSM)
    participant AAPI as Admin API<br/>(Blockdaemon)
    participant VALIDATOR as Canton Validator<br/>(Blockdaemon)

    Note over ADMIN,VALIDATOR: === ONE-TIME PROVISIONING CEREMONY ===

    rect rgb(254, 242, 242)
        Note over ADMIN,VAULT: Step 1: Generate all keys in Vault
        ADMIN->>VAULT: Generate Root Namespace Key (cold storage)
        ADMIN->>VAULT: Generate Namespace Signing Key (retained)
        ADMIN->>VAULT: Generate Transaction Signing Key (retained)
        ADMIN->>VAULT: Generate View Encryption Key (to export)
        ADMIN->>VAULT: Generate Storage Encryption Key (to export)
        ADMIN->>VAULT: Generate Node Identity Key + TLS cert (to export)
    end

    rect rgb(239, 246, 255)
        Note over ADMIN,VALIDATOR: Step 2: Export operational keys for validator
        ADMIN->>VAULT: Export view-encryption-key (wrapped)
        VAULT-->>ADMIN: Wrapped key material
        ADMIN->>VAULT: Export storage-encryption-key (wrapped)
        VAULT-->>ADMIN: Wrapped key material
        ADMIN->>VAULT: Export node-identity-key + cert
        VAULT-->>ADMIN: Key + certificate bundle
    end

    rect rgb(236, 253, 245)
        Note over ADMIN,VALIDATOR: Step 3: Provision to validator (secure channel)
        ADMIN->>AAPI: Provision encryption keys + node identity
        AAPI->>VALIDATOR: Install keys into validator keystore
        VALIDATOR-->>AAPI: Keys installed, node ready
        AAPI-->>ADMIN: Provisioning confirmed
    end

    rect rgb(254, 252, 232)
        Note over ADMIN,VALIDATOR: Step 4: Register public keys on Canton
        ADMIN->>VAULT: Sign topology txn (register namespace + public keys)
        VAULT-->>ADMIN: Signed topology transaction
        ADMIN->>AAPI: Submit signed topology txn
        AAPI->>VALIDATOR: Process topology transaction
        VALIDATOR-->>AAPI: Namespace registered on Canton
        AAPI-->>ADMIN: Canton identity active
    end

    Note over ADMIN,VALIDATOR: === SEGREGATION BEGINS ===<br/>No further key exchange.<br/>All interaction via Ledger API + Admin API only.
```

---

## 5. Transaction Signing Flow (Runtime)

After provisioning, the Signing Module is the only bank component that talks to Blockdaemon — exclusively via Ledger API. It retrieves unsigned transactions, signs them locally with Vault, and submits the signed payload back.

```mermaid
sequenceDiagram
    autonumber
    participant ORCH as Token Orchestrator
    participant SIGNER as Signing Module
    participant VAULT as HashiCorp Vault
    participant LAPI as Ledger API<br/>(Blockdaemon)
    participant CANTON as Canton Network

    Note over ORCH: Domain event received<br/>(e.g. MintRequested via Kafka)

    ORCH->>SIGNER: Build Daml command (CreateCommand: DepositToken)

    SIGNER->>LAPI: 1. SubmitAndWait or PrepareSubmission(command)
    activate LAPI
    LAPI-->>SIGNER: Transaction to sign {txn_hash, serialized_txn}
    deactivate LAPI

    SIGNER->>VAULT: 2. POST /v1/transit/sign/txn-signing-key {hash}
    activate VAULT
    Note over VAULT: ECDSA P-256 sign<br/>HSM-backed · Audit logged<br/>Key never leaves Vault
    VAULT-->>SIGNER: {signature, key_version}
    deactivate VAULT

    SIGNER->>LAPI: 3. Submit signed payload {serialized_txn, signature}
    activate LAPI
    Note over LAPI: Validator forwards to Canton<br/>using its provisioned<br/>encryption keys locally
    LAPI->>CANTON: Encrypted envelopes (Sequencer)
    activate CANTON
    Note over CANTON: Confirmation Protocol<br/>Mediator verdict
    CANTON-->>LAPI: Verdict (approve/reject)
    deactivate CANTON
    LAPI-->>SIGNER: 4. CompletionResponse {status, contract_id, offset}
    deactivate LAPI

    SIGNER-->>ORCH: Result {contract_id, status}
    Note over ORCH: Update Internal Ledger

    Note over VAULT,LAPI: No direct connection between<br/>Vault and Blockdaemon.<br/>Signing Module bridges the gap.
```

### Flow Summary

| Step | Direction | Channel | What Happens |
|---|---|---|---|
| **1** | Bank → Blockdaemon | Ledger API | Signing Module sends command; gets back unsigned txn hash |
| **2** | Bank Internal | Vault Transit API | Signing Module signs txn hash locally; key never leaves Vault |
| **3** | Bank → Blockdaemon | Ledger API | Signed payload submitted; validator encrypts locally with provisioned keys and forwards to Canton |
| **4** | Blockdaemon → Bank | Ledger API | Completion streamed back to Signing Module |

---

## 6. Topology Operations via Admin API

Topology changes (party registration, key rotation, delegation) are signed in Vault and submitted through the Admin API. The validator never needs to call back to Vault — it receives pre-signed topology transactions.

```mermaid
sequenceDiagram
    autonumber
    participant ADMIN as Bank Admin / Automation
    participant VAULT as HashiCorp Vault
    participant AAPI as Admin API<br/>(Blockdaemon)
    participant VALIDATOR as Canton Validator

    Note over ADMIN: Topology change needed<br/>(e.g. key rotation, party onboarding)

    ADMIN->>VAULT: 1. Build & sign topology txn<br/>POST /v1/transit/sign/namespace-signing-key
    activate VAULT
    VAULT-->>ADMIN: Signed topology transaction
    deactivate VAULT

    ADMIN->>AAPI: 2. Submit signed topology txn
    activate AAPI
    AAPI->>VALIDATOR: Apply topology change
    VALIDATOR-->>AAPI: Topology updated
    AAPI-->>ADMIN: 3. Confirmation
    deactivate AAPI

    Note over ADMIN,VALIDATOR: No Vault access needed by validator.<br/>Topology txn was pre-signed.
```

---

## 7. Key Rotation (Re-Provisioning)

Key rotation is the only time the one-time provisioning boundary is crossed again — and only for the encryption/node keys held by the validator. Signing keys rotate inside Vault without any interaction with Blockdaemon beyond a topology announcement.

```mermaid
graph LR
    subgraph SIGNING_ROTATION["Signing Key Rotation (Vault-Only)"]
        direction TB
        S1["1. Vault generates<br/>new key version"]
        S2["2. Sign topology txn<br/>announcing new public key"]
        S3["3. Submit via Admin API"]
        S4["4. Old version kept<br/>for verification only"]
        S1 --> S2 --> S3 --> S4
    end

    subgraph ENCRYPTION_ROTATION["Encryption Key Rotation (Re-Provision)"]
        direction TB
        E1["1. Vault generates<br/>new encryption key"]
        E2["2. Export wrapped key<br/>(secure ceremony)"]
        E3["3. Provision to validator<br/>via Admin API"]
        E4["4. Validator re-wraps<br/>existing data"]
        E5["5. Old key kept for<br/>decryption of historical data"]
        E1 --> E2 --> E3 --> E4 --> E5
    end

    style SIGNING_ROTATION fill:#ecfdf5,stroke:#059669,stroke-width:2px
    style ENCRYPTION_ROTATION fill:#eff6ff,stroke:#2563eb,stroke-width:2px
    style S1 fill:#059669,stroke:#333,color:#fff
    style S2 fill:#059669,stroke:#333,color:#fff
    style S3 fill:#059669,stroke:#333,color:#fff
    style S4 fill:#059669,stroke:#333,color:#fff
    style E1 fill:#2563eb,stroke:#333,color:#fff
    style E2 fill:#2563eb,stroke:#333,color:#fff
    style E3 fill:#2563eb,stroke:#333,color:#fff
    style E4 fill:#2563eb,stroke:#333,color:#fff
    style E5 fill:#2563eb,stroke:#333,color:#fff
```

### Rotation Policy

| Key | Rotation | Method | Crosses Boundary? |
|---|---|---|---|
| **Root Namespace Key** | Never (unless compromised) | Manual Shamir ceremony | No |
| **Namespace Signing Key** | 90 days | Vault auto-rotate → topology txn via Admin API | No (only public key announced) |
| **Transaction Signing Key** | 30 days | Vault auto-rotate → topology txn via Admin API | No (only public key announced) |
| **View Encryption Key** | 90 days | Vault generate → secure export → re-provision via Admin API | Yes (re-provisioning) |
| **Storage Encryption Key** | 180 days | Vault generate → secure export → re-provision via Admin API | Yes (re-provisioning) |
| **Node Identity Key** | Annual | Vault PKI → re-provision via Admin API | Yes (re-provisioning) |

---

## 8. What Each Side Holds at Runtime

```mermaid
graph TB
    subgraph VAULT_HOLDS["🔐 What Vault Holds (Bank)"]
        direction TB
        V1["Root Namespace Private Key<br/>(air-gapped HSM — never used at runtime)"]
        V2["Namespace Signing Key<br/>(signs topology txns)"]
        V3["Transaction Signing Key<br/>(signs Daml commands)"]
        V4["Key version history<br/>(old signing key versions for verification)"]
        V5["Complete audit trail<br/>(every sign operation)"]
    end

    subgraph BD_HOLDS["☁️ What Validator Holds (Blockdaemon)"]
        direction TB
        B1["View Encryption Key<br/>(provisioned copy — encrypts/decrypts views)"]
        B2["Storage Encryption Key<br/>(provisioned copy — encrypts PCS at rest)"]
        B3["Node Identity Key + TLS cert<br/>(provisioned — Canton protocol mTLS)"]
        B4["Public keys of all parties<br/>(registered via topology txns)"]
        B5["Encrypted contract data<br/>(PCS — encrypted with storage key)"]
    end

    subgraph COMMS["🔗 Runtime Communication Channels"]
        direction LR
        LAPI["<b>Ledger API</b><br/>gRPC/TLS :6865"]
        AAPI["<b>Admin API</b><br/>gRPC/TLS"]
    end

    V3 -.->|"Signing Module<br/>signs commands"| LAPI
    V2 -.->|"Admin tools<br/>sign topology txns"| AAPI
    LAPI -.-> B1
    AAPI -.-> B4

    style VAULT_HOLDS fill:#fef2f2,stroke:#dc2626,stroke-width:3px
    style BD_HOLDS fill:#fff7ed,stroke:#ea580c,stroke-width:3px
    style COMMS fill:#ecfdf5,stroke:#059669,stroke-width:3px
    style V1 fill:#dc2626,stroke:#333,color:#fff
    style V2 fill:#dc2626,stroke:#333,color:#fff
    style V3 fill:#dc2626,stroke:#333,color:#fff
    style B1 fill:#ea580c,stroke:#333,color:#fff
    style B2 fill:#ea580c,stroke:#333,color:#fff
    style B3 fill:#ea580c,stroke:#333,color:#fff
    style LAPI fill:#059669,stroke:#333,color:#fff
    style AAPI fill:#059669,stroke:#333,color:#fff
```

---

## 9. End-to-End: Mint Token

Complete flow showing how the segregated model works in practice.

```mermaid
sequenceDiagram
    autonumber
    participant CB as Core Banking
    participant IL as Internal Ledger
    participant ORCH as Token Orchestrator
    participant SIGNER as Signing Module
    participant VAULT as HashiCorp Vault
    participant LAPI as Ledger API<br/>(Blockdaemon)
    participant VALIDATOR as Canton Validator
    participant CANTON as Canton Network

    CB->>IL: POST /entries {debit DDA, credit DEPO suspense}
    IL-->>CB: txn_ref = TXN-20260305-001
    IL->>ORCH: MintRequested event (Kafka)

    ORCH->>SIGNER: Build CreateCommand: DepositToken

    rect rgb(236, 253, 245)
        Note over SIGNER,LAPI: Ledger API — the ONLY channel
        SIGNER->>LAPI: PrepareSubmission(CreateCommand)
        LAPI-->>SIGNER: {txn_hash, serialized_txn}
    end

    rect rgb(254, 242, 242)
        Note over SIGNER,VAULT: Vault — internal signing, no external calls
        SIGNER->>VAULT: transit/sign/txn-signing-key {txn_hash}
        VAULT-->>SIGNER: {signature}
    end

    rect rgb(236, 253, 245)
        Note over SIGNER,LAPI: Ledger API — submit signed payload
        SIGNER->>LAPI: ExecuteSubmission(serialized_txn, signature)
    end

    Note over VALIDATOR: Validator encrypts views<br/>locally with provisioned<br/>encryption key

    VALIDATOR->>CANTON: Encrypted envelopes
    CANTON-->>VALIDATOR: Verdict: APPROVE
    LAPI-->>SIGNER: Completion {contract_id, offset}

    SIGNER-->>ORCH: Success
    ORCH->>IL: POST /confirm {txn_ref, contract_id}
    IL-->>CB: Token minted — suspense cleared

    Note over VAULT,VALIDATOR: Vault and Validator never<br/>communicate directly.
```

---

## 10. Communication Matrix

Summary of all runtime connections in the segregated model.

| From | To | Channel | Purpose | Frequency |
|---|---|---|---|---|
| Signing Module | Ledger API (BD) | gRPC/TLS | Submit commands, receive completions | Every transaction |
| Bank Admin | Admin API (BD) | gRPC/TLS | Topology txns, node config, key rotation announcements | Infrequent |
| Signing Module | Vault | HTTPS (internal) | Sign txn hashes | Every transaction |
| Bank Admin | Vault | HTTPS (internal) | Sign topology txns, generate keys | Infrequent |
| Validator | Canton Sequencer | Canton Protocol (gRPC) | Encrypted envelopes, consensus | Every transaction |
| **Validator** | **Vault** | **None** | **No runtime connectivity** | **Never** |

The last row is the defining characteristic of this architecture: **after provisioning, the validator operates autonomously with its provisioned keys and never calls back to Vault**.
