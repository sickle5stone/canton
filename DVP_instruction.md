# DvP Instruction — Onboarding New Counterparties to a Launched Settlement Instrument

> **Audience.** Integration teams at a settlement instrument provider who have already launched their instrument on Digital Asset's Settlement Utility (`utility-settlement-app-v1` 1.2.0) and now need to bring buyers/sellers onboard so DvPs can actually settle.
>
> **Operator assumption.** The `operator` party on every Settlement Utility and Registry Utility contract resolves to **Digital Asset (DA)**. The "settlement instrument provider" referenced below is a *tenant* of DA's utility, not the operator itself. This pins several authority boundaries — see §1 and the role table in §2.
>
> **Companion doc.** [detailed_allocation_flow.md](detailed_allocation_flow.md) — the on-chain sequence assumed to fire once everything below is in place.
>
> **Scope.** Settlement Utility + Registry Utility (`utility-registry-app-v0` 0.7.0, `utility-registry-v0` 0.6.0). All file:line references point to canonical Daml source under [extracted-dars/daml-source/](extracted-dars/daml-source/).

---

## 1. Framing

A "launched settlement instrument" on DA's utility means DA-as-operator has already deployed:

- The Settlement Utility's `OperatorConfiguration` (signatory: DA)
- The Operator Backend service with DA's operator signing keys
- DAR packages vetted on DA's participant node

What's still missing for any specific DvP to fire is the **per-counterparty onboarding** plus a small amount of **cross-utility plumbing**.

The Settlement Utility owns only the *coordination layer* — `DvpProposal`, `Dvp`, `SettledDvp`, and the `UserService` that gates who can propose/accept a DvP. Assets, factories, and instruments still live on the Registry Utility. The Settlement App has no provider/registrar layer of its own; it has only `OperatorConfiguration` + `UserService`.

`Dvp_Settle` ([Dvp.daml:74-103](extracted-dars/daml-source/utility-settlement-app-v1-1.2.0/utility-settlement-app-v1-1.2.0-f169e1d84c476cb1321eff8ac2aebc9ce1c6b20790db5e788ee4ca87256a0639/Utility/Settlement/App/V1/Model/Dvp.daml#L74-L103)) spans both utilities in a single Daml transaction — three packages, all-or-nothing atomicity.

### What "operator = DA" implies for the provider

| Implication | Why |
|---|---|
| Settlement-operator authority and Registry-operator authority resolve to the same Canton party. | Joint operator signature is automatic across both utilities. |
| The provider cannot unilaterally change `OperatorConfiguration.userRequirements` on either utility. | `OperatorConfiguration` is signed by DA alone. Tightening or relaxing onboarding requirements is a DA-side change request. |
| The provider cannot accept a `UserServiceRequest` themselves. | `UserServiceRequest_Accept` controller is `operator` (= DA). The provider must route the request to DA's onboarding desk. |
| The provider cannot issue Settlement-side user credentials. | Settlement `userRequirements` pin DA as the credential `issuer`. Only DA can call `UserService_OfferFreeCredential` against them. |
| The provider drives the DvP settlement orchestration but does not sign `Dvp_Settle`. | `Dvp_Settle` controller is `operator` (= DA). The provider's orchestrator must call into a DA-exposed endpoint (or instruct DA's orchestrator) to fire the choice. |
| The provider's own party still needs Settlement and Registry `UserService`s if it ever holds assets or proposes DvPs. | The provider party is just another user from the utility's perspective. |

The provider's authority is therefore concentrated on the **Registry side** (as a credentialed provider/registrar/issuer per [credential-hierarchy.md](credential-hierarchy.md)) and on the **off-chain integration surface** (Operator Backend tenant, SDK, runbooks). On-chain operator powers — `UserServiceRequest_Accept`, `Dvp_Settle`, `Dvp_Cancel`, `UserService_Terminate` (operator side), `OperatorConfiguration` updates — all sit with DA.

---

## 2. Roles required for one DvP

From [detailed_allocation_flow.md:10-21](detailed_allocation_flow.md#L10-L21), a DvP needs seven distinct party roles, collapsing to five distinct parties in the simplest case.

| Role | Function | Typical party | Already exists when utility launched? |
|---|---|---|---|
| **Settlement Operator** | Owns `OperatorConfiguration`, signs `UserService`s, drives `Dvp_Settle` | **Digital Asset (DA)** | YES |
| **Registry Operator** | Owns the Registry Utility's `OperatorConfiguration`, accepts `UserServiceRequest` and `ProviderServiceRequest` | **Digital Asset (DA)** — same party as above | YES |
| **Cash Provider** | Operates the cash registrar on the Registry Utility | Bank / stablecoin issuer | Usually yes |
| **Cash Registrar** | Admin of the cash `InstrumentConfiguration` | Bank | Usually yes |
| **Securities Provider** | Operates the securities registrar on the Registry Utility | The settlement instrument provider (this is where the provider's on-chain authority sits) | Maybe new |
| **Securities Registrar** | Admin of the securities `InstrumentConfiguration` | Provider or a delegated custodian | Maybe new |
| **Buyer** | Pays cash, receives securities | End client | NEW per pair |
| **Seller** | Pays securities, receives cash | End client | NEW per pair |

> Provider and Registrar are **Registry Utility** concepts ([credential-hierarchy.md:69-117](credential-hierarchy.md#L69-L117)), not Settlement Utility concepts. Registrar parties need no Settlement-side scaffolding beyond DA-side `UserService` onboarding.
>
> **DA wears two hats.** The same Canton party signs as Settlement Operator and Registry Operator. Per [credential-hierarchy.md:172-179](credential-hierarchy.md#L172-L179), DA's deployment collapses operator and credential-issuer to the same party — important for audit and for understanding why a single `UserServiceRequest_Accept` call can also act as the credential issuer.

---

## 3. Net changes — three blocks of work

### Block A — Settlement App onboarding (per new counterparty)

Buyers and sellers each need their own Settlement-side `UserService` before they can call `UserService_ProposeDvp` or `UserService_AcceptDvpProposal`.

| Contract | Source | Signatory | Created by |
|---|---|---|---|
| `UserServiceRequest` | [Service/User.daml:108-152](extracted-dars/daml-source/utility-settlement-app-v1-1.2.0/utility-settlement-app-v1-1.2.0-f169e1d84c476cb1321eff8ac2aebc9ce1c6b20790db5e788ee4ca87256a0639/Utility/Settlement/App/V1/Service/User.daml#L108-L152) | `user` alone | New party (operator observes) |
| Credentials matching `OperatorConfiguration.userRequirements` | [Configuration/Operator.daml:11-20](extracted-dars/daml-source/utility-settlement-app-v1-1.2.0/utility-settlement-app-v1-1.2.0-f169e1d84c476cb1321eff8ac2aebc9ce1c6b20790db5e788ee4ca87256a0639/Utility/Settlement/App/V1/Model/Configuration/Operator.daml#L11-L20) | `issuer, holder` | Each via `CredentialOffer` issued by the operator |
| `UserService` | [Service/User.daml:14-32](extracted-dars/daml-source/utility-settlement-app-v1-1.2.0/utility-settlement-app-v1-1.2.0-f169e1d84c476cb1321eff8ac2aebc9ce1c6b20790db5e788ee4ca87256a0639/Utility/Settlement/App/V1/Service/User.daml#L14-L32) | `operator, user` (joint) | Operator exercises `UserServiceRequest_Accept` with credential CIDs |

`UserServiceRequest_Accept` ([User.daml:118-136](extracted-dars/daml-source/utility-settlement-app-v1-1.2.0/utility-settlement-app-v1-1.2.0-f169e1d84c476cb1321eff8ac2aebc9ce1c6b20790db5e788ee4ca87256a0639/Utility/Settlement/App/V1/Service/User.daml#L118-L136)) runs `assertFulfillsAllRequirements` against the operator config. If `userRequirements` is empty, the credential dance is skipped entirely.

Steps per counterparty (all four steps are gated by DA — the provider's role here is to *route* the counterparty to DA's onboarding desk, not to sign):

1. New party signs `UserServiceRequest`.
2. **DA** runs `UserService_OfferFreeCredential` from the credential-app for each requirement.
3. New party runs `UserService_AcceptFreeCredentialOffer`.
4. **DA** runs `UserServiceRequest_Accept` with the credential CIDs.

Total Daml contracts per new counterparty on the Settlement App: 1 `UserService` + N credentials.

### Block B — Asset-side prerequisites on the Registry Utility (per counterparty per instrument)

| Prerequisite | Why | Whose action |
|---|---|---|
| Registry Utility `UserService` (separate from Settlement's) | Required to accept any per-instrument credential | Registry operator accepts the request |
| `Credential` with `claims: isHolderOf <instrument>` for every instrument the party will **send or receive** | `assertFulfillsAllRequirements` runs inside `AllocationFactory_AllocateInternal` ([AllocationFactory.daml:71-132](extracted-dars/daml-source/utility-registry-app-v0-0.7.0/utility-registry-app-v0-0.7.0-7a75ef6e69f69395a4e60919e228528bb8f3881150ccfde3f31bcc73864b18ab/Utility/Registry/App/V0/Service/AllocationFactory.daml#L71-L132)) AND again inside `executeAllocation` ([Transfer.daml:294-309](extracted-dars/daml-source/utility-registry-v0-0.6.0/utility-registry-v0-0.6.0-a236e8e22a3b5f199e37d5554e82bafd2df688f901de02b00be3964bdfa8c1ab/Utility/Registry/V0/Rule/Transfer.daml#L294-L309)) for the receiver | Each instrument's registrar issues a `CredentialOffer` |
| At least one unlocked `Holding` of the asset they will pay with | Otherwise `AllocationFactory_Allocate.inputHoldingCids` is empty and the choice fails | Comes from prior mint or transfer-in |

Concretely, for the scenario in [detailed_allocation_flow.md](detailed_allocation_flow.md):

**Buyer (Acme):**
- Settlement `UserService` (Block A)
- Registry `UserService`
- `Credential` `isHolderOf: DEPO` (paying)
- `Credential` `isHolderOf: ACME-EQ` (receiving — required by receiver-side check)
- DEPO `Holding` ≥ 5,000,000

**Seller (Megacorp):**
- Settlement `UserService` (Block A)
- Registry `UserService`
- `Credential` `isHolderOf: ACME-EQ` (paying)
- `Credential` `isHolderOf: DEPO` (receiving — required by receiver-side check)
- ACME-EQ `Holding` ≥ 1,000

The receiver-side credential check is the most-missed gate. Both parties need holder credentials for **both** instruments — not just the one they send.

### Block C — Integration plumbing the settlement provider must publish

The on-chain model is necessary but not sufficient. Every on-chain choice needs operator-supplied context that cannot be derived from the ledger alone ([detailed_allocation_flow.md:363-371](detailed_allocation_flow.md#L363-L371)).

| Artifact | Used for | Form |
|---|---|---|
| Operator party ID | Hardcoded by every counterparty in their integration | Docs / DSO manifest |
| DAR package IDs and versions | Counterparties run `dar upload` + `vetPackages` for exact versions | Release notes |
| `POST /api/v0/registry/allocation-factory/choice-context` | Pre-fetch `instrument_configuration_cid` + `sender_credentials_cids[]` before each `AllocationFactory_Allocate` | HTTP endpoint |
| `POST /api/v0/registry/transfer-rule/choice-context` | Per-leg `transfer_rule_cid` for the operator's `Dvp_Settle` orchestration | HTTP endpoint |
| Instrument catalog | Counterparties pick valid `(cash registrar, securities registrar)` instrument pairs and address them in `Terms.deliveries` / `Terms.payments` | Catalog endpoint |
| `OperatorConfiguration` CID and current `userRequirements` | Counterparty's onboarding integration knows which credentials to collect | On-chain `OperatorConfiguration_Get` or documented CID |
| Webhooks: `dvp.settled`, `dvp.rejected`, `dvp.withdrawn`, `allocation.created`, `allocation.cancelled` | Settlement confirmation without ledger polling | Per-tenant subscription |
| Deadlines policy (`allocateBefore`, `settleBefore`) | Settlement App's `validateDvp` enforces ordering, but defaults are off-chain. `settleBefore` is NOT enforced at execution ([Allocation.daml:66-69](extracted-dars/daml-source/utility-registry-v0-0.6.0/utility-registry-v0-0.6.0-a236e8e22a3b5f199e37d5554e82bafd2df688f901de02b00be3964bdfa8c1ab/Utility/Registry/V0/Holding/Allocation.daml#L66-L69)) | Docs |
| Key custody guidance | Counterparties decide between own Canton signing keys vs custody (Vault + Blockdaemon NaaS) | SDK + runbook |
| SDK / reference client wrapping `PrepareSubmission → sign → ExecuteSubmissionAndWait` | Interactive submission is multi-step and error-prone | Published package |

---

## 4. Full sequence — from cold start to first settled DvP

```
PHASE 0 — Settlement provider publishes
  • Operator party ID, DAR versions, OperatorConfiguration CID
  • Operator Backend API base URL + auth scheme
  • Supported instrument catalog

PHASE 1 — Counterparty Canton readiness (off-utility)
  1. Stand up participant node (own infra OR Blockdaemon NaaS) — see onboarding-detailed.md
  2. Generate party signing keys (HashiCorp Vault transit, or KMS) — see kms-runbook.md
  3. Allocate party on the participant; submit topology transactions
  4. Vet DAR packages (settlement, credential, registry-app, registry, registry-holding)

PHASE 2 — Settlement Utility onboarding (Block A, repeated per party)
  5. Submit UserServiceRequest (signed by new party alone)
  6. Operator runs UserService_OfferFreeCredential for each required credential
  7. New party runs UserService_AcceptFreeCredentialOffer
  8. Operator runs UserServiceRequest_Accept → UserService created

PHASE 3 — Registry Utility credentials (Block B, repeated per leg the party touches)
  9. (If not already) UserServiceRequest on Registry Utility → Accept
 10. For each instrument the party will hold:
     a. Registrar runs UserService_OfferFreeCredential with claims=isHolderOf:<instrument>
     b. New party accepts via UserService_AcceptFreeCredentialOffer
 11. Acquire opening Holding (via mint, transfer-in, or seed)

PHASE 4 — First DvP (lives in detailed_allocation_flow.md verbatim)
 12. Proposer calls UserService_ProposeDvp → DvpProposal
 13. Counterparty calls UserService_AcceptDvpProposal → Dvp
 14. Each side calls AllocationFactory_Allocate → DvpLegAllocation (+ locked Holding)
 15. Operator calls Dvp_Settle → SettledDvp (atomic across legs)

PHASE 5 — Steady state
 16. Operator-published webhooks confirm settlement
 17. Counterparties reconcile against their internal books
```

Per-step signing matrix is in [detailed_allocation_flow.md:375-388](detailed_allocation_flow.md#L375-L388).

---

## 5. What the settlement provider delivers

### 5.1 On-chain artifacts

> These contracts are created by **DA-as-operator**, not by the provider. The provider's job is to drive the workflow that triggers them — collecting the counterparty's request, handing it to DA's onboarding desk, and confirming the resulting CIDs.

- `OperatorConfiguration` — one per utility, signatory = DA alone.
- One `CredentialOffer` per new counterparty per required user-credential — signatories DA (issuer) and DA (operator).
- One `UserService` per new counterparty — joint signatories DA + counterparty.
- `SettledDvp` per successful settlement — signatory DA, observers buyer + seller (audit trail).

### 5.2 Off-chain services

> These the provider does build and own — they are the surface that makes DA's on-chain utility usable by the provider's counterparties.

- **Operator Backend choice-context API** — at minimum two endpoints (allocation factory + transfer rule). May be DA-hosted, provider-hosted as a tenant integration, or a mix; provider must publish whichever URL its counterparties hit.
- **Settlement orchestration service** — observes `Dvp` creation, gathers both `DvpLegAllocation` CIDs and per-leg `transferRuleCid`s, then **calls DA's `Dvp_Settle` endpoint** (or instructs DA's orchestrator). The provider does *not* sign `Dvp_Settle` — DA does, as operator. Counterparties never call `Dvp_Settle` directly.
- **Event webhook publisher** — per-tenant subscriptions for the DvP lifecycle events.
- **SDK / reference client** wrapping `PrepareSubmission → external sign → ExecuteSubmissionAndWait`.
- **Operational runbooks** — key rotation, credential renewal, dispute / `Dvp_Cancel` (provider requests, DA signs), deadline-miss handling.

### 5.3 Documentation

| Doc | Audience | Purpose |
|---|---|---|
| Onboarding playbook | Counterparty IT | Walks through Phases 1-3 |
| API reference | Counterparty back-end | Exact request/response shapes |
| SDK reference | Counterparty back-end | Idiomatic client usage |
| Daml package manifest | Counterparty platform | Exact DAR versions to vet |
| Compliance overview | Counterparty legal | On-chain vs off-chain, Daml-enforced vs policy-enforced deadlines |

---

## 6. Common failure modes to brief counterparties on

| Symptom | Root cause | Fix |
|---|---|---|
| `UserServiceRequest_Accept` fails on credential check | Counterparty hasn't accepted all credentials in `userRequirements` | Re-run step 7 of Phase 2 for each requirement |
| `AllocationFactory_Allocate` fails on `assertFulfillsAllRequirements` | Sender credential missing or expired | Re-issue holder credential |
| `Dvp_Settle` fails on the receiver side, leg 1 rolls back | Receiver lacks `isHolderOf:<receiving-instrument>` credential — receiver-side check runs inside `executeAllocation` | Both sides need holder credentials for **both** instruments before allocation |
| `Dvp` accepted but no allocation happens | Wrong registrar's Operator Backend, or wrong `factory_cid` | Publish a routing table mapping `(admin, instrument_id) → Operator Backend URL + factory_cid` |
| `LF_PACKAGE_VERSION_MISMATCH` | Counterparty's vetted DARs don't match the operator's | Pin exact versions in onboarding docs |
| `Dvp_Settle` succeeds past `settleBefore` | Not enforced at execution ([Allocation.daml:66-69](extracted-dars/daml-source/utility-registry-v0-0.6.0/utility-registry-v0-0.6.0-a236e8e22a3b5f199e37d5554e82bafd2df688f901de02b00be3964bdfa8c1ab/Utility/Registry/V0/Holding/Allocation.daml#L66-L69)) | Enforce hard cutoffs in the operator orchestrator before calling `Dvp_Settle` |

---

## 7. Summary

| Block | Per-counterparty cost | Per-utility cost | Who acts |
|---|---|---|---|
| **A — Settlement onboarding** | 1 `UserService` + N user-credentials | 1 `OperatorConfiguration` (already exists) | DA signs; provider routes |
| **B — Registry credentials** | 1 Registry `UserService` + 2 holder credentials + 1 opening `Holding` per leg they touch | 0 (per-instrument config already exists) | DA signs `UserService`; provider (as registrar) issues holder credentials |
| **C — Integration plumbing** | 0 (re-uses provider's published surface) | Operator Backend APIs, orchestrator, webhooks, SDK, runbooks | Provider builds and operates |

The "mock" parties in [detailed_allocation_flow.md:10-21](detailed_allocation_flow.md#L10-L21) — Acme, Megacorp, the bank, the custodian — each map to one of these blocks. With operator pinned to DA, the provider's job is to (1) operate the registrar layer for its asset class, (2) drive counterparty onboarding through DA's signing flow, and (3) own the off-chain plumbing that makes the whole thing usable end-to-end.

---

## 8. Source references

- Settlement App: [extracted-dars/daml-source/utility-settlement-app-v1-1.2.0/](extracted-dars/daml-source/utility-settlement-app-v1-1.2.0/)
- Registry App: [extracted-dars/daml-source/utility-registry-app-v0-0.7.0/](extracted-dars/daml-source/utility-registry-app-v0-0.7.0/)
- Registry: [extracted-dars/daml-source/utility-registry-v0-0.6.0/](extracted-dars/daml-source/utility-registry-v0-0.6.0/)
- Credential App: [extracted-dars/daml-source/utility-credential-app-v0-0.4.1/](extracted-dars/daml-source/utility-credential-app-v0-0.4.1/)
- Credential: [extracted-dars/daml-source/utility-credential-v0-0.1.0/](extracted-dars/daml-source/utility-credential-v0-0.1.0/)
- DAR archive: `/Users/aloysiuslim/Coding/Work/cn-quickstart/canton-network-utility-dars-0.12.0.tar.gz`

## 9. Related docs

- [detailed_allocation_flow.md](detailed_allocation_flow.md) — on-chain DvP sequence with example payloads
- [credential-hierarchy.md](credential-hierarchy.md) — full role/credential matrix
- [onboarding-detailed.md](onboarding-detailed.md) — Canton node + Vault key setup
- [mint-sequence-flows.md](mint-sequence-flows.md) — interactive submission flow detail
