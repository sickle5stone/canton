# Credential & Role Hierarchy — Digital Asset Registry Utility

Layered capability model of UserService, Credential, ProviderService, RegistrarService, and InstrumentConfiguration. All claims below are grounded in the Daml source under [extracted-dars/daml-source/](extracted-dars/daml-source/). File:line references point to the canonical templates.

## TL;DR

- **It is a role matrix, not a hierarchy.** Operator, Provider, Registrar, Issuer, and Holder are parallel roles. Each role is enabled by a `Credential` that pins a specific *issuer party*.
- **`UserService` is the entry point.** Without it, no choices to offer/accept credentials are reachable.
- **Approval direction inverts at every gate.** The subordinate party signs the request alone, the supervising party controls Accept. Credentials invert this — the holder approves their own credential.
- **No on-ledger cap on credentials.** `Credential` has no key, no `ensure` count, no quota field in any configuration template.
- **`InstrumentConfiguration` identity is immutable.** The `(operator, provider, registrar)` triple cannot be changed in place. Only archive-and-recreate is supported, and only within the same triple.

## Layer 0 — Off-ledger (no contract)

The new party (e.g. JPM) learns the operator party ID for DA from documentation, DSO manifest, or direct communication. There is no `OperatorAnnouncement` or `OperatorRegistry` contract — operator discovery is the **only** out-of-band step in the whole chain. Everything after this is on-ledger and verifiable.

## Layer 1 — UserService

**Purpose:** capability surface. Without a `UserService`, a party cannot call any credential-related choice.

### Contracts

| Contract | File | Key fields | Signatory |
|---|---|---|---|
| `UserServiceRequest` | [User.daml:425-432](extracted-dars/daml-source/utility-credential-app-v0-0.4.1/Utility/Credential/App/V0/Service/User.daml#L425-L432) | `operator`, `user` | `user` (observer: `operator`) |
| `UserService` | [User.daml:17-27](extracted-dars/daml-source/utility-credential-app-v0-0.4.1/Utility/Credential/App/V0/Service/User.daml#L17-L27) | `operator`, `user`, `dso` | `operator, user` (joint) |

### Flow

1. **JPM creates `UserServiceRequest`** — JPM signs alone, DA observes.
2. **DA exercises `UserServiceRequest_Accept`** ([User.daml:435-442](extracted-dars/daml-source/utility-credential-app-v0-0.4.1/Utility/Credential/App/V0/Service/User.daml#L435-L442)) — controller: `operator` — creates `UserService`.

### Gate

Both parties need their own `UserService` with DA. DA needs one to issue credentials, JPM needs one to accept them. `UserService` is per-(operator, user) pair — no Daml key, so the same party can hold multiple `UserService`s with different operators (multi-tenant at the party level).

### Capabilities unlocked

All controlled by `user` on its own `UserService`:

- `UserService_OfferFreeCredential` / `UserService_OfferPaidCredential`
- `UserService_AcceptFreeCredentialOffer` / `UserService_AcceptPaidCredentialOffer`
- `UserService_RevokeCredential` / `UserService_CancelCredentialOffer`
- `UserService_RejectCredentialOffer`
- `UserService_CancelCredentialBilling` / `UserService_RevokeCredentialAndCancelBilling`

## Layer 2 — Provider Credential

**Purpose:** certify that JPM meets the operator's provider requirements.

### Contracts

| Contract | File | Signatory |
|---|---|---|
| `CredentialOffer` | [Offer.daml:18-171](extracted-dars/daml-source/utility-credential-app-v0-0.4.1/Utility/Credential/App/V0/Model/Offer.daml#L18-L171) | `operator, issuer` |
| `Credential` | [Credential.daml:43-95](extracted-dars/daml-source/utility-credential-v0-0.1.0/Utility/Credential/V0/Credential.daml#L43-L95) | `issuer, holder` |

### Flow

1. **DA calls `UserService_OfferFreeCredential`** on DA's own `UserService` (controller: DA). The offer is created with `issuer = user = DA`.
2. **JPM calls `UserService_AcceptFreeCredentialOffer`** on JPM's `UserService` ([Offer.daml:44-46](extracted-dars/daml-source/utility-credential-app-v0-0.4.1/Utility/Credential/App/V0/Model/Offer.daml#L44-L46)) — controller: `holder` — creates `Credential { issuer: DA, holder: JPM, claims }`.

Paid path: `CredentialOffer_AcceptPaid` ([Offer.daml:62-70](extracted-dars/daml-source/utility-credential-app-v0-0.4.1/Utility/Credential/App/V0/Model/Offer.daml#L62-L70)) — controller: `holder, operator` jointly — also creates a `CredentialBilling` for the locked deposit.

### Gate

The credential's `issuer` party must match the pin in `OperatorConfiguration.providerRequirements[].issuer`. `assertFulfillsAllRequirements` at [Provider.daml:158-160](extracted-dars/daml-source/utility-registry-app-v0-0.7.0/Utility/Registry/App/V0/Service/Provider.daml#L158-L160) checks this when JPM later requests provider service.

## Layer 3 — ProviderService

**Purpose:** activate JPM as an operating provider.

### Contracts

| Contract | File | Signatory |
|---|---|---|
| `ProviderServiceRequest` | [Provider.daml:132-173](extracted-dars/daml-source/utility-registry-app-v0-0.7.0/Utility/Registry/App/V0/Service/Provider.daml#L132-L173) | `provider` |
| `ProviderService` | [Provider.daml:18-126](extracted-dars/daml-source/utility-registry-app-v0-0.7.0/Utility/Registry/App/V0/Service/Provider.daml#L18-L126) | `operator, provider` |

### Flow

1. **JPM creates `ProviderServiceRequest`** — JPM signs alone.
2. **DA exercises `ProviderServiceRequest_Accept`** ([Provider.daml:142-152](extracted-dars/daml-source/utility-registry-app-v0-0.7.0/Utility/Registry/App/V0/Service/Provider.daml#L142-L152)) — controller: `operator` — passes `operatorConfigurationCid` and `credentialCids = [JPM's Provider Credential]`. Validates claims via `assertFulfillsAllRequirements` and creates `ProviderService`.

### Gate

`ProviderService` must exist before anyone can be credentialed as a Registrar under JPM (the Registrar credential issuer pin lives in `ProviderConfiguration`).

## Layer 4 — Registrar Credential

Same shape as Layer 2, but **JPM is the issuer** this time. JPM calls `UserService_OfferFreeCredential` on its own `UserService`; the Registrar accepts via its own `UserService`. Resulting `Credential` has `issuer = JPM, holder = Registrar`.

### Gate

The credential's `issuer` must match the pin in `ProviderConfiguration.registrarRequirements[].issuer` (set to JPM).

## Layer 5 — RegistrarService

**Purpose:** activate the Registrar and create the rule/factory contracts that downstream instruments hang off.

### Contracts

| Contract | File | Signatory |
|---|---|---|
| `RegistrarServiceRequest` | [Registrar.daml:911-964](extracted-dars/daml-source/utility-registry-app-v0-0.7.0/Utility/Registry/App/V0/Service/Registrar.daml#L911-L964) | `registrar` |
| `RegistrarService` | (same file) | `operator, provider, registrar` |
| `TransferRule` | [Transfer.daml:29-39](extracted-dars/daml-source/utility-registry-v0-0.6.0/Utility/Registry/V0/Rule/Transfer.daml#L29-L39) | `provider, registrar` |
| `AllocationFactory` | [AllocationFactory.daml:37-47](extracted-dars/daml-source/utility-registry-app-v0-0.7.0/Utility/Registry/App/V0/Service/AllocationFactory.daml#L37-L47) | `provider, registrar` |

### Flow

1. **Registrar creates `RegistrarServiceRequest`** — Registrar signs alone, JPM and DA observe.
2. **JPM exercises `RegistrarServiceRequest_Accept`** ([Registrar.daml:927-936](extracted-dars/daml-source/utility-registry-app-v0-0.7.0/Utility/Registry/App/V0/Service/Registrar.daml#L927-L936)) — controller: `provider` (note: not DA) — passes `providerConfigurationCid` and Registrar credential CIDs. Creates `RegistrarService` plus optional `TransferRule` and `AllocationFactory`.

### Gate

`RegistrarService` must exist before any `InstrumentConfiguration` can be created. All three contracts are scoped to `(operator, provider, registrar)` — instruments hang off this triple.

## Layer 6 — InstrumentConfiguration

**Per-asset configuration** under the `(operator, provider, registrar)` triple.

### Contract

[InstrumentConfiguration](extracted-dars/daml-source/utility-registry-v0-0.6.0/Utility/Registry/V0/Configuration/Instrument.daml) — signatory `provider, registrar`. Created via `RegistrarService_CreateInstrumentConfiguration` (controller: `registrar`).

### Mutability

Only two choices exist on this template ([Instrument.daml:53-71](extracted-dars/daml-source/utility-registry-v0-0.6.0/Utility/Registry/V0/Configuration/Instrument.daml#L53-L71)):

| Choice | Controller | Effect |
|---|---|---|
| `InstrumentConfiguration_SetProviderAppRewardBeneficiaries` | `provider` | Updates reward beneficiary list only |
| `InstrumentConfiguration_Get` (nonconsuming) | `actor` | Read-only |

**The `(operator, provider, registrar)` triple is structurally immutable.** No `_UpdateProvider`, `_UpdateRegistrar`, `_Transfer`, or `_Migrate` choices exist. The only mutation path is `RegistrarService_ArchiveAndCreateInstrumentConfiguration`, which can change identifiers, requirements, and beneficiaries — but inherits the same triple from the parent `RegistrarService`.

To genuinely change provider or registrar: archive the instrument, migrate or burn outstanding Holdings, stand up a new `RegistrarServiceRequest` under the new pair, recreate the instrument.

## Layer 7 — Issuer & Holder credentials (per instrument)

There is **no separate `IssuerServiceRequest`**. Issuance is implicit: whoever the `InstrumentConfiguration.issuerRequirements[].issuer` field pins (typically JPM or the Registrar) calls `UserService_OfferFreeCredential` to credential the would-be issuer party. That party accepts via its own `UserService`.

`HolderServiceRequest` was **deprecated in v0.7.0** ([Holder.daml:4-11](extracted-dars/daml-source/utility-registry-app-v0-0.7.0/Utility/Registry/App/V0/Service/Holder.daml#L4-L11)) — holders are now just parties that accept a `CredentialOffer` per the instrument's `holderRequirements`.

Credentials at this layer are re-checked against the `InstrumentConfiguration`'s requirements at mint/transfer time.

## Approval matrix

| Layer | Request signatory | Accept controller | Reject controller |
|---|---|---|---|
| UserService | `user` (JPM) | `operator` (DA) | `operator` |
| Provider Credential | `operator, issuer` (CredentialOffer) | `holder` (free) / `holder, operator` (paid) | — |
| ProviderService | `provider` (JPM) | `operator` (DA) | `operator` |
| Registrar Credential | `operator, issuer` | `holder` (Registrar) | — |
| RegistrarService | `registrar` | `provider` (JPM) — **not DA** | `provider` |
| InstrumentConfiguration | n/a — direct create on `RegistrarService` | `registrar` | n/a |
| Per-instrument credentials | `operator, issuer` | `holder` | — |

**Pattern:** the subordinate party proposes alone; the supervising party controls Accept. Credentials invert this — you cannot be credentialed against your will, so the holder approves.

## Revocation & termination

| Action | Authority | Notes |
|---|---|---|
| `Credential_Revoke` | `actor ∈ [issuer, holder]` ([Credential.daml:85-93](extracted-dars/daml-source/utility-credential-v0-0.1.0/Utility/Credential/V0/Credential.daml#L85-L93)) | Either side can unilaterally archive the credential. |
| `ProviderService_Terminate` | `operator` alone | Operator can kill the service without touching the credential. |
| `UserService_Terminate` | `operator` OR `user` ([User.daml:28-33](extracted-dars/daml-source/utility-credential-app-v0-0.4.1/Utility/Credential/App/V0/Service/User.daml#L28-L33)) | Either side can walk away. |
| `CredentialOffer_Cancel` | `issuer, operator` jointly | Pre-acceptance only. |
| `CredentialBilling_CancelExpired` | `actor ∈ [issuer, holder, operator]` | Operator can act unilaterally only after expiry. |

### What "DA removes JPM as provider" actually means

DA wears two hats: **operator** and **credential-issuer** (same Canton party in practice). Each hat gives different powers:

- **As operator:** can terminate `ProviderService` unilaterally. Credential survives on-ledger as audit trail.
- **As issuer of the credential:** can call `Credential_Revoke` alone, since `issuer` satisfies `actor ∈ [issuer, holder]`. Service survives unless also terminated.

Clean exit: do both. The Daml model tracks operator and issuer as distinct authorities, even though DA's deployment collapses them to the same party — this matters for audit, and matters if a hypothetical deployment ever splits them.

JPM's powers as the credentialed party:

- Can `Credential_Revoke` its own credential at any time (holder authority).
- **Cannot** terminate its own `ProviderService` — that controller is `operator` alone.
- Cannot archive dependent contracts (`InstrumentConfiguration`, `TransferRule`, `AllocationFactory`) it co-signed without registrar/provider cooperation.

So JPM has a unilateral "quit the credential" button, but only DA can do the operational off-boarding.

## Credential issuance count

**No on-ledger cap.**

- `Credential` has no `key` declaration ([Credential.daml:43-95](extracted-dars/daml-source/utility-credential-v0-0.1.0/Utility/Credential/V0/Credential.daml#L43-L95)) — `(issuer, holder, id)` is not uniqueness-constrained.
- No `ensure` clause limiting count.
- No `maxCredentials*` field on any configuration template.
- No `lookupByKey` / `fetchByKey` in the credential codepath.

Real constraints are economic and operational: Canton storage per contract, Amulet deposit for paid credentials, off-ledger DA policy. The model is unbounded by design so that overlapping/rotating/scoped credentials are possible without an upgrade.

## Minimum onboarding to first mint

For the "JPM is provider, registrar, and issuer of the same asset" case, the shortest path is 8 contracts:

1. `UserServiceRequest` → Accept (JPM ↔ DA).
2. `CredentialOffer` (DA issues Provider credential) → Accept (JPM).
3. `ProviderServiceRequest` → Accept (JPM ↔ DA).
4. `CredentialOffer` (JPM issues Registrar credential to itself) → Accept.
5. `RegistrarServiceRequest` → Accept (JPM-as-provider approving JPM-as-registrar).
6. `RegistrarService_CreateInstrumentConfiguration` (pin issuer requirements to JPM).
7. `CredentialOffer` (JPM issues Issuer credential to itself) → Accept.
8. Mint via `AllocationFactory_OfferMint` / `AllocationFactory_RequestMint`.

DA's approval is required at steps 1, 2, and 3. After that, JPM self-governs within the `(DA, JPM, JPM)` triple.

## Cross-layer invariants

**Rule A — Credential pinning cascades.** Each Service's `_Accept` choice runs `assertFulfillsAllRequirements`, which checks (a) the presented credential's `issuer` matches the requirement's `issuer` pin, and (b) the credential's claims satisfy the requirement's claim shape. The pin at one layer determines who must have issued the credential at the layer below.

**Rule B — Joint signatories propagate trust.** Every Service contract has joint signatories: `(operator, user)`, `(operator, provider)`, `(operator, provider, registrar)`. Once you're "in" at a layer, mutation requires the joint authority. DA can unilaterally *terminate* (because `_Terminate` is `controller operator` alone), but cannot quietly rewrite service terms without the other signatories.

## Glossary

| Term | Meaning in this model |
|---|---|
| Operator | The utility runner. DA Operator party for the Registry Utility. |
| Provider | A party credentialed by the operator to act as provider for one or more registrars. |
| Registrar | A party credentialed by a provider to register instruments. |
| Issuer (credential) | The party in the `issuer` field of a `Credential` — the one whose authority backs the claims. |
| Issuer (instrument) | A party credentialed under an `InstrumentConfiguration.issuerRequirements` to mint that instrument. |
| Holder | A party in the `holder` field of any `Credential`, or in the holder role on an instrument's Holdings. |
| DSO | Decentralized Synchronizer Operations party — referenced by `UserService` for synchronizer-level concerns. |

## Source references

All file paths are relative to repo root. Canonical Daml source is under [extracted-dars/daml-source/](extracted-dars/daml-source/). DAR archive: `/Users/aloysiuslim/Coding/Work/cn-quickstart/canton-network-utility-dars-0.12.0.tar.gz`.

- `utility-credential-v0-0.1.0/` — `Credential`, `PartyCredentialRequirement`
- `utility-credential-app-v0-0.4.1/` — `CredentialOffer`, `CredentialBilling`, `UserService`, `UserServiceRequest`
- `utility-registry-app-v0-0.7.0/` — `ProviderService(Request)`, `RegistrarService(Request)`, `AllocationFactory`, deprecated `HolderServiceRequest`
- `utility-registry-v0-0.6.0/` — `InstrumentConfiguration`, `TransferRule`
