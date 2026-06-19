# Word integration — plan

Goal: let users cite their Refman library while writing in Microsoft Word, the
way Zotero/Mendeley do. This builds on the **citeproc engine** (`RefmanCore/
CitationIO/Citeproc.swift`), which is now in place and renders CSL styles via
citeproc-js in JavaScriptCore.

## Two scopes (ship in order)

### A. Quick Copy — DONE (foundation)
Right-click a selection → **Copy Citation** / **Copy Bibliography** in a chosen
style, paste into Word. Static text: no live reformatting, no managed
bibliography. Already shipped via the citeproc engine + the library context menu.
This covers most casual use and required no Word API at all.

### B. Live integration — the real "Word plugin" (not started)
"Insert Citation" inside Word, citations stored as live fields, bibliography
auto-regenerates, switching style reflows the whole document. This is the large,
ongoing-maintenance piece. Everything below describes **B**.

## Architecture

```
┌──────────────┐   localhost HTTP/WS    ┌───────────────────────────┐
│ Word add-in  │ <───────────────────>  │ Refman (macOS app)        │
│ (Office.js,  │   pick / format /      │  • citation picker UI     │
│  TypeScript) │   bibliography         │  • Citeproc engine        │
│              │                        │  • local server (NEW)     │
└──────────────┘                        └───────────────────────────┘
        │                                          
        │ Word document model                      
        ▼                                          
  citation fields (CSL-JSON payload per cite) + a bibliography field
```

Three new components:

1. **Local server in Refman** (does not exist yet — no HTTP/XPC/socket in the
   codebase today). A loopback-only HTTP+WebSocket server, started with the app.
   Endpoints, all driven by the existing engine:
   - `POST /cite` — open the citation picker (reuse the ⌘K command palette UI),
     return the chosen item(s) as CSL-JSON.
   - `POST /format` — given citation clusters + a style id, return formatted
     in-text strings. (citeproc `processCitationCluster` / `previewCitationCluster`.)
   - `POST /bibliography` — given the set of cited item ids + style, return the
     formatted bibliography. (citeproc `makeBibliography`.)
   - `GET /styles` — list bundled CSL styles.
   - Engine note: switch the per-call `JSContext` in `Citeproc.swift` to a
     **persistent, stateful engine per document** so `processCitationCluster`
     can do disambiguation/`ibid.`/numbering incrementally instead of
     re-rendering from scratch.

2. **Word add-in** (separate TypeScript/Office.js codebase, new toolchain):
   - Manifest + task pane with "Insert Citation", "Add/Refresh Bibliography",
     style picker, "Document Preferences".
   - Stores each citation as a Word **content control / field** whose tag holds
     the CSL-JSON citation cluster (the canonical data; the visible text is
     citeproc output). Mirrors how Zotero stores `ADDIN ZOTERO_ITEM` fields.
   - On any change (insert, edit, style switch): collect all citation fields →
     call `/format` and `/bibliography` → rewrite the visible text of every
     field and the bibliography field.
   - Office.js is cross-platform (Mac/Windows/web Word), which is the only sane
     path on modern Mac Word (legacy AppleScript/VBA plugins are dead-ends).

3. **Pairing/transport**: add-in discovers Refman on a fixed loopback port;
   simple shared-token handshake so only the local user's Word talks to Refman.

## The hard part

Not the wiring — the **document state management**: tracking citation fields,
handling user edits and deletions, re-rendering the entire document on style
change, undo, citation merging/disambiguation, and keeping field payloads and
visible text in sync. This is the single most bug-prone component in
Zotero/Mendeley and is maintained by teams over years. Budget accordingly.

## Rough effort

| Piece                                   | Size   |
|-----------------------------------------|--------|
| citeproc engine                         | DONE   |
| Quick Copy UI                           | DONE   |
| Local server + persistent engine        | M      |
| Office.js add-in (picker, fields, bib)  | L      |
| Document-state correctness + edge cases | L (ongoing) |

## Decision

Quick Copy (A) is shipped and unblocks real use today. Pursue **B** only if
live in-Word citing is a firm requirement — it's a separate TS codebase plus
sustained maintenance against the Office API, not a weekend feature.

## Open questions

- Bundle more CSL styles, or add a "import a .csl" path? (Today: APA, Nature,
  IEEE, AMA/Vancouver, Chicago.)
- Only en-US locale is bundled; non-English styles need their locale files.
- Google Docs later? Same server, a different (Apps Script) add-on front-end.
