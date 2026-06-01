# Plaid Integration Plan for Tally

## Summary
Add Plaid-powered bank sync as a new transaction source for the existing SwiftUI + SwiftData + CloudKit app. Use Plaid `Transactions` as the raw source of truth, use Plaid `Recurring Transactions` as an enrichment signal, keep full transaction history in local SwiftData/iCloud, and keep only minimal server-side state in Convex.

Authentication will use native Sign in with Apple through Auth0, with Convex trusting Auth0-issued tokens. Plaid secrets, access tokens, item IDs, cursors, and webhook/sync state live in Convex only. The app stays privacy-forward and does not turn the backend into a permanent transaction warehouse.

## Key Changes
### Backend and auth
- Add a new `convex/` backend with:
  - Auth configured to accept Auth0 OIDC tokens.
  - Tables for `users`, `plaidItems`, `plaidAccounts`, and `plaidSyncState`.
  - Encrypted storage for Plaid `access_token`.
  - HTTP webhook endpoint for Plaid item and transaction events.
  - Actions/mutations for `createLinkToken`, `exchangePublicToken`, `listConnections`, `syncConnection`, `refreshRecurringInsights`, and `disconnectConnection`.
- Add Auth0 for iOS auth, configured so users sign in with Apple and the app passes Auth0 ID tokens to Convex.
- Keep webhook behavior minimal: webhooks mark an item as needing sync and record status; they do not become the long-term storage path for transactions.

### iOS app flow
- Add authenticated backend client setup to the app bootstrap and app model.
- Add Plaid LinkKit to the iOS app and implement:
  - Connect institution flow
  - Relink/update mode for expired Items
  - Disconnect flow
- Put the main bank-sync entry point in the Imports tab and add connection management in Settings.
- Update empty states so the app says “Connect a bank or import a file” instead of only referencing CSV/XLS imports.
- Trigger sync:
  - Immediately after a successful Plaid link
  - On manual pull-to-refresh
  - On app foreground if the last sync is older than 6 hours or Convex marks the item dirty from a webhook

### Local data model and ingestion
- Keep existing manual import models intact and add first-class bank-sync models rather than overloading `ImportRecord`.
- Add local SwiftData models for:
  - `BankConnection` with backend item/account metadata and status
  - `BankSyncRun` for visible sync history and errors
- Extend `NormalizedTransaction` with Plaid/source fields:
  - `source` (`manualImport` or `plaid`)
  - `externalTransactionID`
  - `externalAccountID`
  - `plaidItemID`
  - `pending`
  - optional raw merchant/category metadata from Plaid
- Replace “always insert” behavior for bank-synced transactions with idempotent upsert/delete logic keyed by `externalTransactionID`.
- Handle Plaid delta semantics correctly:
  - Add new transactions
  - Update changed transactions
  - Remove transactions deleted by Plaid
  - Collapse pending-to-posted transitions without duplicating rows
- After each successful Plaid sync, run the existing subscription rebuild flow so [SubscriptionDetectionService.swift](Tally/Services/Detection/SubscriptionDetectionService.swift) continues to own subscription derivation.
- Use Plaid recurring results only as enrichment:
  - raise confidence
  - improve merchant normalization/category hints
  - pre-seed cadence expectations
  - never overwrite manual user edits blindly

### UI and behavior details
- Imports tab:
  - Add “Connect bank” CTA
  - Show connected institutions, last sync, needs-attention state, and latest sync errors
  - Keep file import as a secondary/manual source
- Settings:
  - Add account section for Sign in with Apple session state
  - Add bank connection management, relink, disconnect, and privacy copy
- Disconnect behavior:
  - Remove the Plaid Item from Convex
  - Mark the local connection disconnected
  - Keep already-synced local transactions/subscriptions by default
  - Offer a separate destructive option to delete synced bank data locally
- Initial backfill:
  - Fetch 24 months of transactions on first link so annual subscriptions can be detected
- Multi-device behavior:
  - One signed-in device can sync Plaid data into SwiftData
  - CloudKit propagates the local transaction/subscription records across the user’s Apple devices

## Public Interfaces and Types
- New backend functions:
  - `plaid.createLinkToken()`
  - `plaid.exchangePublicToken(publicToken, linkMetadata)`
  - `plaid.listConnections()`
  - `plaid.syncConnection(connectionId)`
  - `plaid.refreshRecurringInsights(connectionId)`
  - `plaid.disconnectConnection(connectionId)`
- New local models:
  - `BankConnection`
  - `BankSyncRun`
- `NormalizedTransaction` gains stable external/source identifiers and Plaid metadata fields required for dedupe and update handling.
- `AppModel` grows authenticated sync responsibilities, but CSV/XLS import remains supported.

## Test Plan
- iOS unit tests for Plaid transaction upsert logic:
  - same transaction synced twice does not duplicate
  - pending transaction replaced by posted transaction correctly
  - removed transaction deletes or tombstones correctly
- iOS integration tests for subscription rebuild:
  - first Plaid sync creates subscriptions from recurring charges
  - recurring enrichment increases confidence without overriding manual edits
  - disconnect leaves local historical data intact unless explicit delete is chosen
- Backend tests for Convex actions:
  - link token creation requires auth
  - public token exchange stores encrypted token and account metadata
  - sync cursor advances correctly across paginated `/transactions/sync`
  - webhook marks item dirty and does not create duplicate jobs
- Manual end-to-end validation:
  - sign in with Apple
  - connect institution with Plaid Link
  - initial 24-month sync lands in local store
  - dashboard/subscriptions update automatically
  - relink flow works after invalid credentials
  - second device receives synced results through CloudKit

## Assumptions and Defaults
- Backend target is Convex.
- Identity path is Auth0-backed Sign in with Apple because Convex’s current Swift client docs are built around external OIDC/Auth0 support, and this avoids inventing a custom auth bridge for v1.
- Server-side storage remains minimal: Plaid credentials, cursors, account/item metadata, and sync/webhook status only.
- Full normalized transaction history remains local-first in SwiftData and syncs across Apple devices through CloudKit.
- Plaid `Transactions` is the canonical ingestion path; `Recurring Transactions` is additive signal only.
- Manual CSV/XLS import remains available as a fallback and for users who do not want bank linking.
