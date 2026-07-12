# Refman Chrome extension — implementation plan

## Goal

Build a small Manifest V3 Chrome extension that saves the paper or PDF in the
active tab to the local Refman desktop library, reports the result clearly, and
can open the saved reference in Refman.

This plan assumes the first release is a **capture extension**, not a browser
version of the full Refman library. The initial success criteria are:

- From a supported article page or a direct PDF tab, one click adds the item to
  Refman.
- DOI, arXiv, and PubMed pages reuse Refman's existing metadata resolvers and
  duplicate detection.
- Direct PDFs are downloaded and passed through Refman's existing PDF import
  pipeline so text extraction and metadata resolution behave like desktop
  imports.
- The popup always shows one unambiguous state: ready, saving, saved, already in
  library, Refman unavailable, or failed.
- The bridge is local-only and does not expose the user's library to websites.

## Product scope

### Version 1

- Toolbar popup with page title, detected source type, and primary **Save to
  Refman** action.
- Detect, in priority order:
  1. A direct PDF response or embedded PDF tab.
  2. DOI from `citation_doi`, `dc.identifier`, JSON-LD, DOI links, or page text.
  3. arXiv identifier from the URL or citation metadata.
  4. PubMed identifier from the URL or citation metadata.
  5. Generic scholarly metadata from Highwire/Dublin Core/JSON-LD as a fallback.
- Save into the library, preserving the source URL.
- Optional collection picker populated from Refman.
- Duplicate response that identifies the existing reference instead of silently
  adding another copy.
- **Open in Refman** after a successful or duplicate result.
- Options/help screen for connection state and troubleshooting.
- Light and dark browser color-scheme support.

### Explicitly deferred

- Full library search or editing inside Chrome.
- Citation insertion into web editors or Google Docs.
- Annotation capture, snapshots, and highlighted-text notes.
- Firefox/Safari packaging.
- Cloud accounts or remote sync; the extension talks only to the local app.

## Architecture

```text
Active tab
   │ metadata extraction / PDF detection
   ▼
Chrome extension (Manifest V3, TypeScript)
   │ authenticated JSON over 127.0.0.1
   ▼
Refman local bridge (Swift, loopback only)
   │
   ├── ImportPipeline.importIdentifier(...)
   ├── ImportPipeline.importPDF(...)
   └── LibraryRepository (collections, duplicates, lookup)
```

Use a loopback HTTP bridge rather than Chrome Native Messaging for version 1.
It is also reusable by the planned Word integration, keeps the extension thin,
and avoids installing a Chrome-specific native-host manifest. Bind only to
`127.0.0.1`, never all interfaces.

The bridge uses a random per-install bearer token stored in the macOS Keychain.
Refman presents a one-time pairing code; the extension exchanges it for the
token and stores the token in `chrome.storage.local`. Requests validate both the
token and the extension origin. CORS is restricted to the final extension ID.
Request bodies and PDF downloads have conservative size/time limits.

## Repository layout

Keep the new browser code isolated from the Swift package:

```text
extension/
  manifest.json
  package.json
  tsconfig.json
  vite.config.ts
  src/
    background.ts          # bridge calls and lifecycle
    content.ts             # page metadata extraction
    popup/                 # popup state and UI
    options/               # pairing/help UI
    shared/                # request/response types and detection helpers
  public/icons/
  tests/
Sources/RefmanCore/BrowserBridge/
  BrowserBridgeModels.swift
  BrowserBridgeServer.swift
Sources/Refman/
  BrowserExtensionSettingsView.swift
Tests/RefmanCoreTests/BrowserBridgeTests.swift
```

Use TypeScript with browser-native DOM/CSS and the smallest practical build
tooling. Do not introduce a UI framework for the popup.

## Bridge contract

All responses use a small versioned JSON envelope. Proposed version 1 routes:

| Route | Purpose |
|---|---|
| `GET /v1/status` | App/version compatibility and pairing state |
| `POST /v1/pair` | Exchange a short-lived pairing code for a token |
| `GET /v1/collections` | Populate the optional destination picker |
| `POST /v1/import/identifier` | Import DOI, arXiv ID, or PMID |
| `POST /v1/import/metadata` | Add normalized fallback page metadata |
| `POST /v1/import/pdf` | Import a bounded PDF upload with source URL |
| `POST /v1/documents/:uuid/open` | Activate Refman and select/open the item |

Import responses are one of `added`, `duplicate`, or `failed`, with document
UUID, title, and a safe user-facing message. The extension never reads the
SQLite database or library files directly.

Before implementation, confirm whether the Word integration should share this
same server abstraction immediately. If yes, name it generically (for example
`LocalIntegrationServer`) rather than after Chrome.

## Implementation phases

### 1. Contract and shared import entry points

- Define Codable request/response models and protocol versioning in RefmanCore.
- Add the minimum repository/import methods needed for normalized browser
  metadata, source URL preservation, collection assignment, and UUID lookup.
- Keep existing DOI/arXiv/PubMed and PDF imports on `ImportPipeline`; do not
  duplicate metadata resolution in the extension.
- Add unit tests for normalized metadata, duplicates, collection assignment,
  and invalid input.

**Verify:** Swift tests cover every response status without starting a server.

### 2. Secure local bridge

- Implement the loopback listener and route only the endpoints above.
- Add Keychain-backed token generation, expiring pairing codes, origin checks,
  body limits, request timeouts, and structured error responses.
- Start/stop the bridge with the app and expose connection/pairing controls in
  Settings.
- Add an app action that selects a document by UUID for **Open in Refman**.

**Verify:** integration tests prove unauthenticated, wrong-origin, oversized,
and malformed requests are rejected; authenticated imports succeed. Confirm the
port is unreachable from a non-loopback interface.

### 3. Extension shell and detection

- Create the Manifest V3 project, popup, service worker, options page, icons,
  and typed bridge client.
- Request only `activeTab`, `scripting`, `storage`, and loopback host access.
  Avoid broad website host permissions; `activeTab` grants extraction after the
  user invokes the extension.
- Implement pure metadata parsers with fixtures for Highwire, Dublin Core,
  JSON-LD, DOI, arXiv, PubMed, and unsupported pages.
- Handle Chrome's built-in PDF viewer separately because normal content scripts
  cannot reliably inspect it; use the active tab URL and fetch/upload from the
  extension context when permitted.

**Verify:** automated parser tests plus manual checks on representative Crossref
publisher pages, arXiv, PubMed, and direct PDFs.

### 4. Popup workflow and visual polish

- Implement a compact state-driven popup with no navigation for the main save
  flow.
- Add collection choice, pairing/retry affordances, success/duplicate states,
  and **Open in Refman**.
- Match the chosen visual direction, reuse the Refman mark, support keyboard
  navigation, visible focus, reduced motion, 200% zoom, and dark mode.
- Provide concise recovery instructions when Refman is closed or unpaired.

**Verify:** keyboard-only and screen-reader labels; popup never resizes
dramatically between states; contrast meets WCAG AA.

### 5. Packaging and release

- Add deterministic `npm test`, `npm run build`, and a script that creates the
  Chrome Web Store ZIP without development files.
- Document local unpacked installation, pairing, permissions, privacy, and
  troubleshooting.
- Pin the production extension ID before locking the server's allowed origin.
- Add extension-version compatibility checks so old clients receive a useful
  upgrade message.

**Verify:** clean checkout passes Swift tests and extension tests/build; install
the ZIP in a fresh Chrome profile and complete the end-to-end capture matrix.

## End-to-end acceptance matrix

| Scenario | Expected result |
|---|---|
| DOI publisher page | Resolved metadata saved; source URL retained |
| arXiv abstract page | Metadata and available PDF saved |
| PubMed record | PubMed metadata saved |
| Direct PDF | PDF stored, indexed, and metadata resolution attempted |
| Same DOI or PDF twice | Existing item reported as a duplicate |
| Generic scholarly page | Extracted metadata shown for confirmation and saved |
| Unsupported page | Clear unsupported message; no junk record created |
| Refman closed/unpaired | Actionable connection state; no indefinite spinner |
| Tampered/missing token | Request rejected without leaking library data |

## Decisions needed before coding

1. Visual style for the popup (see options below).
2. Should saving happen immediately on click, or should metadata always be
   previewed and confirmed first? Recommended: one-click for confident DOI/
   arXiv/PubMed/PDF matches, confirmation for generic metadata.
3. Is collection selection required for version 1, or can every item initially
   land in **All References**? Recommended: optional collection picker.
4. Should version 1 be Chrome-only, or intentionally package for all Chromium
   browsers? Recommended: Chrome first while keeping standard WebExtension APIs.
5. May the extension add a context-menu action, **Save page to Refman**?

## Style directions

- **Native Refman:** quiet off-white surface, near-black typography, hairline
  borders, restrained system accent, and the existing node logo. Feels like a
  small companion to the macOS app.
- **Editorial:** paper-like cream background, stronger title hierarchy, serif
  accents for reference metadata, and subtle citation-card details. Feels more
  academic and distinctive.
- **Chrome-native minimal:** system fonts, neutral white/gray surfaces, compact
  controls, and Chrome-like spacing. Familiar and functional, with less Refman
  personality.

The selected direction should define popup width/density, corner treatment,
accent behavior, success/error colors, dark-mode palette, and whether cover/
journal imagery appears. No visual implementation starts until this choice is
confirmed.
