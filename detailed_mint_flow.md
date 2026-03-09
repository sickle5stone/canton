# Mint & Bridge Workflow — Sequence of Events with Example Payloads

> **Revised to align with Digital Asset's Registry Utility (v0.9.x+) and Credential Utility.**
> All on-chain payloads use the official utility templates, the two-step request/accept mint workflow, and the Operator Backend API for choice context retrieval.

> **Scenario:** Acme Corp requests minting of 5,000,000 DEPO (USD) via Bank Portal.

---

## Role Mapping

| Registry Utility Role | Mapped To | Party ID |
|---|---|---|
| **Operator** | Platform operator (bank or DA) | `operator::1220b39d...b8fe` |
| **Provider** | The bank (onboards Registrars) | `bank_provider::1220d301...6567` |
| **Registrar** | The bank (maintains ownership records, accepts/rejects mints) | `bank_registrar::1220d301...6567` |
| **Holder / Issuer** | The bank is the issuer (minter); Acme Corp is the holder | Issuer: `bank_issuer::1220d301...6567`, Holder: `acme_corp::1220a4c2...9f01` |

## Prerequisites (assumed to exist before this flow)

| Contract | Template | Purpose |
|---|---|---|
| `ProviderService` | `Utility.Registry.App.V0.Service.Provider:ProviderService` | Bank onboarded as Provider |
| `RegistrarService` | `Utility.Registry.App.V0.Service.Registrar:RegistrarService` | Bank onboarded as Registrar |
| `InstrumentConfiguration` | `Utility.Registry.V0.Configuration.Instrument:InstrumentConfiguration` | Defines DEPO instrument with Issuer and Holder credential requirements |
| `AllocationFactory` | `Utility.Registry.App.V0.Service.AllocationFactory:AllocationFactory` | Factory contract for mint/burn requests |
| `Credential` (Issuer) | `Utility.Credential.V0.Credential:Credential` | Bank's credential with claim `isIssuerOf: DEPO` |
| `Credential` (Holder) | `Utility.Credential.V0.Credential:Credential` | Acme's credential with claim `isHolderOf: DEPO` |
| `TransferRule` | `Utility.Registry.V0.Rule.Transfer:TransferRule` | Registrar's rule enabling transfers for DEPO |

---

## Step 1 — Initiation

| | |
|---|---|
| **Action** | User initiates a "Move to Chain" transfer in the Bank Portal. |
| **System** | Bank UI → Core Banking |
| **Details** | Debit DDA; credit Reserve Account (`RESERVE-DEPO-001`). |

No inter-service payload at this step. Core Banking performs internal book entry:

| Account | Side | Amount |
|---|---|---|
| DDA — Acme (`****4521`) | DEBIT | $5,000,000.00 |
| Deposit Token Reserve (`RESERVE-DEPO-001`) | CREDIT | $5,000,000.00 |

---

## Step 2 — Off-Chain Recording

| | |
|---|---|
| **Action** | Core Banking calls the Internal Ledger to record the mint. |
| **System** | Internal Txn System → Internal Ledger |
| **API** | `POST https://internal-ledger.bank.internal/api/v1/tokens/mint` |
| **Protocol** | REST, TLS 1.3, OAuth 2.0 Bearer Token (client credentials grant) |

**Request:**

```json
{
  "request_ref": "MINT-2026-0301-00001",
  "token_type": "DEPO",
  "amount": 5000000.00,
  "currency": "USD",
  "owner_party_id": "acme_corp::1220a4c2...9f01",
  "source_account": {
    "account_type": "DDA",
    "account_number": "****4521",
    "routing_number": "021000021"
  },
  "metadata": {
    "initiated_by": "treasury_ops@acme.com",
    "business_reason": "Supply chain settlement",
    "reference": "PO-2026-88712"
  }
}
```

**Response (201 Created):**

```json
{
  "txn_ref": "TXN-MINT-20260301-A7F3E9",
  "status": "PENDING_MINT",
  "token_type": "DEPO",
  "amount": 5000000.00,
  "currency": "USD",
  "owner_party_id": "acme_corp::1220a4c2...9f01",
  "ledger_entries": [
    { "account": "DDA-****4521", "side": "DEBIT", "amount": 5000000.00 },
    { "account": "RESERVE-DEPO-001", "side": "CREDIT", "amount": 5000000.00 }
  ],
  "created_at": "2026-03-01T10:00:00.000Z",
  "idempotency_key": "f47ac10b-58cc-4372-a567-0e02b2c3d479"
}
```

---

## Step 3 — Event Emission

| | |
|---|---|
| **Action** | Internal Ledger emits a domain event to the Event Bus. |
| **System** | Internal Ledger → Kafka |
| **Event** | `MintRequested` domain event |

**Kafka Message (Topic: `deposit-token.events.mint`):**

```json
{
  "event_type": "MintRequested",
  "event_id": "evt-20260301-mint-00001",
  "txn_ref": "TXN-MINT-20260301-A7F3E9",
  "token_type": "DEPO",
  "amount": 5000000.00,
  "currency": "USD",
  "owner_party_id": "acme_corp::1220a4c2...9f01",
  "issuer_party_id": "bank_issuer::1220d301...6567",
  "registrar_party_id": "bank_registrar::1220d301...6567",
  "source_account": {
    "account_type": "DDA",
    "account_number": "****4521"
  },
  "metadata": {
    "initiated_by": "treasury_ops@acme.com",
    "business_reason": "Supply chain settlement",
    "reference": "PO-2026-88712"
  },
  "emitted_at": "2026-03-01T10:00:00.250Z"
}
```

---

## Step 4 — Retrieve Mint Request Choice Context

| | |
|---|---|
| **Action** | Orchestrator calls the Operator Backend API to retrieve the choice context required for the mint request. |
| **System** | Token Orchestrator → Operator Backend API |
| **API** | `POST ${BACKEND_API}/v0/registry/mint/v0/request` |
| **Protocol** | HTTPS (TLS 1.3) |

This retrieves the `AllocationFactory` contract ID, the `InstrumentConfiguration` contract ID, the issuer's `Credential` contract ID(s), and the disclosed contracts (serialized `createdEventBlob`s) needed for the command.

**Request:**

```json
{
  "holder": "acme_corp::1220a4c2...9f01",
  "instrumentId": {
    "admin": "bank_registrar::1220d301...6567",
    "id": "DEPO"
  }
}
```

**Response:**

```json
{
  "factoryId": "000b99a1...factory_contract_id",
  "choiceContext": {
    "choiceContextData": {
      "values": {
        "utility.digitalasset.com/instrument-configuration": {
          "tag": "AV_ContractId",
          "value": "00eca75b...instrument_config_cid"
        },
        "utility.digitalasset.com/issuer-credentials": {
          "tag": "AV_List",
          "value": [
            {
              "tag": "AV_ContractId",
              "value": "0031a230...issuer_credential_cid"
            }
          ]
        }
      }
    },
    "disclosedContracts": [
      {
        "createdAt": "2026-01-15T12:00:00Z",
        "contractId": "000b99a1...factory_contract_id",
        "templateId": "...pkg_hash:Utility.Registry.App.V0.Service.AllocationFactory:AllocationFactory",
        "createdEventBlob": "<base64_encoded_blob>"
      },
      {
        "createdAt": "2026-01-15T12:01:00Z",
        "contractId": "00eca75b...instrument_config_cid",
        "templateId": "...pkg_hash:Utility.Registry.V0.Configuration.Instrument:InstrumentConfiguration",
        "createdEventBlob": "<base64_encoded_blob>"
      },
      {
        "createdAt": "2026-01-15T12:02:00Z",
        "contractId": "0031a230...issuer_credential_cid",
        "templateId": "...pkg_hash:Utility.Credential.V0.Credential:Credential",
        "createdEventBlob": "<base64_encoded_blob>"
      }
    ]
  }
}
```

---

## Step 5 — Construct Mint Request Command

| | |
|---|---|
| **Action** | Orchestrator constructs the `ExerciseCommand` on the `AllocationFactory` to request a mint. |
| **System** | Token Orchestrator (internal) |
| **Choice** | `AllocationFactory_RequestMint` |
| **Template** | `Utility.Registry.App.V0.Service.AllocationFactory:AllocationFactory` |

**ExerciseCommand (Ledger API v2 — HTTP JSON API format):**

```json
{
  "commands": {
    "commands": [
      {
        "ExerciseCommand": {
          "templateId": "#utility-registry-app-v0:Utility.Registry.App.V0.Service.AllocationFactory:AllocationFactory",
          "contractId": "000b99a1...factory_contract_id",
          "choice": "AllocationFactory_RequestMint",
          "choiceArgument": {
            "expectedAdmin": "bank_registrar::1220d301...6567",
            "mint": {
              "instrumentId": {
                "admin": "bank_registrar::1220d301...6567",
                "id": "DEPO"
              },
              "amount": "5000000.0000000000",
              "holder": "acme_corp::1220a4c2...9f01",
              "reference": "TXN-MINT-20260301-A7F3E9",
              "requestedAt": "2026-03-01T10:00:01Z",
              "executeBefore": "2026-03-01T11:00:01Z",
              "meta": {
                "values": {}
              }
            },
            "extraArgs": {
              "context": {
                "values": {
                  "utility.digitalasset.com/instrument-configuration": {
                    "tag": "AV_ContractId",
                    "value": "00eca75b...instrument_config_cid"
                  },
                  "utility.digitalasset.com/issuer-credentials": {
                    "tag": "AV_List",
                    "value": [
                      {
                        "tag": "AV_ContractId",
                        "value": "0031a230...issuer_credential_cid"
                      }
                    ]
                  }
                }
              },
              "meta": { "values": {} }
            }
          }
        }
      }
    ],
    "userId": "token_orchestrator_svc",
    "commandId": "CMD-MINTREQ-20260301-A7F3E9",
    "actAs": ["bank_issuer::1220d301...6567"],
    "readAs": [],
    "disclosedContracts": [
      {
        "contractId": "000b99a1...factory_contract_id",
        "templateId": "...pkg_hash:Utility.Registry.App.V0.Service.AllocationFactory:AllocationFactory",
        "createdEventBlob": "<base64_encoded_blob>",
        "synchronizerId": ""
      },
      {
        "contractId": "00eca75b...instrument_config_cid",
        "templateId": "...pkg_hash:Utility.Registry.V0.Configuration.Instrument:InstrumentConfiguration",
        "createdEventBlob": "<base64_encoded_blob>",
        "synchronizerId": ""
      },
      {
        "contractId": "0031a230...issuer_credential_cid",
        "templateId": "...pkg_hash:Utility.Credential.V0.Credential:Credential",
        "createdEventBlob": "<base64_encoded_blob>",
        "synchronizerId": ""
      }
    ]
  }
}
```

---

## Step 6 — Prepare, Sign & Submit Mint Request

| | |
|---|---|
| **Action** | Orchestrator submits the mint request command through the Interactive Submission flow (prepare → KMS sign → execute). |
| **System** | Token Orchestrator → Blockdaemon Node → Internal KMS → Blockdaemon Node |
| **APIs** | `InteractiveSubmissionService.PrepareSubmission` → `POST /v1/sign` (KMS) → `InteractiveSubmissionService.ExecuteSubmissionAndWait` |
| **Endpoint** | `canton-validator.blockdaemon.com:443` (gRPC/TLS 1.3, mTLS + OIDC) |

**6a — PrepareSubmission Request (gRPC):**

The Orchestrator submits the ExerciseCommand from Step 5 to Blockdaemon for preparation.

**6a — PrepareSubmission Response:**

```json
{
  "prepared_transaction": "<binary_protobuf_encoded_transaction>",
  "prepared_transaction_hash": "c8d4e2f1a3b5...sha256_hash",
  "cost_estimation": {
    "traffic_cost_bytes": 5120
  }
}
```

**6b — KMS Sign Request:**

```json
{
  "key_id": "canton-signing-key-prod-001",
  "algorithm": "ECDSA_P256_SHA256",
  "payload_hash": "c8d4e2f1a3b5...sha256_hash",
  "context": {
    "operation": "CANTON_TX_SIGN",
    "command_id": "CMD-MINTREQ-20260301-A7F3E9",
    "txn_ref": "TXN-MINT-20260301-A7F3E9"
  }
}
```

**6b — KMS Sign Response (200 OK):**

```json
{
  "signature": "MEUCIQDh8k...base64_encoded_signature",
  "signing_key_fingerprint": "SHA256:xYz123...key_fingerprint",
  "algorithm": "ECDSA_P256_SHA256",
  "signed_at": "2026-03-01T10:00:01.500Z",
  "audit_id": "KMS-AUDIT-20260301-001234"
}
```

**6c — ExecuteSubmissionAndWait Request (gRPC):**

```json
{
  "prepared_transaction": "<binary_protobuf_encoded_transaction>",
  "signatures": [
    {
      "key_fingerprint": "SHA256:xYz123...key_fingerprint",
      "signature": "MEUCIQDh8k...base64_encoded_signature",
      "algorithm": "ECDSA_P256_SHA256"
    }
  ],
  "command_id": "CMD-MINTREQ-20260301-A7F3E9",
  "synchronizer_id": "global-domain::1220f0c1...33eb"
}
```

---

## Step 7 — Canton Commit Protocol (Mint Request)

| | |
|---|---|
| **Action** | Canton's confirmation protocol executes for the `AllocationFactory_RequestMint` exercise. |
| **System** | Blockdaemon Node → Sequencer → Stakeholder Validators → Mediator |

This follows the standard Canton commit protocol:

1. **Blockdaemon node** executes the Daml command locally, produces transaction tree, decomposes into encrypted views (HKDF hybrid encryption), submits `TransactionConfirmationRequest` to Sequencer.
2. **Sequencer** assigns monotonic timestamp, distributes `EncryptedViewMessage` to stakeholders, `InformeeMessage` to Mediator, `RootHashMessage` to each participant.
3. **Stakeholder validators** decrypt views, validate Daml semantics, verify the issuer's `Credential` contract (claim `isIssuerOf: DEPO`), verify `InstrumentConfiguration` exists. Send `ConfirmationResponse` (`LocalApprove`).
4. **Mediator** aggregates responses per Signatory confirmation policy, issues `Verdict: Approve`, distributes `ConfirmationResultMessage`.
5. **All participants** commit: the `AllocationFactory` remains active (non-consuming exercise), and a new `MintRequest` contract is created in the ACS.

**6c — ExecuteSubmissionAndWait Response (MintRequest created):**

```json
{
  "transaction": {
    "updateId": "12201f75...tx_hash",
    "commandId": "CMD-MINTREQ-20260301-A7F3E9",
    "effectiveAt": "2026-03-01T10:00:02.100Z",
    "events": [
      {
        "CreatedEvent": {
          "offset": 50001,
          "nodeId": 3,
          "contractId": "00113ba9...mint_request_cid",
          "templateId": "...pkg_hash:Utility.Registry.App.V0.Model.Mint:MintRequest",
          "createArgument": {
            "operator": "operator::1220b39d...b8fe",
            "provider": "bank_provider::1220d301...6567",
            "mint": {
              "instrumentId": {
                "admin": "bank_registrar::1220d301...6567",
                "id": "DEPO"
              },
              "amount": "5000000.0000000000",
              "holder": "acme_corp::1220a4c2...9f01",
              "reference": "TXN-MINT-20260301-A7F3E9",
              "requestedAt": "2026-03-01T10:00:01Z",
              "executeBefore": "2026-03-01T11:00:01Z",
              "meta": { "values": {} }
            }
          },
          "signatories": [
            "bank_issuer::1220d301...6567",
            "bank_provider::1220d301...6567"
          ],
          "observers": [
            "operator::1220b39d...b8fe",
            "bank_registrar::1220d301...6567"
          ],
          "packageName": "utility-registry-app-v0"
        }
      }
    ],
    "offset": 50001,
    "synchronizerId": "global-domain::1220f0c1...33eb",
    "recordTime": "2026-03-01T10:00:02.130Z"
  }
}
```

---

## Step 8 — Retrieve Mint Accept Choice Context

| | |
|---|---|
| **Action** | Orchestrator (acting as Registrar) calls the Backend API to get the choice context for accepting the mint request. |
| **System** | Token Orchestrator → Operator Backend API |
| **API** | `POST ${BACKEND_API}/v0/registry/mint/v0/request/${MINTREQUEST_CID}/choice-contexts/accept` |

**Request:**

```json
{
  "meta": {},
  "excludeDebugFields": true
}
```

**Response:**

```json
{
  "choiceContextData": {
    "values": {
      "utility.digitalasset.com/instrument-configuration": {
        "tag": "AV_ContractId",
        "value": "00eca75b...instrument_config_cid"
      },
      "utility.digitalasset.com/issuer-credentials": {
        "tag": "AV_List",
        "value": [
          {
            "tag": "AV_ContractId",
            "value": "0031a230...issuer_credential_cid"
          }
        ]
      },
      "utility.digitalasset.com/app-reward-configuration": {
        "tag": "AV_ContractId",
        "value": "00525af6...app_reward_config_cid"
      }
    }
  },
  "disclosedContracts": [
    {
      "createdAt": "2026-01-15T12:02:00Z",
      "contractId": "0031a230...issuer_credential_cid",
      "templateId": "...pkg_hash:Utility.Credential.V0.Credential:Credential",
      "createdEventBlob": "<base64_encoded_blob>"
    },
    {
      "createdAt": "2026-01-15T12:03:00Z",
      "contractId": "00525af6...app_reward_config_cid",
      "templateId": "...pkg_hash:Utility.Registry.V0.Configuration.AppReward:AppRewardConfiguration",
      "createdEventBlob": "<base64_encoded_blob>"
    }
  ]
}
```

---

## Step 9 — Construct Mint Accept Command

| | |
|---|---|
| **Action** | Orchestrator constructs the `ExerciseCommand` on the `MintRequest` to accept it. |
| **System** | Token Orchestrator (internal) |
| **Choice** | `MintRequest_Accept` |
| **Template** | `Utility.Registry.App.V0.Model.Mint:MintRequest` |

**ExerciseCommand (Ledger API v2):**

```json
{
  "commands": {
    "commands": [
      {
        "ExerciseCommand": {
          "templateId": "...pkg_hash:Utility.Registry.App.V0.Model.Mint:MintRequest",
          "contractId": "00113ba9...mint_request_cid",
          "choice": "MintRequest_Accept",
          "choiceArgument": {
            "extraArgs": {
              "context": {
                "values": {
                  "utility.digitalasset.com/instrument-configuration": {
                    "tag": "AV_ContractId",
                    "value": "00eca75b...instrument_config_cid"
                  },
                  "utility.digitalasset.com/issuer-credentials": {
                    "tag": "AV_List",
                    "value": [
                      {
                        "tag": "AV_ContractId",
                        "value": "0031a230...issuer_credential_cid"
                      }
                    ]
                  },
                  "utility.digitalasset.com/app-reward-configuration": {
                    "tag": "AV_ContractId",
                    "value": "00525af6...app_reward_config_cid"
                  }
                }
              },
              "meta": { "values": {} }
            }
          }
        }
      }
    ],
    "userId": "token_orchestrator_svc",
    "commandId": "CMD-MINTACC-20260301-A7F3E9",
    "actAs": ["bank_registrar::1220d301...6567"],
    "readAs": [],
    "disclosedContracts": [
      {
        "contractId": "0031a230...issuer_credential_cid",
        "templateId": "...pkg_hash:Utility.Credential.V0.Credential:Credential",
        "createdEventBlob": "<base64_encoded_blob>",
        "synchronizerId": ""
      },
      {
        "contractId": "00525af6...app_reward_config_cid",
        "templateId": "...pkg_hash:Utility.Registry.V0.Configuration.AppReward:AppRewardConfiguration",
        "createdEventBlob": "<base64_encoded_blob>",
        "synchronizerId": ""
      }
    ]
  }
}
```

---

## Step 10 — Prepare, Sign & Submit Mint Accept

| | |
|---|---|
| **Action** | Orchestrator submits the accept command through the Interactive Submission flow (same three-phase pattern as Step 6). |
| **System** | Token Orchestrator → Blockdaemon Node → Internal KMS → Blockdaemon Node |
| **APIs** | `PrepareSubmission` → `POST /v1/sign` → `ExecuteSubmissionAndWait` |

**10a — PrepareSubmission Response:**

```json
{
  "prepared_transaction": "<binary_protobuf_encoded_transaction>",
  "prepared_transaction_hash": "f7a1b3c5d2e4...sha256_hash",
  "cost_estimation": {
    "traffic_cost_bytes": 6144
  }
}
```

**10b — KMS Sign Request:**

```json
{
  "key_id": "canton-signing-key-prod-001",
  "algorithm": "ECDSA_P256_SHA256",
  "payload_hash": "f7a1b3c5d2e4...sha256_hash",
  "context": {
    "operation": "CANTON_TX_SIGN",
    "command_id": "CMD-MINTACC-20260301-A7F3E9",
    "txn_ref": "TXN-MINT-20260301-A7F3E9"
  }
}
```

**10b — KMS Sign Response (200 OK):**

```json
{
  "signature": "MEYCIQC9p2...base64_encoded_signature",
  "signing_key_fingerprint": "SHA256:xYz123...key_fingerprint",
  "algorithm": "ECDSA_P256_SHA256",
  "signed_at": "2026-03-01T10:00:03.200Z",
  "audit_id": "KMS-AUDIT-20260301-001235"
}
```

---

## Step 11 — Canton Commit Protocol (Mint Accept → Holding Created)

| | |
|---|---|
| **Action** | Canton's confirmation protocol executes for the `MintRequest_Accept` exercise. |
| **System** | Blockdaemon Node → Sequencer → Stakeholder Validators → Mediator |

Same 2PC confirmation protocol as Step 7. On `Verdict: Approve`:

- The `MintRequest` contract is **archived** (consumed).
- A new `Holding` contract is **created** in the ACS representing the minted tokens.

**Credential validation during accept:**

```
InstrumentConfiguration (DEPO):
  instrumentId:
    admin:  bank_registrar::1220d301...6567
    id:     "DEPO"
  issuerCredentialRequirements: [
    { issuer: bank_registrar, property: "isIssuerOf", value: "DEPO" }
  ]
  holderCredentialRequirements: [
    { issuer: bank_registrar, property: "isHolderOf", value: "DEPO" }
  ]

Issuer Credential Check:
  Credential {
    issuer:  bank_registrar::1220d301...6567
    holder:  bank_issuer::1220d301...6567
    claims:  [{ property: "isIssuerOf", value: "DEPO" }]
  }
  → Issuer authorized to mint DEPO ✓
```

---

## Step 12 — Result Receipt (Holding Created)

| | |
|---|---|
| **Action** | Orchestrator receives the transaction result — the `Holding` contract now exists on-chain. |
| **System** | Blockdaemon Node → Token Orchestrator |
| **API** | `ExecuteSubmissionAndWait` response (sync) |

**gRPC Response (Canton Ledger API v2):**

```json
{
  "transaction": {
    "updateId": "1220a8b3...tx_hash_accept",
    "commandId": "CMD-MINTACC-20260301-A7F3E9",
    "effectiveAt": "2026-03-01T10:00:04.500Z",
    "events": [
      {
        "ArchivedEvent": {
          "offset": 50002,
          "nodeId": 0,
          "contractId": "00113ba9...mint_request_cid",
          "templateId": "...pkg_hash:Utility.Registry.App.V0.Model.Mint:MintRequest"
        }
      },
      {
        "CreatedEvent": {
          "offset": 50002,
          "nodeId": 5,
          "contractId": "00d4e5f6...holding_cid",
          "templateId": "...pkg_hash:Utility.Registry.Holding.V0.Holding:Holding",
          "createArgument": {
            "instrument": {
              "admin": "bank_registrar::1220d301...6567",
              "id": "DEPO"
            },
            "amount": "5000000.0000000000",
            "owner": "acme_corp::1220a4c2...9f01",
            "registrar": "bank_registrar::1220d301...6567",
            "meta": { "values": {} }
          },
          "interfaceViews": [
            {
              "interfaceId": "...pkg_hash:Splice.Api.Token.HoldingV1:Holding",
              "viewValue": { "..." : "..." }
            }
          ],
          "signatories": [
            "bank_registrar::1220d301...6567",
            "acme_corp::1220a4c2...9f01"
          ],
          "observers": [
            "operator::1220b39d...b8fe"
          ],
          "packageName": "utility-registry-holding-v0"
        }
      }
    ],
    "offset": 50002,
    "synchronizerId": "global-domain::1220f0c1...33eb",
    "recordTime": "2026-03-01T10:00:04.530Z"
  }
}
```

---

## Step 13 — Reconciliation

| | |
|---|---|
| **Action** | Orchestrator updates the Internal Ledger with the on-chain status. |
| **System** | Token Orchestrator → Internal Ledger |
| **API** | `PUT https://internal-ledger.bank.internal/api/v1/tokens/TXN-MINT-20260301-A7F3E9/status` |

**Request:**

```json
{
  "status": "MINTED",
  "on_chain": {
    "holding_contract_id": "00d4e5f6...holding_cid",
    "mint_request_contract_id": "00113ba9...mint_request_cid",
    "transaction_id": "1220a8b3...tx_hash_accept",
    "offset": 50002,
    "committed_at": "2026-03-01T10:00:04.500Z",
    "instrument_id": "DEPO",
    "registrar": "bank_registrar::1220d301...6567",
    "holding_template": "Utility.Registry.Holding.V0.Holding:Holding"
  }
}
```

**Daily reconciliation (00:30 UTC):**

```
Reconciliation:
  1. Fetch all DEPO Holdings from ACS via StateService.GetActiveContracts
  2. Compare per-party holding amounts against Internal Ledger positions
  3. Total DEPO supply on-chain == Reserve balance off-chain?     ✓
  4. Per-party positions match (Acme: 5,000,000 DEPO)?            ✓
  5. No orphaned Holdings (on-chain without off-chain record)?    ✓
  → Reconciliation PASSED
```

---

## Step 14 — Confirmation

| | |
|---|---|
| **Action** | Internal Ledger confirms back to Core Banking; client notified. |
| **System** | Internal Ledger → Internal Txn System → Client |
| **E2E Target** | < 10s (p99) |

**Client-facing confirmation:**

```json
{
  "transaction_ref": "TXN-MINT-20260301-A7F3E9",
  "status": "COMPLETE",
  "message": "5,000,000.00 DEPO minted successfully.",
  "balance": {
    "token_type": "DEPO",
    "instrument_id": "DEPO",
    "currency": "USD",
    "available_balance": 5000000.00,
    "active_holdings": 1,
    "registrar": "bank_registrar::1220d301...6567",
    "last_updated": "2026-03-01T10:00:05.000Z"
  }
}
```

---

## Timing Summary

| Step | Component | Expected Latency |
|------|-----------|-----------------|
| 1–2 | Core Banking → Internal Ledger | < 200ms |
| 3 | Kafka emission + consumption | < 50ms |
| 4 | Backend API — mint request context | < 500ms |
| 5 | Command construction | < 10ms |
| 6a | `PrepareSubmission` (mint request) | < 500ms |
| 6b | KMS signing | < 100ms (p99), 5s hard limit |
| 6c–7 | `ExecuteSubmissionAndWait` + Canton 2PC (mint request) | < 5s |
| 8 | Backend API — accept context | < 500ms |
| 9 | Command construction (accept) | < 10ms |
| 10a | `PrepareSubmission` (accept) | < 500ms |
| 10b | KMS signing | < 100ms (p99), 5s hard limit |
| 10c–11 | `ExecuteSubmissionAndWait` + Canton 2PC (accept → Holding) | < 5s |
| 12 | Result processing | < 50ms |
| 13 | Internal Ledger status update | < 200ms |
| 14 | Client confirmation | < 100ms |
| **Total E2E** | **Client request → MINTED confirmation** | **< 12s (p99)** |

> **Note:** The E2E target increases from < 10s to approximately < 12s due to the two-step on-chain flow (request + accept), each requiring a full Canton commit protocol round and a separate KMS signing operation. This may be optimized by automating the Registrar accept step with minimal latency between Steps 7 and 8.

---

## Key Differences from Previous Spec

| Aspect | Previous (Custom Templates) | Revised (Registry Utility) |
|---|---|---|
| **Mint mechanism** | Single `CreateCommand` on `DepositToken` | Two-step `ExerciseCommand`: `AllocationFactory_RequestMint` → `MintRequest_Accept` |
| **Token contract** | `DepositToken.Registry.DepositToken` | `Utility.Registry.Holding.V0.Holding:Holding` |
| **Asset model** | Monolithic (instrument + holding in one contract) | Separated: `InstrumentConfiguration` (what) + `Holding` (how much, at which registrar) |
| **Credential model** | Custom fields: `kycStatus`, `permissionedTokens` | Claim-based: `Utility.Credential.V0.Credential` with `isIssuerOf`/`isHolderOf` properties |
| **Roles** | Issuer / Owner | Four roles: Operator, Provider, Registrar, Holder |
| **Choice context** | Not required | Required — must call Operator Backend API before each command |
| **Disclosed contracts** | Not required | Required — `InstrumentConfiguration`, `Credential`, `AppRewardConfiguration` blobs must be passed with each command |
| **Canton protocol steps** | 1 round | 2 rounds (request + accept), each with full 2PC |
| **KMS signing ops per mint** | 1 | 2 (one per Interactive Submission) |