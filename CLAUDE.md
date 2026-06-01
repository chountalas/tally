# Repository Instructions

Tally is a native SwiftUI personal-finance app for tracking subscriptions. Keep the app local-first, privacy-forward, and contributor-friendly.

## Public Repo Rules

- Do not commit real financial data, bank exports, screenshots with personal spending, credentials, provisioning profiles, local machine paths, or private agent/session notes.
- Keep app secrets out of the client. Optional integrations such as Plaid must use user-provided or server-side credentials; never ship client secrets in this repo.
- Treat merchant names, memos, account names, file paths, model prompts, and model outputs as private user data. Aggregate counts and timings can be public logs; dynamic user data should be redacted or logged as private.
- Use `Config/Tally.xcconfig` for public defaults and create an ignored `Config/Local.xcconfig` for local signing, bundle ID, and iCloud container overrides.
- Regenerate the Xcode project with `xcodegen generate` after changing `project.yml`.

## Build And Test

```sh
xcodegen generate
xcodebuild test -project Tally.xcodeproj -scheme Tally -destination 'platform=macOS' -derivedDataPath .build/derived
```

The app targets current Apple platform SDKs and uses SwiftData, SwiftUI, CloudKit-compatible persistence, CoreXLSX, libxls, and a macOS-only bundled `llama.framework` for optional local Gemma inference.

## Design Context - Tally

Tally is the current design gate. Do not regress toward the prior Stone & Ember or Obsidian Ledger directions.

Locked direction: soft, light and dark polished, coral accent, cozy density, lively but tasteful motion.

Native translation choices:

- SF Rounded substitutes for rounded display/numeral typography.
- SF Pro substitutes for body typography.
- Native macOS title bars replace faux browser chrome.
- Per-service monogram tiles are acceptable fallbacks for brand logos.
- The "Saved on this Mac" live dot is static.

### Visual System

- Window background: warm parchment in light mode, warm noir in dark mode.
- Surfaces: warm, rounded cards; avoid pure black/white and cold grey SaaS styling.
- Accent: coral for primary actions, active nav, progress, soon badges, and important highlights.
- Semantic colors stay distinct: warning amber, yearly blue, active green, destructive red.
- Radius: cards 24pt, smaller controls around 16pt, monogram tiles around 13pt.
- Layout: 232pt sidebar, centered content with a 920pt max width, cozy spacing.

### Interaction And Motion

- Use `Theme.Animation.whenAllowed(_:reduceMotion:)` for motion gates.
- Keep quick feedback at or below 0.25s and standard reveals at or below 0.40s.
- Use critically damped interactive springs only; avoid decorative bounce.
- Do not add perpetual `repeatForever` motion.
- Use numeric transitions for changing numbers where appropriate.

### Component Conventions

- Sidebar: coral active pill, outline SF Symbols, static "Saved on this Mac" footer, settings behind the gear.
- Home: greeting, hero amount, yearly equivalent, stat tiles, renewal cards, and spend chart.
- Subscriptions: monogram tile, name, inline badges, muted meta, right-aligned rounded amount.
- Badges: soon coral, ended/idle neutral, yearly blue, price-up amber.
- Details: hero identity row, headline price card, warning callout for price increases, fact grid, charge list, action pills.
- Calendar: month grid with coral today state, monogram events, agenda below.
- Add/update: compact sheet, clear choices, primary coral treatment for the main import path.
