<p align="center">
  <img src="assets/logo.svg" width="128" alt="Refman logo">
</p>

<h1 align="center">Refman</h1>

<p align="center">A native macOS reference manager (Mendeley-style), built with Swift.</p>

> 🤖 **Vibecoded with Claude.** This project is written end-to-end by
> [Claude](https://claude.com) (Anthropic) via Claude Code — every line of code,
> from the database layer to the SwiftUI app to this README, produced by AI from
> natural-language prompts. No line was hand-written. Enjoy it for what it is.

- **Library**: SQLite (GRDB) with FTS5 full-text search; PDFs stored
  content-addressed by sha256 under `~/Library/Application Support/Refman/Storage`.
- **Import**: drag-and-drop or ⌘I; extracts text via PDFKit, scans for DOI/arXiv
  IDs, resolves metadata against CrossRef and the arXiv API. `.bib`/`.ris` import too.
- **Reader**: PDFKit viewer with highlight/underline/note annotations, written
  into the PDF itself *and* mirrored to SQLite (searchable, listable, syncable).
- **Export**: BibTeX, RIS, CSL-JSON.
- **Assistant**: local-LLM chat over the [Agent Client Protocol](https://agentclientprotocol.com).
  The app spawns `refman-agent` (an ACP↔Ollama bridge) and exposes library
  tools (`search_library`, `get_document_text`, `get_annotations`, …) that the
  model calls to ground its answers in your actual papers.

## Install

```sh
curl -LsSf https://refman.datavil.org/install.sh | sh
```

This installs the latest release in `/Applications`, recursively clears its
quarantine attribute, and opens Refman. Until releases can be signed with an
Apple Developer ID, the in-app updater clears quarantine again after every
update.

## Run

```sh
swift run Refman
```

Requirements: macOS 14+, Swift 6.2+ toolchain. For the assistant: [Ollama](https://ollama.com)
running locally with at least one tool-capable model pulled (e.g. `ollama pull qwen3:14b`).
Override with `REFMAN_OLLAMA_MODEL` / `REFMAN_OLLAMA_HOST`.

## Build a macOS app

```sh
scripts/build_app.sh
open dist/Refman.app
```

The bundle includes both the SwiftUI app and the bundled `refman-agent` used by
the Assistant. The script ad-hoc signs the app for local use; set
`SKIP_CODESIGN=1` to skip signing. Installed releases update themselves through
**Refman → Check for Updates…**.

## Test

```sh
swift test                      # 86 unit/integration tests
python3 scripts/acp_smoke.py    # end-to-end ACP agent test (needs Ollama)
```

## Chrome extension

The extension in `extension/` saves DOI, arXiv, PubMed, generic scholarly
metadata, and direct PDFs into the running Refman app. Build and load it with:

```sh
cd extension
npm install
npm test
npm run package
```

Open `chrome://extensions`, enable Developer mode, choose **Load unpacked**, and
select `extension/refman-chrome-extension`. Pair it from **Refman → Settings →
Chrome Extension**.

## Layout

```
Sources/RefmanCore/    # UI-free engine: database, storage, metadata, citation IO, ACP
Sources/Refman/        # SwiftUI app (library browser, PDF reader, assistant panel)
Sources/RefmanAgent/   # refman-agent: ACP agent bridging to Ollama
Tests/RefmanCoreTests/
```

See `todo.md` for status and roadmap (citeproc bibliographies and CloudKit
sync across devices are the next phases).
