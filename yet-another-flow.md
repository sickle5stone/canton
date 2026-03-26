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

# Mint Flow (Issuer-Initiated via RequestMint + Transfer)

Minting is a two-step request/accept workflow using the AllocationFactory, followed by a transfer to the end client. There are two paths available on the AllocationFactory:

- **AllocationFactory_RequestMint** — controller is `mint.holder`. This is our flow — the Issuer sets itself as the holder and requests the mint.
- **AllocationFactory_OfferMint** — controller is `registrar`. This is for when the registrar directly offers a mint to a holder.

We use the RequestMint path because we have a separate Issuer party that initiates mints, then transfers the Holding to the end client (acme_corp).

## Step 1 — Off-Chain Settlement

1. Client initiates a "Move to Chain" request in the Bank Portal
2. Core Banking debits the client's DDA and credits the Reserve Account
3. Internal Ledger records the position as PENDING_MINT
4. Event Bus emits a MintRequested domain event
5. Token Orchestrator consumes the event

## Step 2 — Request Mint (on-chain)

The Issuer requests a mint with itself as the holder. acme_corp is not involved in this step.

1. Orchestrator calls the Operator Backend API to retrieve the choice context for the mint request
   - Returns: AllocationFactory CID, InstrumentConfiguration CID, Issuer Credential CID(s), and disclosed contracts

2. Orchestrator constructs an ExerciseCommand on the AllocationFactory with choice AllocationFactory_RequestMint
   - actAs: bank_issuer (controller is mint.holder, and the issuer IS the holder in this step)
   - mint.holder set to: bank_issuer (the issuer mints to itself first)
   - Args include: expectedAdmin, mint { instrumentId, amount, holder: bank_issuer, reference, requestedAt, executeBefore }, extraArgs with the choice context

3. Submit via interactive submission:
   - PrepareSubmission → get preparedTransactionHash
   - Vault sign with canton-issuer key
   - ExecuteSubmissionAndWait

4. Result: MintRequest contract created on-chain
   - signatories: provider, mint.holder (= bank_issuer)
   - observer: operator, instrumentId.admin (= bank_registrar)

## Step 3 — Accept Mint (on-chain)

The Registrar accepts the mint request. Controller is `mint.instrumentId.admin` (= bank_registrar).

1. Orchestrator calls the Backend API to retrieve the accept choice context for the MintRequest
   - Returns: InstrumentConfiguration CID, Issuer Credential CID(s), AppRewardConfiguration CID, and disclosed contracts

2. Construct ExerciseCommand on MintRequest with choice MintRequest_Accept
   - actAs: bank_registrar (instrumentId.admin is the controller)
   - Args include the accept choice context (extraArgs)

3. Submit via interactive submission:
   - PrepareSubmission → get preparedTransactionHash
   - Vault sign with canton-registrar key
   - ExecuteSubmissionAndWait

4. Result:
   - MintRequest contract archived (consumed)
   - Holding contract created for bank_issuer (owner = bank_issuer, amount = minted amount)
   - ExecutedMint contract created (audit trail)

## Step 4 — Transfer to Client via TransferPreapproval (on-chain)

The Issuer now holds the minted tokens and transfers them to acme_corp. We use the TransferPreapproval path to skip the two-step TransferOffer/Accept — acme_corp preapproved transfers during onboarding, so the transfer completes in a single transaction.

**Prerequisite (one-time during onboarding):** acme_corp creates a TransferPreapproval contract:
- TransferPreapproval { operator, receiver: acme_corp, instrumentAdmin: bank_registrar, instrumentAllowances: [{ id: "DEPO" }] }
- signatory: acme_corp (receiver), observer: operator
- Submit via interactive submission — signed with acme_corp's key
- This serves as standing consent for future transfers of DEPO to acme_corp

**Transfer step:**

1. Orchestrator exercises the transfer via the TransferPreapproval contract (it implements the TransferFactory interface)
   - This calls TransferRule_DirectTransfer under the hood — one-shot, no receiver accept needed
   - actAs: bank_issuer (sender) + provider + registrar
   - Args: sender = bank_issuer, receiver = acme_corp, instrumentId, amount, inputHoldingCids
   - Submit via interactive submission — signed with canton-issuer key + canton-registrar key

2. Result:
   - Issuer's Holding archived
   - New Holding created for acme_corp (owner = acme_corp)
   - Remainder Holding created for issuer if partial transfer

## Step 5 — Off-Chain Finalization

1. Orchestrator receives the Holding CreatedEvent for acme_corp
2. Internal Ledger updates position from PENDING_MINT to MINTED
3. Bank Portal notified — client sees on-chain balance

# Transfer Flow

We don't hold client keys. So transfers involving external parties (e.g. acme_corp → another party) are client-initiated and client-signed. We only facilitate bank-internal transfers (e.g. issuer → acme_corp via TransferPreapproval, which is already covered in the mint flow above).

## Client-to-Client Transfer (two-step, client-initiated)

This is when acme_corp wants to transfer their Holding to another party. We don't control this — the client drives it.

1. acme_corp exercises the transfer choice on the AllocationFactory (AllocationFactory_TransferInternal)
   - controller: provider, registrar, transfer.sender — all three must authorize
   - actAs: acme_corp (sender) + provider + registrar
   - Submit via interactive submission — signed with acme_corp's key + canton-registrar key
   - Note: acme_corp needs to coordinate with us for the registrar signature, or we provide a co-signing service

2. Result: TransferOffer contract created
   - Original Holding locked (locker = registrar)
   - Remainder Holding created for acme_corp if partial

3. Receiver accepts via TransferInstruction_Accept (controller: transfer.receiver)
   - Submitted by the receiver — signed with receiver's key
   - Exercises TransferRule_TwoStepTransfer under the hood
   - Result: locked Holding archived, new Holding created for receiver

## Bank-Internal Transfer (one-step, via TransferPreapproval)

This is the transfer from issuer → acme_corp during the mint flow. Already covered in Mint Flow Step 4 above. Uses TransferPreapproval + TransferRule_DirectTransfer — no receiver accept needed.

# Redeem (Burn) Flow

Redemption burns on-chain tokens and triggers off-chain settlement back to fiat. The flow mirrors the mint pattern — instead of clients burning directly, clients transfer their Holding to a bank-owned BurnParty, which triggers off-chain fiat settlement, followed by the bank burning the tokens on-chain.

Clients do **not** receive `isIssuerOf` credentials. They only need `isHolderOf` — enough to transfer tokens. The burn is entirely a bank-internal operation.

## Step 1 — Client Initiates Redemption (off-chain)

1. Client initiates a "Move to Fiat" request in the Bank Portal
2. Internal Ledger records the position as PENDING_REDEEM
3. Event Bus emits a RedeemRequested domain event
4. Token Orchestrator consumes the event and instructs the client to transfer

## Step 2 — Transfer to BurnParty (on-chain)

The client transfers their Holding to the bank-owned BurnParty via TransferPreapproval (same mechanism as the mint flow's Step 4, but in reverse).

**Prerequisite (one-time during onboarding):** BurnParty creates a TransferPreapproval contract:
- TransferPreapproval { operator, receiver: bank_burner, instrumentAdmin: bank_registrar, instrumentAllowances: [{ id: "DEPO" }] }
- signatory: bank_burner (receiver), observer: operator
- Submit via interactive submission — signed with canton-burner key
- This serves as standing consent for any client to transfer DEPO tokens to the BurnParty

**Transfer step:**

1. Orchestrator exercises the transfer via the TransferPreapproval contract
   - actAs: acme_corp (sender) + provider + registrar
   - Args: sender = acme_corp, receiver = bank_burner, instrumentId, amount, inputHoldingCids
   - Submit via interactive submission — signed with acme_corp's key + canton-registrar key

2. Result:
   - acme_corp's Holding archived
   - New Holding created for bank_burner (owner = bank_burner)
   - Remainder Holding created for acme_corp if partial transfer

## Step 3 — Off-Chain Settlement

1. Orchestrator detects the Holding CreatedEvent for bank_burner
2. Internal Ledger updates position from PENDING_REDEEM to SETTLING
3. Core Banking credits the client's DDA and debits the Reserve Account
4. Client receives fiat
5. Internal Ledger updates position from SETTLING to SETTLED

## Step 4 — Burn (on-chain)

The bank burns the tokens now held by BurnParty. This is a bank-internal operation — no client keys needed.

1. BurnParty exercises AllocationFactory_RequestBurn on the AllocationFactory
   - actAs: bank_burner (burn.holder is controller — BurnParty is the holder)
   - Args include: expectedAdmin, burn { instrumentId, amount, holder: bank_burner, reference, requestedAt, executeBefore }, holdingCids, extraArgs
   - Submit via interactive submission — signed with canton-burner key
2. Result: BurnRequest contract created + Holding is locked (locked with registrar as locker)

3. Registrar exercises BurnRequest_Accept on the BurnRequest (controller: burn.instrumentId.admin)
   - actAs: bank_registrar
   - Submit via interactive submission — signed with canton-registrar key
4. Result:
   - BurnRequest archived
   - Locked Holding archived (tokens burned)
   - ExecutedBurn contract created (audit trail)

## Step 5 — Off-Chain Finalization

1. Orchestrator detects the ExecutedBurn event
2. Internal Ledger updates position from SETTLED to REDEEMED
3. Bank Portal notified — client sees updated on-chain balance

# Summary — Who Signs What

Verified from the actual Daml source in utility-registry-app-v0-0.7.0.dar:

| Choice | Controller (from Daml source) | Who signs in our flow |
|---|---|---|
| AllocationFactory_RequestMint | `mint.holder` | bank_issuer (issuer is the holder in this step) |
| MintRequest_Accept | `mint.instrumentId.admin` | bank_registrar |
| TransferPreapproval (TransferFactory_Transfer) | `sender` (via interface) | bank_issuer + bank_registrar |
| TransferPreapproval_Withdraw | `actor` (receiver or operator) | acme_corp or operator |
| TransferPreapproval (burn transfer) | `sender` (via interface) | acme_corp + bank_registrar |
| AllocationFactory_RequestBurn | `burn.holder` | bank_burner (BurnParty holds the tokens) |
| BurnRequest_Accept | `burn.instrumentId.admin` | bank_registrar |
| AllocationFactory_TransferInternal | `provider, registrar, sender` | bank + sender |

In this model, acme_corp's key is only needed for:
- CredentialOffer_AcceptFree (one-time onboarding)
- TransferPreapproval creation (one-time onboarding)
- Transfer to BurnParty (when acme_corp redeems — standard transfer, no burn-specific permissions)

Both mint and burn are symmetric bank-internal operations:
- **Mint:** bank mints to itself (Issuer) → transfers out to client
- **Burn:** client transfers in to bank (BurnParty) → bank burns from itself

The client never needs `isIssuerOf` credentials — only `isHolderOf` for transfers.
