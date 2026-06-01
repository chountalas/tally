# Privacy

Tally is intended to be local-first personal finance software.

## Data Stored By The App

Tally can store:

- Imported transaction rows, including dates, amounts, merchants, categories, account labels, and memos.
- Subscription records, renewal dates, prices, statuses, notes, aliases, and detection evidence.
- Import templates and merchant classification corrections.
- Local AI provider preferences and optional Gemma model setup state.

Data is stored with SwiftData. When a valid iCloud container is configured, SwiftData can sync through the user's Apple/iCloud account. Tally does not run its own backend for this data.

## Network Use

Tally has no analytics or advertising network calls.

The app can make a network request when the user chooses to download the optional Gemma model. That request downloads `gemma-4-E4B-it-Q4_K_M.gguf` from Hugging Face and does not include transaction data. The model download is subject to Hugging Face and Google model terms separate from Tally's source license.

Future bank-sync integrations must keep credentials out of the client and must be optional. Plaid or similar services cannot be required for core local-file workflows.

## Local Apple Integrations

Tally may expose selected subscription data to local Apple platform features:

- User notifications can show renewal reminders.
- Calendar access can create renewal reminder events.
- Spotlight indexing can index subscription names, expected renewal amounts, and dates for local search.
- App Intents and Shortcuts can surface subscription and renewal entities on the device.
- CloudKit sync uses the user's iCloud account when configured.

These features should remain permissioned, local-platform integrations. Do not add external telemetry around them.

## AI Providers

Tally supports local Gemma inference on macOS when the model and bundled llama runtime are available. Prompts can include merchant and subscription facts, so inference logs must not expose prompt text, model output, merchant names, account names, memos, or local file paths as public OSLog values.

Tally can also use Apple's Foundation Models APIs where available. Tally does not send data to a Tally-operated server through that provider; provider behavior is governed by Apple's platform implementation and user settings.

## Logging Rules

Public logs may include aggregate counts, durations, selected provider kinds, and health states.

The following must be private or omitted from logs:

- Merchant names
- Transaction memos
- Account names
- Imported file names and file paths
- Local model paths
- Model prompts and outputs
- Raw errors that may include user-controlled paths or data snippets

## Test Data

Committed test fixtures must be synthetic. Do not commit real bank exports, personal account names, screenshots, or imported data.
