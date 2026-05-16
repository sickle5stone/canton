# Allocation & DvP Settlement Flow — Sequence of Events with Example Payloads

> **Aligned with Digital Asset's Registry Utility (`utility-registry-app-v0` 0.7.0, `utility-registry-v0` 0.6.0) and Settlement Utility (`utility-settlement-app-v1` 1.2.0).**
> All on-chain payloads use the official Splice Token Standard interfaces (`AllocationFactoryV1`, `AllocationV1`, `AllocationRequestV1`) and the Operator Backend API for choice-context retrieval.

> **Scenario:** Acme Corp (buyer) purchases 1,000 ACME-EQ shares from Megacorp (seller) for 5,000,000 DEPO. Two registrars settle atomically via the Settlement App's DvP coordinator.

---

## Role Mapping

| Settlement / Registry Role | Mapped To                                                       | Party ID                                                                       |
| -------------------------- | --------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| **Settlement Operator**    | DvP coordinator (typically the bank or DA platform)             | `operator::1220b39d...b8fe`                                                    |
| **Cash Provider**          | Bank that operates the DEPO (USD) cash registrar                | `bank_provider::1220d301...6567`                                               |
| **Cash Registrar**         | Bank — admin of DEPO instrument                                 | `bank_registrar::1220d301...6567`                                              |
| **Securities Provider**    | Custodian that operates the ACME-EQ securities registrar        | `cust_provider::12207a44...02fd`                                               |
| **Securities Registrar**   | Custodian — admin of ACME-EQ instrument                         | `cust_registrar::12207a44...02fd`                                              |
| **Buyer**                  | Pays cash (DEPO), receives securities (ACME-EQ)                 | `acme_corp::1220a4c2...9f01`                                                   |
| **Seller**                 | Pays securities (ACME-EQ), receives cash (DEPO)                 | `megacorp::1220e5b8...77a3`                                                    |

---

## Prerequisites (assumed to exist before this flow)

| Contract                                    | Template                                                               | Purpose                                                                |
| ------------------------------------------- | ---------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| `AllocationFactory` (cash)                  | `Utility.Registry.App.V0.Service.AllocationFactory:AllocationFactory`  | Cash registrar's factory (admin = `bank_registrar`)                    |
| `AllocationFactory` (securities)            | `Utility.Registry.App.V0.Service.AllocationFactory:AllocationFactory`  | Securities registrar's factory (admin = `cust_registrar`)              |
| `TransferRule` (cash)                       | `Utility.Registry.V0.Rule.Transfer:TransferRule`                       | Enables `ExecuteAllocation` for DEPO                                   |
| `TransferRule` (securities)                 | `Utility.Registry.V0.Rule.Transfer:TransferRule`                       | Enables `ExecuteAllocation` for ACME-EQ                                |
| `InstrumentConfiguration` × 2               | `Utility.Registry.V0.Configuration.Instrument:InstrumentConfiguration` | Defines DEPO and ACME-EQ requirements                                  |
| `Credential` (Acme — DEPO holder)           | `Utility.Credential.V0.Credential:Credential`                          | Buyer's claim `isHolderOf: DEPO`                                       |
| `Credential` (Megacorp — ACME-EQ holder)    | `Utility.Credential.V0.Credential:Credential`                          | Seller's claim `isHolderOf: ACME-EQ`                                   |
| Buyer cash `Holding`                        | `Utility.Registry.Holding.V0.Holding:Holding`                          | ≥ 5,000,000 DEPO unlocked, owned by `acme_corp`                        |
| Seller securities `Holding`                 | `Utility.Registry.Holding.V0.Holding:Holding`                          | ≥ 1,000 ACME-EQ unlocked, owned by `megacorp`                          |

---

## Layered Mental Model

```
SETTLEMENT APP            REGISTRY APP                  REGISTRY (holdings)
─────────────             ─────────────                 ─────────────────────
DvpProposal               AllocationFactory             Holding (sender, unlocked)
   │                          │                            │
   ▼ Accept                   ▼ Allocate                   ▼ MergeSplitLock
Dvp ──┐                   DvpLegAllocation             Holding (sender, locked)
      │                       │                            │
      └─► Dvp_Settle ──► Allocation_ExecuteTransfer ───►   │ archive +
              (atomic across all legs)                     ▼
                                                       Holding (receiver, unlocked)
                                                       + SettledDvp
```

Three packages, three layers. The `Dvp` is the *commitment*, the `DvpLegAllocation` is the *escrow receipt*, and the `Holding` is the *asset*. Atomicity is guaranteed by `Dvp_Settle` exercising `Allocation_ExecuteTransfer` on every leg in one transaction.

---

## Phase 1 — Trade Agreement: `DvpProposal` → `Dvp`

### Step 1.1 — Seller proposes the DvP

|             |                                                                       |
| ----------- | --------------------------------------------------------------------- |
| **Action**  | Seller (Megacorp) proposes a DvP via the Settlement App.              |
| **System**  | Seller's portal → Operator Backend → Ledger API                       |
| **Choice**  | `create DvpProposal` (signatories: `operator`, `proposer = megacorp`) |
| **Source**  | [Dvp.daml:146-188](extracted-dars/daml-source/utility-settlement-app-v1-1.2.0/utility-settlement-app-v1-1.2.0-f169e1d84c476cb1321eff8ac2aebc9ce1c6b20790db5e788ee4ca87256a0639/Utility/Settlement/App/V1/Model/Dvp.daml#L146-L188) |

**`DvpProposal` payload:**

```json
{
  "operator": "operator::1220b39d...b8fe",
  "proposer": "megacorp::1220e5b8...77a3",
  "proposerIsBuyer": false,
  "counterparty": "acme_corp::1220a4c2...9f01",
  "terms": {
    "id": "DVP-2026-0505-00042",
    "deliveries": [
      {
        "instrument": { "admin": "cust_registrar::12207a44...02fd", "id": "ACME-EQ" },
        "amount": "1000.0"
      }
    ],
    "payments": [
      {
        "instrument": { "admin": "bank_registrar::1220d301...6567", "id": "DEPO" },
        "amount": "5000000.0"
      }
    ],
    "createdAt": "2026-05-05T09:00:00Z",
    "allocateBefore": "2026-05-05T15:00:00Z",
    "settleBefore": "2026-05-05T17:00:00Z"
  }
}
```

The `ensure validateDvp $ toDvp this` clause forces `createdAt < allocateBefore < settleBefore`, positive amounts, and `buyer ≠ seller` ([Dvp.daml:273-280](extracted-dars/daml-source/utility-settlement-app-v1-1.2.0/utility-settlement-app-v1-1.2.0-f169e1d84c476cb1321eff8ac2aebc9ce1c6b20790db5e788ee4ca87256a0639/Utility/Settlement/App/V1/Model/Dvp.daml#L273-L280)).

### Step 1.2 — Buyer accepts → `Dvp` contract

|             |                                                                                  |
| ----------- | -------------------------------------------------------------------------------- |
| **Action**  | Buyer (Acme) accepts the proposal.                                               |
| **Choice**  | `DvpProposal_Accept` (controller: `counterparty = acme_corp`)                    |
| **Output**  | `Dvp` contract (signatories: `operator`, `buyer`, `seller`)                      |
| **Asserts** | `assertDeadlineExceeded createdAt`, `assertWithinDeadline allocateBefore`        |
| **Source**  | [Dvp.daml:164-172](extracted-dars/daml-source/utility-settlement-app-v1-1.2.0/utility-settlement-app-v1-1.2.0-f169e1d84c476cb1321eff8ac2aebc9ce1c6b20790db5e788ee4ca87256a0639/Utility/Settlement/App/V1/Model/Dvp.daml#L164-L172) |

The created `Dvp` implements the `AllocationRequest` interface; its view exposes:

- `settlement`: `SettlementInfo { executor = operator, requestedAt = createdAt, settlementRef = {id="DVP-2026-0505-00042", cid=None}, allocateBefore, settleBefore }`
- `transferLegs`: `TextMap` keyed by string indices — leg `"1"` carries the delivery (seller → buyer 1000 ACME-EQ), leg `"2"` carries the payment (buyer → seller 5,000,000 DEPO). Built by `toTransferLegs` ([Dvp.daml:294-308](extracted-dars/daml-source/utility-settlement-app-v1-1.2.0/utility-settlement-app-v1-1.2.0-f169e1d84c476cb1321eff8ac2aebc9ce1c6b20790db5e788ee4ca87256a0639/Utility/Settlement/App/V1/Model/Dvp.daml#L294-L308)).

> **Important:** No assets have moved or been locked yet. The `Dvp` is purely a commitment with deadlines.

---

## Phase 2 — Each counterparty allocates their leg

Both sides happen in parallel. Each side calls `AllocationFactory_Allocate` (the Splice Token Standard interface choice) on the *registrar that admins their instrument*, which in turn dispatches to `AllocationFactory_AllocateInternal`.

### Step 2.1 — Seller allocates the delivery leg (1,000 ACME-EQ)

|              |                                                                                                  |
| ------------ | ------------------------------------------------------------------------------------------------ |
| **Action**   | Seller escrows 1,000 ACME-EQ against `cust_registrar`'s factory.                                 |
| **Choice**   | `AllocationFactory_Allocate` → `AllocationFactory_AllocateInternal`                              |
| **Controller** | `provider = cust_provider`, `registrar = cust_registrar`, `sender = megacorp`                  |
| **Source**   | [AllocationFactory.daml:63-132](extracted-dars/daml-source/utility-registry-app-v0-0.7.0/utility-registry-app-v0-0.7.0-7a75ef6e69f69395a4e60919e228528bb8f3881150ccfde3f31bcc73864b18ab/Utility/Registry/App/V0/Service/AllocationFactory.daml#L63-L132) |

**Operator Backend choice-context request (before submission):**

```http
POST /api/v0/registry/allocation-factory/choice-context
{
  "factory_cid": "00cust-factory-cid...",
  "sender": "megacorp::1220e5b8...77a3",
  "instrument_id": { "admin": "cust_registrar::12207a44...02fd", "id": "ACME-EQ" }
}
```

**Backend response** (becomes `extraArgs.context`):

```json
{
  "instrument_configuration_cid": "00cust-acme-eq-cfg-cid...",
  "sender_credentials_cids": [
    "00megacorp-acme-eq-holder-credential-cid..."
  ]
}
```

**`AllocationFactory_Allocate` payload:**

```json
{
  "expectedAdmin": "cust_registrar::12207a44...02fd",
  "allocation": {
    "settlement": {
      "executor": "operator::1220b39d...b8fe",
      "requestedAt": "2026-05-05T09:00:00Z",
      "settlementRef": { "id": "DVP-2026-0505-00042", "cid": null },
      "allocateBefore": "2026-05-05T15:00:00Z",
      "settleBefore": "2026-05-05T17:00:00Z",
      "meta": {}
    },
    "transferLegId": "1",
    "transferLeg": {
      "sender": "megacorp::1220e5b8...77a3",
      "receiver": "acme_corp::1220a4c2...9f01",
      "amount": "1000.0",
      "instrumentId": { "admin": "cust_registrar::12207a44...02fd", "id": "ACME-EQ" },
      "meta": {}
    }
  },
  "requestedAt": "2026-05-05T09:30:00Z",
  "inputHoldingCids": [ "00megacorp-acme-eq-holding-1500-cid..." ],
  "extraArgs": {
    "context": {
      "instrumentConfigurationCid": "00cust-acme-eq-cfg-cid...",
      "senderCredentialsCids": ["00megacorp-acme-eq-holder-credential-cid..."]
    },
    "meta": {}
  }
}
```

**What the choice does** (verbatim per [AllocationFactory.daml:71-132](extracted-dars/daml-source/utility-registry-app-v0-0.7.0/utility-registry-app-v0-0.7.0-7a75ef6e69f69395a4e60919e228528bb8f3881150ccfde3f31bcc73864b18ab/Utility/Registry/App/V0/Service/AllocationFactory.daml#L71-L132)):

1. Verifies `registrar == expectedAdmin` and `settlement.requestedAt <= requestedAt`.
2. Pulls `InstrumentConfiguration` and the sender's `Credential`s from the choice context.
3. Confirms `toInstrumentId instrumentConfiguration == allocation.transferLeg.instrumentId`.
4. `assertFulfillsAllRequirements sender holderRequirements credentials` — sender must satisfy the instrument's holder claims.
5. **`MergeSplitLock`** via `collapseAction`: merges the 1,500 ACME-EQ input holding(s), splits exactly 1,000, and locks that 1,000 with:

   ```haskell
   Lock { lockers = {cust_registrar}
        , context = toAllocationLockContext allocation   -- encodes settlement.id + transferLegId
        , observers = None }
   ```

   The remaining 500 is returned to the seller as an **unlocked** change Holding.
6. Creates `DvpLegAllocation` (signatories: `cust_provider, cust_registrar, megacorp`; observers: `operator`).

**Result:**

```json
{
  "output": {
    "tag": "AllocationInstructionResult_Completed",
    "value": "00dvp-leg-allocation-1-cid..."
  },
  "senderChangeCids": ["00megacorp-acme-eq-holding-500-cid..."],
  "meta": {}
}
```

### Step 2.2 — Buyer allocates the payment leg (5,000,000 DEPO)

Mirror image of 2.1 but on the *cash* registrar. Choice context comes from the bank's Operator Backend, validates Acme's `isHolderOf: DEPO` credential, locks 5,000,000 DEPO with `lockers = {bank_registrar}`.

|                |                                                                              |
| -------------- | ---------------------------------------------------------------------------- |
| **Choice**     | `AllocationFactory_Allocate` (cash factory)                                  |
| **Controller** | `bank_provider`, `bank_registrar`, `sender = acme_corp`                      |
| **Output**     | `00dvp-leg-allocation-2-cid...` (DvpLegAllocation for leg "2")               |
| **Lock**       | `lockers = {bank_registrar}`, context tied to settlement `DVP-2026-0505-00042`, leg `"2"` |

### Ledger state after Phase 2

| Contract                                     | Notes                                                       |
| -------------------------------------------- | ----------------------------------------------------------- |
| `Dvp` (DVP-2026-0505-00042)                  | Untouched                                                   |
| `DvpLegAllocation` (leg 1, ACME-EQ)          | Holds 1,000 ACME-EQ locked                                  |
| `DvpLegAllocation` (leg 2, DEPO)             | Holds 5,000,000 DEPO locked                                 |
| Locked `Holding` (Megacorp, ACME-EQ, 1000)   | `lock.lockers = {cust_registrar}`, owner still = megacorp   |
| Locked `Holding` (Acme, DEPO, 5,000,000)     | `lock.lockers = {bank_registrar}`, owner still = acme_corp  |
| Unlocked change `Holding` (Megacorp, 500)    | If applicable                                               |

> **Sender retains the claim-back path.** Each `DvpLegAllocation` exposes `Allocation_Withdraw` and `Allocation_Cancel`, which call `Holding_Unlock` on the locked Holding and return it unlocked to the sender ([Allocation.daml:46-62](extracted-dars/daml-source/utility-registry-v0-0.6.0/utility-registry-v0-0.6.0-a236e8e22a3b5f199e37d5554e82bafd2df688f901de02b00be3964bdfa8c1ab/Utility/Registry/V0/Holding/Allocation.daml#L46-L62)).

---

## Phase 3 — Atomic Settlement: `Dvp_Settle`

The operator collects both `DvpLegAllocation` CIDs plus per-leg `extraArgs` (each carrying its registrar's `TransferRule` reference), then exercises `Dvp_Settle` on the `Dvp` contract.

### Step 3.1 — Operator gathers per-leg execution context

For **each leg**, the operator backend produces:

```json
{
  "extraArgs": {
    "context": {
      "transferRuleCid": "00<registrar>-transfer-rule-cid..."
    },
    "meta": {}
  }
}
```

This is the only context `Allocation_ExecuteTransfer` needs ([Allocation.daml:71-72](extracted-dars/daml-source/utility-registry-v0-0.6.0/utility-registry-v0-0.6.0-a236e8e22a3b5f199e37d5554e82bafd2df688f901de02b00be3964bdfa8c1ab/Utility/Registry/V0/Holding/Allocation.daml#L71-L72)).

### Step 3.2 — Operator exercises `Dvp_Settle`

|              |                                                                              |
| ------------ | ---------------------------------------------------------------------------- |
| **Choice**   | `Dvp_Settle` (consuming)                                                     |
| **Controller** | `operator`                                                                 |
| **Source**   | [Dvp.daml:74-103](extracted-dars/daml-source/utility-settlement-app-v1-1.2.0/utility-settlement-app-v1-1.2.0-f169e1d84c476cb1321eff8ac2aebc9ce1c6b20790db5e788ee4ca87256a0639/Utility/Settlement/App/V1/Model/Dvp.daml#L74-L103) |

**Payload:**

```json
{
  "allocationCids": [
    "00dvp-leg-allocation-1-cid...",
    "00dvp-leg-allocation-2-cid..."
  ],
  "extraArgss": [
    { "context": { "transferRuleCid": "00cust-transfer-rule-cid..." }, "meta": {} },
    { "context": { "transferRuleCid": "00bank-transfer-rule-cid..." }, "meta": {} }
  ]
}
```

**Inside the choice body:**

1. `length allocationCids == nLegs` and `length extraArgss == nLegs` (here, 2).
2. Fetch each allocation, call `view`, and verify the set of `AllocationSpecification`s matches `toExpectedAllocations this` after `normalize` (clears metadata fields). This is the integrity check — a substituted leg fails here.
3. For each `(allocationCid, extraArgs)`, exercises `Allocation_ExecuteTransfer` with that leg's context.

### Step 3.3 — Per-leg `Allocation_ExecuteTransfer` (×2 inside the same transaction)

|              |                                                                                              |
| ------------ | -------------------------------------------------------------------------------------------- |
| **Choice**   | `Allocation_ExecuteTransfer` (interface, dispatches to `DvpLegAllocation`'s impl)            |
| **Controller (interface)** | `executor (operator)`, `sender`, `receiver`                                    |
| **Source**   | [Allocation.daml:64-86](extracted-dars/daml-source/utility-registry-v0-0.6.0/utility-registry-v0-0.6.0-a236e8e22a3b5f199e37d5554e82bafd2df688f901de02b00be3964bdfa8c1ab/Utility/Registry/V0/Holding/Allocation.daml#L64-L86) |

The implementation pulls the `TransferRule` CID and exercises **`TransferRule_ExecuteAllocation`** ([Transfer.daml:85-106](extracted-dars/daml-source/utility-registry-v0-0.6.0/utility-registry-v0-0.6.0-a236e8e22a3b5f199e37d5554e82bafd2df688f901de02b00be3964bdfa8c1ab/Utility/Registry/V0/Rule/Transfer.daml#L85-L106)). That choice runs `executeAllocation`, which:

1. `assertDeadlineExceeded settlement.requestedAt`.
2. `validateTransfer` — re-checks parties, instrument, and credentials against the *receiver*'s requirements (and re-fetches the registrar's `InstrumentConfiguration`).
3. **`UnlockMergeSplitTransfer`** via `collapseAction`:
   - Verifies the locked Holding has `lockers = {instrumentId.admin}` and the expected lock context.
   - Archives the locked sender Holding.
   - Creates a fresh `Holding` with `owner = receiver`, `amount = transferLeg.amount`, `lock = None`, `label = ""` ([Transfer.daml:294-309](extracted-dars/daml-source/utility-registry-v0-0.6.0/utility-registry-v0-0.6.0-a236e8e22a3b5f199e37d5554e82bafd2df688f901de02b00be3964bdfa8c1ab/Utility/Registry/V0/Rule/Transfer.daml#L294-L309)).

Both legs run within the same transaction tree rooted at `Dvp_Settle`. **Daml transaction semantics guarantee all-or-nothing** — if leg 2 fails any check (e.g. Acme's holder credential expired between Phase 2 and Phase 3), leg 1's archival and Holding creation are rolled back.

### Step 3.4 — Settlement result

```json
{
  "settledDvpCid": "00settled-dvp-cid..."
}
```

The `Dvp` contract is consumed; a `SettledDvp` is created (signatory: `operator`; observers: `buyer`, `seller`) as the audit trail ([Dvp.daml:223-232](extracted-dars/daml-source/utility-settlement-app-v1-1.2.0/utility-settlement-app-v1-1.2.0-f169e1d84c476cb1321eff8ac2aebc9ce1c6b20790db5e788ee4ca87256a0639/Utility/Settlement/App/V1/Model/Dvp.daml#L223-L232)).

### Ledger state after Phase 3

| Contract                                          | Notes                                                  |
| ------------------------------------------------- | ------------------------------------------------------ |
| `SettledDvp`                                      | Audit trail                                            |
| `Holding` (Acme, ACME-EQ, 1000, unlocked)         | New — buyer received delivery                          |
| `Holding` (Megacorp, DEPO, 5,000,000, unlocked)   | New — seller received payment                          |
| Old `Dvp`, both `DvpLegAllocation`s, both locked Holdings | All archived                                  |

---

## Phase 4 — Off-chain Reconciliation

The operator backend, observing the `Dvp_Settle` event:

1. Records `SettlementCompleted(DVP-2026-0505-00042)` in its database.
2. Notifies both portals via webhooks / WebSocket.
3. The bank reconciles its DEPO reserve account against Megacorp's new on-chain DEPO balance.
4. The custodian updates internal share-register records to reflect Acme's new ACME-EQ holding.

---

## Failure Paths

| Trigger                                      | Choice                                  | Controller                    | Effect                                                                               |
| -------------------------------------------- | --------------------------------------- | ----------------------------- | ------------------------------------------------------------------------------------ |
| Buyer rejects proposal                       | `DvpProposal_Reject`                    | `counterparty`                | `RejectedDvpProposal` created; no allocations exist yet                              |
| Seller cancels proposal                      | `DvpProposal_Cancel`                    | `proposer`                    | Proposal archived                                                                    |
| Either side wants out *after* allocating     | `AllocationRequest_Reject` on the `Dvp` | `buyer` or `seller`           | `RejectedDvp` created (signal); allocations remain — must be unwound separately      |
| Operator decides not to settle               | `Dvp_Cancel`                            | `operator`                    | `Dvp` withdrawn **and** every `Allocation_Withdraw` exercised → all lockers released |
| One side wants their escrow back unilaterally| `Allocation_Withdraw` / `Allocation_Cancel` | `sender`                  | Locked Holding unlocked, returned to sender; Allocation archived                     |
| Settlement deadline missed                   | n/a                                     | n/a                           | No automatic action — operator/parties choose to cancel; `settleBefore` is *not* hard-enforced at execution time ([Allocation.daml:66-69](extracted-dars/daml-source/utility-registry-v0-0.6.0/utility-registry-v0-0.6.0-a236e8e22a3b5f199e37d5554e82bafd2df688f901de02b00be3964bdfa8c1ab/Utility/Registry/V0/Holding/Allocation.daml#L66-L69)) |

> **Design note:** Splice intentionally allows execution past `settleBefore` for "operational flexibility and recovery scenarios". Enforcement of post-deadline failure is a *policy* choice that lives in the operator backend, not the Daml model.

---

## Choice Context Cheatsheet

What the Operator Backend must produce for each choice in the flow:

| Choice                                | Context Keys                                              | Source of Truth                                                                |
| ------------------------------------- | --------------------------------------------------------- | ------------------------------------------------------------------------------ |
| `AllocationFactory_Allocate`          | `instrumentConfigurationCid`, `senderCredentialsCids[]`   | Registrar's `InstrumentConfiguration`; sender's holder `Credential`s           |
| `Allocation_ExecuteTransfer`          | `transferRuleCid`                                         | Registrar's published `TransferRule`                                           |
| `Dvp_Settle`                          | (none on the choice itself; per-leg `extraArgss[]` only)  | Aggregate of per-leg `transferRuleCid`s                                        |

---

## Interactive Submission Notes (Vault + Blockdaemon)

Each on-chain step is a `PrepareSubmission → Vault sign → ExecuteSubmissionAndWait` cycle. The signing party in each phase:

| Step                                       | Signing Party (controller)                              | Vault Key                          |
| ------------------------------------------ | ------------------------------------------------------- | ---------------------------------- |
| `DvpProposal` (create)                     | `proposer` (e.g. Megacorp)                              | `seller` party key                 |
| `DvpProposal_Accept`                       | `counterparty` (e.g. Acme)                              | `buyer` party key                  |
| `AllocationFactory_Allocate` (cash leg)    | `bank_provider`, `bank_registrar`, `acme_corp` (sender) | All three Vault keys               |
| `AllocationFactory_Allocate` (sec leg)     | `cust_provider`, `cust_registrar`, `megacorp` (sender)  | All three Vault keys               |
| `Dvp_Settle`                               | `operator`                                              | Operator Vault key only            |

`Dvp_Settle` is signed by the operator alone, but its sub-exercises (`Allocation_ExecuteTransfer` → `TransferRule_ExecuteAllocation`) require additional party authorizations that are pre-delegated through the allocation contracts' signatory sets. **The operator does not need any party's key at settlement time** — that authority was committed when each side allocated.

---

## Quick Reference — Templates and Choices

| Layer            | Template                  | Key Choices / Interface Methods                                                                                                       |
| ---------------- | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| Settlement App   | `DvpProposal`             | `DvpProposal_Accept`, `DvpProposal_Cancel`, `DvpProposal_Reject`                                                                      |
| Settlement App   | `Dvp`                     | `Dvp_Settle`, `Dvp_Cancel`, `AllocationRequest_Reject`, `AllocationRequest_Withdraw`                                                  |
| Registry App     | `AllocationFactory`       | `AllocationFactory_Allocate` (interface) → `AllocationFactory_AllocateInternal`                                                       |
| Registry         | `DvpLegAllocation`        | `Allocation_Withdraw`, `Allocation_Cancel`, `Allocation_ExecuteTransfer` (all via `Allocation` interface)                             |
| Registry         | `TransferRule`            | `TransferRule_ExecuteAllocation` (called inside `Allocation_ExecuteTransfer`)                                                         |
| Registry         | `Holding`                 | `Holding_Unlock` (called by Withdraw/Cancel)                                                                                          |

---

## File-level References

- AllocationFactory: `extracted-dars/daml-source/utility-registry-app-v0-0.7.0/.../Service/AllocationFactory.daml`
- DvpLegAllocation: `extracted-dars/daml-source/utility-registry-v0-0.6.0/.../V0/Holding/Allocation.daml`
- TransferRule: `extracted-dars/daml-source/utility-registry-v0-0.6.0/.../V0/Rule/Transfer.daml`
- Dvp / DvpProposal / SettledDvp: `extracted-dars/daml-source/utility-settlement-app-v1-1.2.0/.../V1/Model/Dvp.daml`
