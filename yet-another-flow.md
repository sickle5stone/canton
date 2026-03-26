# Key and Party Onboarding

Parties are unique identifiers in the Canton network to represent an individual/entity on the network. This is equivalent to an 0xEthereumAddress.

It follows a <Provider_Registrar|Issuer|Burner>::1220uniqueRootNamespace construct.

We will first need to create the following parties in Hashicorp Vault
- PROVIDER_REGISTRAR
- ISSUER
- BURNER

Next we need to register these parties with the Node-as-a-Service provider via the Topology Transactions.

  1. First, we request for the topology transactions for each of the parties
  - /v2/parties/external/generate-topology

  2. API will return a multi hash with three parts
  - Namespace Delegation
  - PartyToParticipant - This will be used to identify which participant node the party belongs to
  - PartyToKey

  3. Canton dApp will then need to sign these multi-hash + parts with the respective private keys in the Hashicorp Vault

  4. Canton dApp will then submit the topology transactions via a command submitted via the interactive submission workflow. This will return a prepared transaction payload.

  * Reason for interactive submission:
    * Because we are not looking to hold Canton Coins that is required to obtain traffic credit to submit transactions to the Sequencer. We are utilizing an interactive submission workflow where the participant node handles the traffic credit <> Canton coin interaction on behalf of us.

  5. Canton dApp will then sign the prepared transaction payload with the respective private key and execute the submission via the interactive submission workflow.

  6. Canton dApp will then poll via Ledger API /updates /completion endpoints to observe result of the transaction.

  7. Upon successful topology transaction, the Participant Node will submit the topology transaction to the Sequencer node in the Global Synchronizer Domain (operated by Digital Assets).

  8. The synchronizer will handle the propagation of the party into each participant node in the domain network.

# User Service Onboard

The previous steps only create and sync the native party identity across the network. But that doesn't mean every party will want to participate in all DAML templates in the network.

So parties wanting to utilize a service such as the Credential/Registry utilities in the Canton/Digital Assets ecosystem will have to explicitly "register" for these services.

This is done via the UserServiceRequest template (from `utility-credential-app-v0`).

1. Each of our parties creates a UserServiceRequest contract. The request only has the user as signatory — the operator is an observer, not a co-signer.
   - UserServiceRequest { operator, user } → signatory: user, observer: operator

2. The operator then accepts via UserServiceRequest_Accept (controller: operator). This creates the UserService contract.
   - UserService { operator, user, dso } → signatory: operator, user

3. The co-signing happens implicitly — the UserService contract carries both signatories (operator + user), but the user only signed the request, not the accept.

4. Submit via interactive submission — signed with the respective party key.

5. Repeat for Provider_Registrar/Issuer/Burner.

# Provider/Registrar Onboarding

We now move on to setting up the Provider/Registrar, these are admin-like users that control certain products within the Canton ecosystem like transfer rules, instrument configurations, and credential issuance.

1. Provider_Registrar creates a ProviderServiceRequest contract.
   - ProviderServiceRequest { operator, provider } → signatory: provider, observer: operator

2. Operator accepts via ProviderServiceRequest_Accept (controller: operator). The operator validates provider credentials against the OperatorConfiguration requirements.
   - Submit via interactive submission — signed with provider key
   - Result: ProviderService contract created (signatory: operator, provider)

3. Registrar creates a RegistrarServiceRequest contract.
   - RegistrarServiceRequest { operator, provider, registrar, createTransferRule, createAllocationFactory } → signatory: registrar, observer: provider, operator
   - Set createTransferRule and createAllocationFactory to `Some True` to auto-create these on accept

4. Provider accepts via ProviderService_AcceptRegistrarServiceRequest (controller: provider). The provider validates registrar credentials against the ProviderConfiguration requirements.
   - Submit via interactive submission — signed with provider key
   - Result: RegistrarService + TransferRule + AllocationFactory all created in one step (as of v0.6.0)

5. Registrar creates InstrumentConfiguration via RegistrarService_CreateInstrumentConfiguration — defines the token (e.g. DEPO), the admin (registrar), and the credential requirements for issuers and holders.
   - Submit via interactive submission — signed with registrar key

# Credential Issuance

Credentials are standing authorizations that allow parties to act as issuers or holders for specific instruments. Think of them as on-chain permissions.

## Issuer Credential

1. Registrar (as a UserService user) exercises UserService_OfferFreeCredential to create a CredentialOffer for the Issuer party
   - CredentialOffer { operator, issuer: registrar, holder: issuer_party, claims: [{ isIssuerOf: "DEPO" }] } → signatory: operator, issuer; observer: holder
   - Submit via interactive submission — signed with registrar key
2. Issuer accepts via CredentialOffer_AcceptFree (controller: holder)
   - Submit via interactive submission — signed with canton-issuer key
3. Result: Credential contract created (signatory: issuer, holder). Issuer is now authorized to mint DEPO tokens.

## Holder Credential (Internal Party)

Same flow as above — Registrar offers a credential with claims `{ isHolderOf: "DEPO" }` to the internal party, and the internal party accepts via CredentialOffer_AcceptFree.

## Holder Credential (External Party e.g. acme_corp)

This is the onboarding step for an external counterparty like acme_corp.

1. acme_corp passes the partyID to us via a secure channel
2. Registrar exercises UserService_OfferFreeCredential to create a CredentialOffer for acme_corp with claims: `{ isHolderOf: "DEPO" }`
   - Submit via interactive submission — signed with registrar key
3. acme_corp accepts via CredentialOffer_AcceptFree (controller: holder) — signed with acme_corp's own key (this key resides with the client)
   - Submitted by client
4. Result: Credential contract created. acme_corp is now authorized to hold DEPO tokens.

This is the **only** time acme_corp's key is needed during onboarding. The Credential contract serves as standing authorization for all future mints to acme_corp.

# Mint Flow (Bank-Initiated via OfferMint)

Minting is a two-step workflow using the AllocationFactory. There are actually two paths available:

- **AllocationFactory_RequestMint** — controller is `mint.holder`. This is for when the holder (e.g. acme_corp) initiates their own mint request. Not our flow.
- **AllocationFactory_OfferMint** — controller is `registrar`. This is for when the bank initiates a mint on behalf of a client. This is our flow.

We use the OfferMint path because we don't expect our clients to be submitting their own mint requests.

## Step 1 — Off-Chain Settlement

1. Client initiates a "Move to Chain" request in the Bank Portal
2. Core Banking debits the client's DDA and credits the Reserve Account
3. Internal Ledger records the position as PENDING_MINT
4. Event Bus emits a MintRequested domain event
5. Token Orchestrator consumes the event

## Step 2 — Offer Mint (on-chain)

The Registrar creates a mint offer on behalf of the client. acme_corp is not involved in this step at all.

1. Orchestrator calls the Operator Backend API to retrieve the choice context for the mint
   - Returns: AllocationFactory CID, InstrumentConfiguration CID, Issuer Credential CID(s), and disclosed contracts

2. Orchestrator constructs an ExerciseCommand on the AllocationFactory with choice AllocationFactory_OfferMint
   - actAs: bank_registrar (registrar is the controller of OfferMint)
   - mint.holder set to: acme_corp (the intended recipient)
   - Args include: expectedAdmin, mint { instrumentId, amount, holder, reference, requestedAt, executeBefore }, extraArgs with the choice context

3. Submit via interactive submission:
   - PrepareSubmission → get preparedTransactionHash
   - Vault sign with canton-registrar key
   - ExecuteSubmissionAndWait

4. Result: MintOffer contract created on-chain
   - signatories: provider, instrumentId.admin (= registrar, bank controls both)
   - observer: operator, mint.holder (acme_corp can see the offer)

## Step 3 — Accept Mint Offer (on-chain)

Now acme_corp needs to accept the offer. The MintOffer_Accept choice is controlled by `mint.holder`.

1. Orchestrator calls the Backend API to retrieve the accept choice context for the MintOffer
   - Returns: InstrumentConfiguration CID, Issuer Credential CID(s), AppRewardConfiguration CID, and disclosed contracts

2. Construct ExerciseCommand on MintOffer with choice MintOffer_Accept
   - actAs: acme_corp (holder is the controller)
   - Args include the accept choice context (extraArgs)

3. Submit via interactive submission:
   - PrepareSubmission → get preparedTransactionHash
   - Vault sign with acme_corp's key (bank holds this key in the bank-hosted model)
   - ExecuteSubmissionAndWait

4. Result:
   - MintOffer contract archived (consumed)
   - Holding contract created for acme_corp (owner = acme_corp, amount = minted amount)
   - ExecutedMint contract created (audit trail)

* Note: In the bank-hosted key model, the bank generated and holds acme_corp's Vault key. So even though acme_corp is the controller, the bank is the one signing operationally. acme_corp the entity doesn't need to do anything.

## Step 4 — Off-Chain Finalization

1. Orchestrator receives the Holding CreatedEvent from the ExecuteSubmissionAndWait response
2. Internal Ledger updates position from PENDING_MINT to MINTED
3. Bank Portal notified — client sees on-chain balance

# Transfer Flow

Transfer moves a Holding from one party to another. The AllocationFactory_TransferInternal choice is controlled by `provider, registrar, transfer.sender` — so the sender must sign.

1. Orchestrator retrieves the transfer choice context from the Backend API
   - Returns: InstrumentConfiguration CID, sender's Credential CID(s), and disclosed contracts

2. Construct ExerciseCommand on the AllocationFactory with the transfer choice
   - actAs: current holder (e.g. acme_corp) + provider + registrar
   - Args: sender, receiver, instrumentId, amount, inputHoldingCids, transfer context

3. Submit via interactive submission — signed with the holder's key + canton-registrar key (all three controllers must authorize)

4. Result:
   - A TransferOffer contract is created (signatory: provider, instrumentId.admin, sender; observer: operator, receiver)
   - Original Holding is locked during the transfer (locked with registrar as locker)
   - Remainder Holding created for the sender if partial transfer

5. Receiver accepts the TransferOffer via TransferInstruction_Accept (controller: transfer.receiver)
   - Submit via interactive submission — signed with receiver's key
   - The accept exercises a TransferRule_TwoStepTransfer under the hood
   - Result: locked Holding archived, new Holding created for the receiver

# Redeem (Burn) Flow

Redemption burns on-chain tokens and triggers off-chain settlement back to fiat. Same two-path pattern as mint:

- **AllocationFactory_RequestBurn** — controller is `burn.holder`. Holder-initiated burn.
- **AllocationFactory_OfferBurn** — controller is `registrar`. Bank-initiated burn.

## Path A — Holder-Initiated Burn (RequestBurn)

If acme_corp wants to redeem their tokens:

1. Holder exercises AllocationFactory_RequestBurn on the AllocationFactory
   - actAs: acme_corp (holder is controller)
   - Args include: expectedAdmin, burn { instrumentId, amount, holder, reference, requestedAt, executeBefore }, holdingCids, extraArgs
   - Submit via interactive submission — signed with acme_corp's key
2. Result: BurnRequest contract created + Holding is locked (locked with registrar as locker)

3. Registrar exercises BurnRequest_Accept on the BurnRequest (controller: burn.instrumentId.admin)
   - actAs: bank_registrar
   - Submit via interactive submission — signed with canton-registrar key
4. Result:
   - BurnRequest archived
   - Locked Holding archived (tokens burned)
   - ExecutedBurn contract created (audit trail)

## Path B — Bank-Initiated Burn (OfferBurn)

If the bank initiates the burn:

1. Registrar exercises AllocationFactory_OfferBurn
   - actAs: bank_registrar (registrar is controller)
   - Args include: expectedAdmin, burn { instrumentId, amount, holder, reference, requestedAt, executeBefore }, extraArgs
   - Note: OfferBurn does NOT take holdingCids — no Holdings are locked at offer time
   - Submit via interactive submission — signed with canton-registrar key
2. Result: BurnOffer contract created (signatory: provider, instrumentId.admin; observer: operator, burn.holder)

3. Holder exercises BurnOffer_Accept (controller: burn.holder)
   - actAs: acme_corp
   - Args include: holdingCids (holder provides their Holdings at accept time), extraArgs
   - Submit via interactive submission — signed with acme_corp's key
4. Result:
   - BurnOffer archived
   - Holdings merged/split/burned directly (no locking step — unlike RequestBurn)
   - ExecutedBurn contract created (audit trail)

## Off-Chain Settlement (both paths)

1. Orchestrator detects the archived Holding
2. Internal Ledger records position as REDEEMED
3. Core Banking credits the DDA and debits the Reserve Account
4. Client receives fiat

# Summary — Who Signs What

Verified from the actual Daml source in utility-registry-app-v0-0.7.0.dar:

| Choice | Controller (from Daml source) | Who signs in our setup |
|---|---|---|
| AllocationFactory_OfferMint | `registrar` | bank_registrar (canton-registrar key) |
| AllocationFactory_RequestMint | `mint.holder` | acme_corp (not our flow) |
| MintOffer_Accept | `mint.holder` | acme_corp (bank signs on their behalf) |
| MintOffer_Cancel | `mint.instrumentId.admin` | bank_registrar |
| MintRequest_Accept | `mint.instrumentId.admin` | bank_registrar |
| MintRequest_Cancel | `mint.holder` | acme_corp |
| AllocationFactory_OfferBurn | `registrar` | bank_registrar |
| AllocationFactory_RequestBurn | `burn.holder` | acme_corp |
| AllocationFactory_TransferInternal | `provider, registrar, sender` | bank + acme_corp |

In the bank-hosted model where we hold acme_corp's key in our Vault, the bank signs everything operationally. acme_corp's key is "needed" in the Daml sense (they're the controller), but the bank is the one actually calling Vault to sign.
