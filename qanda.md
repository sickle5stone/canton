# Canton Deployment Security Q&A — Code-Based Answers

## Deployment context (read first)

This Q&A concerns a tokenisation platform on **Canton Network** using **the Utility Provider's Registry
Utility** templates. The security posture follows from how responsibility is split between three parties.

- **The Institution** runs its own **dApp / orchestrator** and holds **every party signing key** in its
  own **HSM/KMS**. The parties are onboarded as **external parties**: their signing keys live
  off the node, and the Node Provider node hosts them with **confirmation rights only**, not signing
  authority (Canton forbids Submission permission for external parties — see Q10.1). Every transaction is
  signed by the Institution's signing KMS through Canton's **Interactive Submission** flow (`PrepareSubmission`
  → the KMS signs the transaction hash → `ExecuteSubmission`).
- **Node Provider** is the **Node-as-a-Service provider**. It hosts the **Canton participant node** and
  the **Registry Utility application** (operator backend API + UI). On the node it holds its own
  **node-level signing key(s)** ("Key 4" — authenticate the node's protocol messages to the mediator and
  sequencer, including confirmation responses and ACS-commitment signing) and **encryption key(s)**
  ("Key 5" — decrypt the per-view session key that in turn decrypts each incoming transaction view).
  These are the node's own keys; "Key 4 / Key 5" is shorthand used throughout this document. It holds
  **no party signing key**.
- **Utility Provider** is **minimalist**: it supplies the Registry Utility templates and acts as the
  **credential operator at onboarding only**, then steps back. It operates **no standing party** in the
  day-to-day mint / transfer / redeem flows.

**Three facts carry most of the answers, all verified against the Daml source and onboarding design:**

1. **No one but the Institution can sign a transaction.** Parties are external, so signing keys are in
   the Institution's signing KMS; the node has confirmation rights only (not signing authority). Separately,
   the Registry Utility's `operator` party is an **observer** (never signatory or controller) on the
   actual balance contract (`Holding`: `signatory registrar, owner, getLockers this`) and on every
   token-movement template — `InstrumentConfiguration` (`signatory provider, registrar` /
   `observer operator`), `TransferRule`, `AllocationFactory` (the live mint/burn/transfer/allocation
   path), and Lock/Unlock — so it cannot mint, burn, or transfer ownership of any holding. The one
   App-service-layer exception is the live, operator-controlled `RegistrarService_SplitHolding` /
   `MergeHolding` (`Service/Registrar.daml:392-414`), which split or consolidate a holder's *own*
   holdings without changing owner or total amount, via a registrar/provider-cosigned service
   contract — an integrity surface, not a token movement or custody path. Custody rests entirely with
   the Institution.
2. **The Node Provider's authority is delegated and revocable.** Because the Institution holds the namespace
   keys, it can revoke the node's hosting permission and its node-level keys through a topology change
   at any time — including to migrate to a different provider.
3. **One real exposure remains: confidentiality.** Key 5 lives on the Node Provider node, so the node
   **can decrypt and see** the Institution's transaction contents (counterparties, amounts,
   instruments). External parties stop the node *forging*; they do not stop it *seeing*. This is a
   confidentiality risk to manage contractually (Q4), not a custody risk.

Answer tags: **[Node Provider SLA/DPA]** = source from the contract; **[risk acceptance]** = needs formal
sign-off; **[verify in config]** = configuration/topology check before go-live.

---

## Q1 — the IdP (OIDC) OIDC: validation required when available *(Critical)*

The Ledger API on the Node Provider node is protected by OIDC bearer tokens; the Institution's
orchestrator authenticates with them. Key architectural point: a token only lets a caller *submit* —
it cannot *sign*. Signing is a separate signing KMS step, so a stolen token alone cannot move assets.

| # | Sub-question | Answer |
|---|---|---|
| 1 | Is the audience (`aud`) claim restricted to the Node Provider node's specific application ID only? | It must be. Canton's JWT auth supports `targetAudience`; when set, the node rejects any token whose `aud` does not exactly match. If blank, any tenant-signed token is accepted. **Action: confirm `targetAudience` is pinned to this node's application ID. [verify in config]** |
| 2 | Can other applications in the same the IdP (OIDC) tenant (e.g. other tenant clients) obtain tokens the node would accept? What prevents cross-application access? | If `aud` is unpinned, another tenant app could in principle obtain an accepted token — but the impact is doubly bounded: the token maps only to a user with act-as rights on specific parties, **and** it cannot sign (the signing KMS must sign every submission). Pinning `aud` and `iss` is the primary fix; the external-party signing gate is defence-in-depth. **[verify in config]** |
| 3 | Is RBAC enforced via claims/roles, or does any valid token grant full Ledger API access? | Role-based. Each token maps to a user with explicit **act-as / read-as** rights per party. A valid token is not blanket access. **Action: confirm the orchestrator user is least-privilege. [verify in config]** |
| 4 | How does the node validate incoming tokens? (JWKS discovery vs pinned URI, issuer validation, expiry) | Validates the JWT signature against the configured IdP JWKS URL (pin the URI rather than open discovery), the `aud` claim (via target-audience), and `exp`/`nbf` (with configurable leeway and an optional max token lifetime). Trust in the issuer is established by **pinning the JWKS URL / key source rather than a separate `iss`-string check** — Canton's JWT config documents JWKS/audience/expiry validation but no explicit issuer-validation knob; confirm whether issuer validation is available/required in the deployed Canton version. Rejected at the API boundary before any command runs. **Action: confirm JWKS pinning and key-rotation handling. [verify in config]** |
| 5 | What is the configured token lifetime? Are refresh tokens used, or is re-authentication required on each expiry? | Set on the IdP (OIDC) side, not in Canton. Recommended: short access-token lifetime (≤1h), orchestrator re-mints via client-credentials; the node never sees refresh tokens. **Confirm the configured lifetime with the IdP owner.** |
| 6 | What is the timeline for this implementation? Is there a plan to review it before GA go-live? | A programme item. Recommend making the `aud` and JWKS pinning checks (Q1.1, Q1.4) explicit go-live gates with sign-off in this document. |

---

## Q2 — Canton/Utility Provider Utilities portal: production security posture *(Critical)*

The "portal" is the Registry Utility UI and operator backend, which **Node Provider hosts** alongside the
node. The natural concern — that whoever hosts the portal could initiate or tamper with production
transactions — does not hold here, for structural reasons.

| # | Sub-question | Answer |
|---|---|---|
| 1 | How is portal access authenticated? Via the same the IdP (OIDC) OIDC, or a separate mechanism? | The operator backend serves **choice context** (contract IDs and disclosed contracts the orchestrator needs to build a command). The actual submission goes through the OIDC-protected Ledger API (Q1) and is signing KMS-signed. Portal access and transaction authority are therefore separate concerns. **Confirm the backend's own auth mechanism with Node Provider. [Node Provider SLA]** |
| 2 | Who has access? Only Institution personnel, or do Node Provider/Utility Provider staff also have accounts? | Transaction initiation is effectively Institution-only, because initiation requires a signing KMS-signed submission and only the Institution holds the keys. Node Provider staff operate the node and can *see* decrypted data (Key 5, Q4) but cannot *act* as any party. Utility Provider is involved only at onboarding. No Node Provider or Utility Provider account can mint/transfer/burn the Institution's holdings. |
| 3 | What transaction types can the portal initiate on production? (mint, transfer, burn, or only specific test workflows?) | None that move value. On the token-movement templates (`AllocationFactory` mint/burn/transfer, `TransferRule`, `Holding`) the `operator` party is an **observer only — never a controller** — so the hosted app cannot initiate or complete a mint, transfer, or ownership change. (Operator *does* control the live App-service `RegistrarService_SplitHolding` / `MergeHolding` choices, which only split/merge a holder's *own* holdings without changing owner or amount and run via a registrar-cosigned service contract; this is not a value-moving transaction but is a real operator-authored mutation of holding state.) |
| 4 | What controls prevent portal-initiated test transactions from affecting production client balances? | The conclusion holds, and the load-bearing reason is the **external signing key**: production holdings require the Institution's external signing KMS key to author any movement (`Holding_Transfer`/`Holding_Lock` are co-controlled by the `owner`, whose key is in the Institution's signing KMS), and the portal host holds no Institution party key. The `operator` party is **the Utility Provider's Canton Network operator** (`operator::<redacted>…`), hosted on the Utility Provider's own participant node — not the Institution and not Node Provider — and it is observer-only on all holding/token-movement contracts; its only live powers (`RegistrarService_SplitHolding`/`MergeHolding`) re-partition a holder's own holdings without changing owner or amount and cannot move value. So neither Node Provider (no party key) nor a compromised registry app can author a value-moving transaction against a production holding. A separate test namespace is recommended hygiene on top. **[verify in config]** |
| 5 | Is there RBAC to limit which users can initiate transactions vs read-only access? | Yes, at two levels: act-as vs read-as rights at the Ledger API, and the independent signing KMS-signing gate for initiation. A read-only operator gets read-as with no path to signing. |
| 6 | Is there audit logging of all portal-initiated transactions? | Yes, from two independent sources: the **append-only, sequencer-ordered** on-ledger record via UpdateService (tx ID, acting party, choice, sequencer timestamp) — tamper-evident and not alterable, though subject to the participant's pruning/retention configuration — and the Institution's signing KMS audit log of every signing event. The two reconcile against each other. |
| 7 | Are there network-level restrictions (IP allowlisting, VPN-only access)? | Traffic to the node and backend is over TLS; the node uses a fixed egress IP whitelisted by the network sponsor. Pinning the orchestrator's egress to the Node Provider's documented endpoints is an Institution-side control to confirm. **[verify in config]** |

---

## Q3 — Node Provider node logging: GA baseline *(Critical)*

Two log planes: the **ledger event history**, which the Institution reads itself via the Ledger API,
and **Node Provider infrastructure/access logs**, which are contractual.

| # | Sub-question | Answer |
|---|---|---|
| 1 | Has node logging been resolved for GA? Are logs now flowing to the Institution's SIEM (the SIEM)? | The ledger event history is always available via UpdateService regardless of forwarding. Forwarding the Node Provider's *infrastructure* logs into the Institution's SIEM is a separate integration to confirm. **[Node Provider SLA]** |
| 2 | If not flowing to SIEM, what is the mechanism to retrieve them? (API, dashboard, support request) | Ledger history: self-service via API. Infrastructure logs: Node Provider dashboard or support request. **[Node Provider SLA]** |
| 3 | If a security incident occurs, what is the process and SLA to obtain relevant logs from Node Provider? | Belongs in the incident-response section of the SLA. The Institution already holds full ledger evidence without Node Provider. **[Node Provider SLA]** |
| 4 | What is the retention period for logs on the Node Provider side? | Infrastructure logs: contractual **[Node Provider SLA]**. On-ledger history: governed by the participant's pruning configuration, which the Institution controls. |
| 5 | Do logs capture sufficient detail for forensic investigation? (transaction IDs, party identifiers, timestamps, error conditions) | At the ledger layer, yes — tx ID, parties, choices, ordered timestamps, all immutable — plus the signing KMS signing trail. Host/network logs supplement these. **[Node Provider SLA]** |

---

## Q4 — Data visibility at Node Provider *(Critical)*

The central trust question, answered candidly. Because **Key 5 is on the Node Provider node**, the node
**can decrypt and see** the Institution's transaction contents. It can see; it cannot act (external
parties + observer operator). This is a confidentiality exposure to manage contractually, not a custody
or integrity risk.

| # | Sub-question | Answer |
|---|---|---|
| 1 | What specific data fields are visible to Node Provider? (e.g. sender/receiver party IDs, amounts, asset type, timestamps) | Through its node-level encryption key, Node Provider can decrypt the transaction views for the Institution's hosted parties: counterparty party IDs, amounts, instrument/asset types, and timestamps. The node's PostgreSQL holds these as decrypted payloads. Canton sub-transaction privacy limits this to transaction views in which one of the Institution's hosted parties is a stakeholder/informee — the node decrypts only those views, not the private sub-views of other participants' parties. Where the Institution's party is a counterparty in a shared transaction (e.g. a DvP with another institution), the node sees the shared views it is entitled to, but not that counterparty's unrelated or private views. What it cannot do: sign or submit as any party (external keys), or perform namespace operations. **This visibility is the genuine residual exposure.** Externalising the encryption key to a KMS (a supported Canton feature) moves the private key *material* off the node and makes key use auditable and revocable, which reduces key-exfiltration risk — but it does **not** by itself eliminate the operator's ability to see decrypted views: the node is the execution/validation environment and must decrypt views in-process, so plaintext transaction contents remain transiently in node memory and typically in its store on Node Provider infrastructure. Treat external KMS as a hardening control, not a guarantee of confidentiality from the node operator; residual visibility must still be managed contractually (Q4.2/Q4.3). |
| 2 | Does the data governance agreement restrict the Node Provider's use of this data? (e.g. no sharing, no analytics, deletion on termination) | This is load-bearing here precisely because the data *is* visible (Q4.1). The agreement should restrict Node Provider to operating the service — no secondary analytics, no sharing, deletion on termination. **Obtain and review the DPA. [Node Provider DPA]** |
| 3 | Are Node Provider personnel with access to node data subject to any Institution-approved vetting or background checks? | Covered by the Node Provider's SOC 2 Type II / ISO 27001 controls; obtain the attestations. Given Key 5 visibility, personnel vetting is a meaningful control. **[Node Provider SLA]** |

---

## Q5 — Independent balance verification design *(Critical)*

Can the Institution prove its on-chain position without trusting Node Provider? Yes — on capabilities
native to Canton, not features of the host.

| # | Sub-question | Answer |
|---|---|---|
| 1 | Is a reconciliation process planned for GA? If so, what is its design and frequency? | Yes. The Institution reads its holdings from the Ledger API (active-contract set at an offset), sums holding amounts per instrument for its parties, and compares against the internal ledger at the same cut-off. Canton reinforces this: participants exchange cryptographic active-contract-set commitments with counterparties every commitment period, raising a mismatch alarm on divergence. Run reconciliation on that cadence plus a full end-of-day pass. |
| 2 | How does the Institution independently verify that on-chain balances match the Internal Ledger (system of record)? | The holding figures are read straight from the ledger — no reliance on a Node Provider dashboard or supplied number. The Institution holds the keys and can validate the payloads itself. And because every balance change was signing KMS-signed by the Institution, the signing KMS log is an independent second source for the expected position. |
| 3 | In a dispute, what evidence can the Institution produce that is independent of Node Provider? | Three independent, mutually reinforcing sources: the sequencer-ordered transaction history (UpdateService); the counterparty-signed active-contract-set commitments (non-repudiable proof of agreed state per period); and the Institution's signing KMS signing log. All exportable with no Node Provider involvement. |
| 4 | Has the architectural difference from Base (where EOD reconciliation against a globally available ledger is possible) been formally risk-accepted? | Needs sign-off. Honest framing: Canton is privacy-preserving — there is no global public ledger to reconcile against; reconciliation is bilateral and cryptographic (per-counterparty commitments). Stronger for confidentiality, but a different model; the absence of third-party-observable global state should be explicitly accepted, with the commitment-based reconciliation and signing KMS trail documented as compensating controls. **[risk acceptance]** |

---

## Q6 — dApp-to-Node Provider transport security: remediation plan *(Critical)*

This link carries the orchestrator's prepare/execute calls. The transaction is signing KMS-signed, so a
compromised link cannot forge one — but a bearer token on it is replayable, which is why mTLS matters.

| # | Sub-question | Answer |
|---|---|---|
| 1 | Is mTLS with Node Provider planned for GA? If not, what is the timeline? | Canton's Ledger API supports mTLS (client-cert) on top of the OIDC bearer token. Recommend enabling it for GA so the bearer token is not the sole credential on an internet-traversing path. Confirm whether the Node Provider's endpoint enforces client certs. **[Node Provider SLA]** |
| 2 | Is certificate pinning feasible given the proxy architecture? | Generally yes — pin the endpoint's server cert or issuing CA. If a Node Provider proxy terminates TLS, pin the proxy cert and confirm the proxy-to-node hop is also TLS. **[verify in config]** |
| 3 | Will egress be restricted to specific Node Provider IP ranges/FQDNs, or is wide egress accepted as mitigated by proxy controls? | Recommend pinning the orchestrator's egress to the Node Provider's documented endpoints; document any wide-egress acceptance with the proxy as the stated compensating control. **[verify in config]** |
| 4 | Has the risk of relying solely on bearer-token authentication (without mTLS) over an internet-traversing connection been formally assessed? | Should be assessed and recorded. Mitigating factor: a bearer token cannot sign (the signing KMS must), and replay is blocked because input contracts are consumed on execution, so interception cannot cause **theft** of holdings. It **can**, however, cause unauthorised **disclosure**: reading the ACS/transaction history requires no signature, exposing exactly the confidential data flagged in Q4 (counterparties, amounts, instruments, timestamps). The read exposure is a genuine confidentiality breach, not a benign outcome, and its scope depends on the orchestrator user being least-privilege (Q1.3). Recommended remediation: mTLS + short token lifetime + pinned `aud` + least-privilege read-as scope — required mitigations, not merely recommended. **[risk acceptance]** |

---

## Q7 — Node Provider multi-region failover: GA status *(Critical)*

| # | Sub-question | Answer |
|---|---|---|
| 1 | Has dApp failover to the secondary node been implemented for GA? | The node-level HA commitment sits in the Node Provider's SLA; confirm with a tested RTO/RPO. **[Node Provider SLA]** The architecture makes failover clean: because all party signing keys live in the Institution's signing KMS (external parties), a secondary node serves the **same parties with no key migration** — the orchestrator simply re-points to the secondary endpoint and keeps signing with the same keys. |
| 2 | Are both nodes active-active or active-passive? | **[Node Provider SLA]** — a topology/operations question for Node Provider. Canton participants are typically run active-passive for a given party hosting; confirm the Node Provider's specific design and whether the secondary is hot or warm. |
| 3 | Is data replicated synchronously between regions? | **[Node Provider SLA]** — depends on the Node Provider's PostgreSQL replication design. Note the Institution does not rely on this for correctness: the ledger state is reconstructable from the network, and the Institution's signing KMS + reconciliation (Q5) provide independent recovery of the expected state. Confirm the Node Provider's replication mode and its RPO implication. |
| 4 | If the primary fails, is failover transparent to the dApp (same endpoint, DNS-based) or does the dApp need to switch endpoints? | **[Node Provider SLA / verify in config]** — confirm whether Node Provider presents a stable endpoint (DNS/load-balancer failover) or expects the orchestrator to switch. Either is workable; if endpoint-switching, the orchestrator's failover logic must enumerate the secondary endpoint and re-point its prepare/execute calls. **Action: obtain the Node Provider's runbook and confirm the orchestrator handles the chosen mode.** |

---

## Q8 — Break-glass / emergency operations for GA *(Critical)*

These probe what can be done in an emergency (freeze/recover assets) and who can do it. The honest
architectural answer is that emergency *control* stays with the Institution, and the available
mechanisms depend on the Registry Utility templates in use.

| # | Sub-question | Answer |
|---|---|---|
| 1 | Has ForcedTransfer functionality been implemented, or is a workaround in place? | In the deployed templates (registry-model v0.6.0, registry-app v0.7.0) there is **no functional registrar-controlled forced transfer**. The `ForceTransfer` module is disabled as of v0.2.0 (every template `ensure False`; every choice `deprecatedChoice`), and its successor the **EnforcementService** — the mechanism the Utility Provider's docs describe as registrar-led forced transfer, introduced in registry-app v0.3.4 — is likewise disabled in the extracted v0.7.0, along with every `RegistrarService` force-transfer/enforcement choice. A standard `Transfer` cannot substitute as a unilateral recovery lever: `TransferRule_DirectTransfer` / `TwoStepTransfer` are controlled by `transfer.sender, transfer.receiver`, so the holder's own (signing KMS-signed) party must authorise any movement of its assets. **[verify in config: confirm deployed package versions and whether a later registry-app re-enables EnforcementService]** Whatever the eventual mechanism, it is exercised by an Institution party (signing KMS-signed), not by Node Provider or the Utility Provider. |
| 2 | Has Pauser functionality been implemented, or is a workaround in place? | No pause/suspend/freeze template exists in the deployed source; the sole lever is `Credential_Revoke` (archives the credential). Credential suspension halts mint/transfer for the affected party **only** for instruments whose `InstrumentConfiguration` defines non-empty `holderRequirements` / `issuerRequirements` — an instrument configured with empty requirements is not gated, and revoking a credential does not stop its transfers. **[verify in config: confirm each production instrument's requirements are populated]** Credential suspension is Institution-controlled. |
| 3 | If neither is available, what is the emergency response procedure if a security incident requires freezing or recovering on-chain assets? | Where an instrument is configured with credential requirements, the credential layer is the lever: the transfer, allocation, mint and burn choices call `assertFulfillsAllRequirements` against the instrument's requirements, fetching each credential via `Credential_Get`. Revoking a holder's credential (`Credential_Revoke`) makes that fetch fail, so subsequent gated transfers/mints for that party abort. **Caveat:** this only holds for instruments with non-empty requirements (the Utility Provider docs: *"if no credentials are required … you can perform that action without any credentials"*), so revocation does **not** freeze transfers of an instrument configured without requirements. There is no separate credential-gated 'lock' choice (the standalone Lock module is disabled as of registry-model v0.5.0); locking occurs only as an internal step inside the same credential-checked transfer flow. Recovery of mis-sent holdings **cannot** be done unilaterally by the registrar in these versions: standard Transfer choices are controlled by sender and receiver, and the registrar-led ForceTransfer/EnforcementService path is disabled (Q8.1) — recovery requires the current holder's authorising party to cooperate. Document this as the runbook (ties to Q8.5). **[risk acceptance]** for the documented procedure. |
| 4 | Can Node Provider take any action on the Institution's behalf in an emergency, or are they strictly limited to node operations? | Strictly node operations. Node Provider holds no party signing key, and the value-moving primitives require the asset owner's co-authorisation (`Holding_Lock` is controlled by `registrar, owner, lockers`; `Holding_Transfer` by `registrar, owner, newOwner` — never operator alone), so through the Daml application layer it **cannot** freeze, transfer, or recover assets; emergency *asset* actions require the Institution's signing KMS. **Trust caveat:** because Node Provider hosts the external parties as their confirming participant node at confirmation threshold = 1, a malicious/compromised Node Provider node could — per Canton's trust model — approve a transaction carrying an invalid external signature. The boundary is therefore an honest-single-CPN trust assumption, not an unconditional guarantee; to make it Byzantine-resistant, host each party on ≥2 independent CPNs with threshold > 1. The on-ledger/signing KMS audit trail (Q5) detects such an action but does not prevent it. (Operator *does* control the live `RegistrarService_SplitHolding` / `MergeHolding` choices, which re-partition a holder's own holdings without changing owner or total amount — an integrity, not a custody, surface.) **[verify in config: CPN count + confirmation threshold]** |
| 5 | Is there a documented runbook for Canton-specific incident scenarios? | **[risk acceptance / documentation]** — should exist covering: credential suspension to freeze, registrar-led recovery transfers, node failover (Q7), key revocation (Q10.4), and signing KMS unavailability. Confirm it is written and signed off before GA. |

---

## Q9 — Key rotation: compliance gap *(Critical)*

| # | Sub-question | Answer |
|---|---|---|
| 1 | Is key rotation supported for the Canton namespace keys without disrupting on-chain identity? | Yes for **operational** keys — Canton supports rotation of signing/encryption and intermediary delegation keys via topology (`OwnerToKeyMapping` / namespace delegation updates) without changing the party's on-chain identity, because identity is the namespace, not a specific operational key. Rotation publishes a new key and retires the old via signed topology transactions. The one exception is the **root namespace key**, which is permanent and cannot be rotated (see Q9.2). **[verify in config]** for the documented procedure. |
| 2 | What is the process to rotate the root namespace key vs the signing key vs the intermediary key? | The **root namespace key** is a permanent trust anchor and **cannot be rotated** — the namespace is identified by the root key's fingerprint, so rotating it would change on-chain identity. It is held in cold storage under dual control and never rotated; if it is ever compromised, the only remedy is migrating to a new namespace and transferring contracts to new parties. What rotates under it is the **intermediary/delegation key**: the root signs a new namespace delegation to a fresh intermediate key and revokes the old delegation — the highest-ceremony operation that still preserves namespace identity. **Per-party signing keys** (in signing KMS) rotate by publishing a new `OwnerToKeyMapping` (or the relevant `PartyToKeyMapping` / `PartyToParticipant` key declaration) and retiring the old. The rotatable operations are signing KMS-signed by the Institution. **Document each as a runbook. [verify in config]** |
| 3 | For the Node Provider API credentials (username/password in the secrets manager): is there a credential rotation policy for GA? Can rotation be automated, or does it require manual coordination with Node Provider? | **[Node Provider SLA / verify in config]** — these are the API/IdP credentials the orchestrator uses, distinct from Canton keys. Confirm whether Node Provider supports automated rotation (e.g. client-credentials re-mint) or requires manual coordination, and bring them under the Institution's Secrets Manager rotation policy. |
| 4 | If rotation is not feasible for certain keys, has a control procedure exception been filed? | **[risk acceptance]** — the cold **root namespace key cannot be rotated at all** (the namespace is its fingerprint; see Q9.2), so a control-procedure exception MUST be filed for it, with compensating controls: cold storage, dual control, monitored access, and a documented namespace-migration runbook as the only recovery path if the root key is ever compromised. |

---

## Q10 — Topology permission enforcement: submit vs sign boundary *(Critical)*

This is the question that defines the whole trust model. The external-party design answers it: the node
hosts and confirms the party, but holds no signing key, so it cannot author a transaction on the party's
behalf — subject to one trust assumption recorded in Q10.2.

| # | Sub-question | Answer |
|---|---|---|
| 1 | How was the Node Provider's node key granted submit-only permissions? What topology transaction was used? | Via the `PartyToParticipant` topology mapping, which hosts each external party on the Node Provider participant with **Confirmation permission only (NOT Submission)** — Canton forbids Submission permission for external parties, so the participant is a Confirming Participant Node (CPN), not a Submitting Participant Node. The party's **signing key stays external** (in the Institution's signing KMS), declared via `PartyToKeyMapping` (which grants signing authority to no node; in newer Canton the key may instead be declared within `PartyToParticipant`, which takes precedence). The node validates/confirms and relays the externally-signed transaction via the Interactive Submission flow, but cannot itself author or sign a transaction on the party's behalf. **[verify in config]** — the exact topology transactions are in the onboarding ceremony. |
| 2 | Is this enforced cryptographically by the Canton protocol (the network rejects signing attempts from the node key), or is it a configuration-level restriction on the node? | **Cryptographically, but with one recorded trust assumption.** A party's namespace is derived from its own key (in signing KMS); the Interactive Submission protocol requires that key's signature over the transaction hash, and the node does not possess the key, so a transaction submitted without the signing KMS signature is rejected by an honest confirming node. **Trust caveat:** the external signature is validated by the party's Confirming Participant Node(s), not independently re-checked by the synchronizer/mediator. Canton's docs state that *"if threshold many CPNs are malicious, they can incorrectly approve an invalid transaction … including transactions with an invalid external signature for external parties."* This deployment uses a single Node Provider CPN at confirmation threshold = 1, so the guarantee reduces to trusting that one node to honestly run the signature check. (Note: the guarantee comes from the external signing key, not from the topology permission flag — the Submission-vs-Confirmation distinction is enforced only in the participant node.) Host each party on ≥2 independent CPNs with threshold > 1 to make it trust-minimised. **[verify in config: CPN count + threshold] [risk acceptance: single-CPN integrity trust]** |
| 3 | Can this permission boundary be verified independently by the Institution (e.g. by querying topology state)? | Yes — the Institution queries the node's Topology Read API (`TopologyManagerReadService`, e.g. `ListPartyToParticipant` / `ListPartyToKeyMapping`) and inspects the records to confirm the node holds only **Confirmation** rights (NOT Submission) and that the party's signing key maps to the Institution's signing KMS fingerprints. (In newer Canton versions the key may be declared within `PartyToParticipant`, which takes precedence; read whichever mapping carries the key.) This is a self-service, independent check. **[verify in config]** |
| 4 | What is the process to revoke the Node Provider's submit permission if needed (e.g. migration to a different NaaS provider)? | The Institution issues a topology change removing/replacing the `PartyToParticipant` mapping (and the node's own signing/encryption keys), signed with its namespace keys. Because identity is the namespace the Institution controls, the parties survive the move and can be re-hosted on a new provider's node without changing on-chain identity. **Document as a migration runbook.** |

---

## Q11 — Node Provider SLA and legal agreements: GA status *(Important)*

| # | Sub-question | Answer |
|---|---|---|
| 1 | Are these agreements now signed? | **[Node Provider SLA]** — contractual status to confirm; not derivable from the architecture. |
| 2 | Does the SLA include provisions for security incident notification to the Institution? (timeframes, severity thresholds) | **[Node Provider SLA]** — confirm the notification window and severity thresholds in the agreement. |
| 3 | Does the agreement cover the Node Provider's obligation to cooperate with the Institution's forensic investigations? | **[Node Provider SLA]** — confirm the cooperation clause. Note the Institution already holds independent ledger + signing KMS evidence (Q3, Q5), so cooperation covers infra-level forensics. |

---

## Q12 — Canton Network operational dependencies *(Important)*

These concern the shared network infrastructure (sequencers, mediators, super-validators) beyond the
Institution's own node.

| # | Sub-question | Answer |
|---|---|---|
| 1 | Who operates these shared Canton Network components? | The synchronizer infrastructure (sequencers, mediators) and super-validators are operated by Canton Network / Global Synchronizer Foundation participants, not by Node Provider or the Institution. The Institution's node is a participant that connects to them. **Confirm the specific operators for the deployed synchronizer.** |
| 2 | What is the SLA/availability commitment for the Canton Network infrastructure? | **[network/contract-dependent]** — sourced from the Global Synchronizer Foundation / synchronizer operator terms, not the Node Provider's SLA. Confirm the availability commitment for the synchronizer the node connects to. |
| 3 | Has Utility Provider undergone TPO review? (the TPO Cyber Deviation Report identified 2 Critical and 6 High findings — what is the remediation status?) | **[the Utility Provider/contract-dependent]** — request the remediation status of the cited Critical/High findings directly from Utility Provider. Architectural mitigant: the Utility Provider's role here is minimalist (credential operator at onboarding, template supplier) with no standing production party and no signing authority over the Institution's holdings, which bounds the exposure of Utility-Provider-side findings — but the remediation status should still be obtained and the residual risk assessed. **[risk acceptance]** |

---

## Q13 — Preapproval failure handling: GA status *(Important)*

These concern what happens when a transfer is not accepted by the receiver.

| # | Sub-question | Answer |
|---|---|---|
| 1 | What is the implemented procedure for handling unaccepted transfers? | In the Registry Utility's two-step transfer model, requesting a transfer **locks** the offered amount of the sender's holding (split out and held under the registrar) and creates a `TransferOffer`; the assets are not delivered to the receiver until acceptance. If the receiver rejects or the sender withdraws, the locked holding is unlocked and returned as change. So the sender does not lose the assets and they are never moved to the receiver, but the offered amount is locked (not freely spendable) while the offer is pending — it is not left fully intact. The procedure is to track open offers via the orchestrator and re-issue or withdraw them. **Confirm the deployed templates' offer lifecycle. [verify in config]** |
| 2 | How are funds held by the Institution on-chain tracked and reconciled? | Via the same mechanism as Q5: holdings are read from the Ledger API and reconciled against the internal ledger, with open (unaccepted) transfer offers tracked as a distinct state so in-flight amounts are not double-counted. |
| 3 | Is there a timeout/expiry mechanism, or do unaccepted offers persist indefinitely? | Partially. The Splice token-standard Transfer payload carries an `executeBefore` deadline (and `requestedAt`), and the templates enforce that an offer cannot be **accepted** after `executeBefore` (`assertWithinDeadline` on the accept path). However, this deadline is set per-transfer by the requester, not a fixed template TTL, and an expired-but-unaccepted offer is **not auto-archived**: the offered holding stays **locked** until the sender exercises Withdraw (or the receiver Rejects). The orchestrator should set a sensible `executeBefore` and actively withdraw stale offers to release locked holdings, so they do not persist indefinitely. Document the chosen behaviour. **[verify in config]** |

---

# BD-Q Series — Node Provider vendor due-diligence

These are **vendor/contract** questions, not architecture questions. They must be sourced from
the Node Provider's SOC 2 Type II / ISO 27001 reports, the MSA/SLA, and the DPA. Answers below state the
expected baseline and the **evidence to obtain** — do not record as facts until the artifact is in hand.
Architectural mitigants are noted where the external-party + observer-operator design reduces the impact
of a given vendor control.

## BD-Q1 — Security certifications *(High — required before sign-off)*

| # | Sub-question | Answer / evidence |
|---|---|---|
| 1 | Does Node Provider hold SOC 2 Type II, ISO 27001, or equivalent certification covering the infrastructure used to host the Institution's Canton node? | **[Node Provider SLA]** — request the certificate scope and confirm it covers the specific hosting environment (region, service) used for this node. |
| 2 | If so, can a copy of the report or certificate be provided? | **[Node Provider SLA]** — obtain the report/cert for the document. |
| 3 | What is the audit period and next renewal date? | **[Node Provider SLA]** — confirm the period is current and note the renewal date. |

## BD-Q2 — Privileged access management for Node Provider staff *(High)*

| # | Sub-question | Answer / evidence |
|---|---|---|
| 1 | How do Node Provider engineers access the Institution's production Canton node infrastructure? | **[Node Provider SLA]** — request the access architecture (bastion/PAM, MFA, approval flow). Mitigant: even full node access cannot sign as a party (external keys) — but it *can* see data via Key 5 (Q4), so this control matters for confidentiality. |
| 2 | Is a PAM solution (e.g. CyberArk, HashiCorp Boundary) in use? | **[Node Provider SLA]** — expect a named PAM/bastion solution. |
| 3 | Is access just-in-time (JIT) or persistent? | **[Node Provider SLA]** — JIT (time-boxed, approval-gated) is the expected baseline; standing admin access is a finding to flag. |
| 4 | Are privileged sessions recorded and audit-logged? | **[Node Provider SLA]** — expect full session recording with tamper-evident retention; request a sample/attestation. |
| 5 | Is the Institution notified when Node Provider staff access its node environment? | **[Node Provider SLA]** — confirm whether access-notification is available. Defence-in-depth here, given staff cannot act on assets. |

## BD-Q3 — Penetration testing cadence *(High)*

| # | Sub-question | Answer / evidence |
|---|---|---|
| 1 | Is the Canton node infrastructure subject to annual independent third-party penetration testing? | **[Node Provider SLA]** — expect at least annual independent testing. |
| 2 | When was the most recent test conducted? | **[Node Provider SLA]** — obtain the date; confirm within 12 months. |
| 3 | Were any critical or high findings identified, and what is their remediation status? | **[Node Provider SLA]** — request findings summary and remediation evidence. |
| 4 | Can a summary or attestation letter be provided? | **[Node Provider SLA]** — request the attestation letter for this review. |

## BD-Q4 — Incident notification SLA to the Institution *(High)*

| # | Sub-question | Answer / evidence |
|---|---|---|
| 1 | What is the contractual obligation to notify the Institution? (timeframe, severity threshold) | **[Node Provider SLA]** — confirm the notification window and triggering severity in the MSA/SLA. |
| 2 | What is the escalation path and contact for security incidents? | **[Node Provider SLA]** — obtain named escalation contacts and out-of-hours path. |
| 3 | What constitutes a notifiable incident under the agreement? | **[Node Provider SLA]** — confirm the definition covers the Institution's threat model (data exposure via Key 5, availability, key handling). |

## BD-Q5 — Patch and vulnerability management SLA *(High)*

| # | Sub-question | Answer / evidence |
|---|---|---|
| 1 | What are the SLAs for applying security patches to the Canton node infrastructure? | **[Node Provider SLA]** — obtain the patch-SLA matrix by severity. |
| 2 | Critical CVE: target remediation timeframe? | **[Node Provider SLA]** — expect a short defined window; confirm the figure. |
| 3 | High CVE: target remediation timeframe? | **[Node Provider SLA]** — confirm the defined window. |
| 4 | Is the Institution notified of patching activity that may affect node availability? | **[Node Provider SLA]** — confirm maintenance-window notification. Ties to Q7: a patch restart should be covered by failover so it is not client-visible downtime. |

## BD-Q6 — Sub-processor list *(Lower — note as limitation if not available in time)*

| # | Sub-question | Answer / evidence |
|---|---|---|
| 1 | Beyond a cloud provider and a CDN/edge provider (identified in the Node Provider security overview), are any other third-party sub-processors involved in delivering or securing the Institution's Canton node? | **[Node Provider DPA]** — obtain the full sub-processor list. |
| 2 | Are these sub-processors subject to the same security standards as Node Provider? | **[Node Provider DPA]** — confirm flow-down of obligations in the DPA. |

## BD-Q7 — Data retention and deletion *(Lower)*

| # | Sub-question | Answer / evidence |
|---|---|---|
| 1 | What is the retention period for the Institution's transaction data held on the Node Provider node? | On-ledger data follows the Institution-controlled pruning configuration. Any *additional* Node Provider-side copies (backups, decrypted PCS, logs) and their retention are **[Node Provider SLA]** — confirm, since Key 5 means these copies are plaintext. |
| 2 | Upon contract termination, what is the process and timeline for data deletion or return? | **[Node Provider SLA]** — obtain the termination data-handling clause (return + certified deletion, with timeline). Mitigant: on migration the Institution revokes the node's keys/permissions (Q10.4), and external signing keys never resided on Node Provider. |
| 3 | Is deletion certified in writing? | **[Node Provider SLA]** — confirm a written certificate of destruction is provided. |

---

## Summary for the reviewer

This is a **Model B, external-party** deployment. Node Provider runs the infrastructure (node + Registry
Utility app); the Institution holds every party signing key in its own signing KMS and onboards parties as
external, so the node has **confirmation rights only**, not signing authority. Three facts carry the
assurance:

- **No party other than the Institution can author a value-moving transaction.** Every *Institution*
  party signing key (registrar/issuer/receiver) lives in the Institution's signing KMS as external parties;
  Node Provider holds only the node's own confirmation/encryption keys (in its KMS), and the `operator`
  party is the Utility Provider's Canton Network operator hosted on the Utility Provider's own node — observer-only on all
  holding and token-movement contracts, with its only live powers (split/merge) unable to move value or
  change ownership. The
  submit-vs-sign boundary is **anchored in the external signing key** held in the signing KMS — an honest
  confirming node rejects any transaction lacking a valid party signature — **and the topology state is
  independently verifiable** via `TopologyManagerReadService` (Q10). **Caveat to record:** the
  deployment hosts each party on a single Node Provider CPN at confirmation threshold = 1, so the
  guarantee currently rests on Node Provider honestly validating the external signature; a malicious CPN
  could approve a forged-signature transaction (Q10.2). Treat this as a residual trust assumption
  pending multi-CPN hosting (≥2 CPNs, threshold > 1). `[verify in config: CPN count + threshold]`
- **Independent verification, failover, and provider migration do not depend on trusting Node Provider**,
  because the Institution holds the keys, the ledger evidence, and the reconciliation commitments
  (Q5, Q7, Q10.4).
- **The one real exposure is confidentiality:** the node's encryption key lets Node Provider decrypt and
  see the Institution's transaction contents. The controls are contractual — the DPA (Q4.2) and
  personnel vetting (Q4.3, BD-Q2). Externalising the encryption key to a KMS **materially reduces** this
  — moving key custody off the node into an auditable, revocable store — but does not fully eliminate it,
  since the node must still decrypt views in-process to validate them; the contractual controls remain
  necessary.

Items marked **[Node Provider SLA/DPA]** must be sourced from the agreements and SOC 2 / ISO 27001
attestations; **[risk acceptance]** items need formal sign-off; **[verify in config]** items are
configuration/topology checks to complete before go-live.
