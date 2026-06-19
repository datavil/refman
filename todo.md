# Refman — build todo

Native macOS reference manager (Mendeley-class). Swift + SwiftUI, GRDB, PDFKit,
CloudKit sync, ACP for local-LLM assistant. SPM-based (`swift build` / `swift run Refman`).

## Phase 0 — Skeleton ✅
- [x] SPM workspace: `RefmanCore` (library), `Refman` (SwiftUI executable), `refman-agent`, tests
- [x] GRDB dependency, schema v1 migrations: document, author, documentAuthor,
      collection, collectionDocument, tag, documentTag, annotation, documentFTS (FTS5)
- [x] `LibraryStore` (content-addressed PDF storage by sha256)
- [x] Tests green (`swift test` — 26 tests)

## Phase 1 — Usable library ✅
- [x] Import pipeline: file → hash → store → PDF text extraction → DOI/arXiv regex scan
- [x] CrossRef client (`api.crossref.org/works/{doi}`, JATS-stripped abstracts)
- [x] arXiv API client (Atom feed parse)
- [x] 3-pane UI: sidebar (collections/tags) | document table | inspector (metadata edit)
- [x] Drag-and-drop + Open-panel import (⌘I)
- [x] Collections & tags CRUD

## Phase 2 — Reader ✅
- [x] PDFKit reader window (double-click row or "Open PDF")
- [x] Highlight / underline / note annotations written into the PDF as `PDFAnnotation`
      (tagged with uuid via /NM key; PDF saved in place)
- [x] Annotation mirror rows in SQLite (page, quads, color, selected text, note, dates)
- [x] Annotation sidebar (list, jump-to, inline note edit, delete)

## Phase 3 — In/Out (citeproc pending)
- [x] FTS5 full-text search over title/abstract/authors/PDF text; search field UI
- [x] BibTeX parser + exporter (roundtrip-tested), citation key generation
- [x] RIS parser + exporter (roundtrip-tested)
- [x] CSL-JSON export
- [x] citeproc-js via JavaScriptCore + bundled CSL styles (formatted bibliographies);
      Copy Citation / Copy Bibliography in the library context menu (APA, Nature,
      IEEE, AMA/Vancouver, Chicago)

## Phase 4 — Sync (CloudKit) — NOT STARTED
- [ ] Requires an Xcode app target + Apple Developer signing + CloudKit entitlements;
      SPM executables can't carry entitlements. Plan: wrap Refman in an .xcodeproj
      app shell, add CKSyncEngine adapter behind a protocol in RefmanCore.
- [ ] documents/annotations/collections/tags as CKRecords; PDFs as CKAsset
- [ ] Conflict policy: LWW per field; annotations append-mostly
- Schema is sync-ready: every syncable row carries a `uuid`; files are content-addressed.

## Phase 5 — Assistant (ACP + local LLM) ✅
- [x] `JSONRPCPeer`: bidirectional JSON-RPC 2.0 over ndjson/stdio (shared by both sides)
- [x] `ACPClient` (app side): spawn agent, initialize → session/new → session/prompt,
      streamed agent_message_chunk, auto-grant permission requests
- [x] Client-side tools via `refman/toolCall`: get_current_document, get_document_text,
      search_library, get_annotations, add_tag
- [x] `refman-agent`: ACP↔Ollama bridge with streaming + tool loop;
      model = $REFMAN_OLLAMA_MODEL or largest installed (verified vs qwen3:14b)
- [x] Chat sidebar in reader ("Assistant" toolbar toggle)
- [x] End-to-end smoke test: `python3 scripts/acp_smoke.py`

## Later
- [ ] Watched-folder auto-import
- [ ] GROBID-based metadata extraction for PDFs without DOI
- [ ] Word-processor citation integration (live in-Word plugin) — see `word-integration.plan.md`
- [ ] Proper .app bundle (icon, signing, notarization)
- [ ] Annotation colors picker; ink annotations
