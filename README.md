# RefMan

A native macOS reference manager (Mendeley-style), built with Swift.

- **Library**: SQLite (GRDB) with FTS5 full-text search; PDFs stored
  content-addressed by sha256 under `~/Library/Application Support/RefMan/Storage`.
- **Import**: drag-and-drop or ⌘I; extracts text via PDFKit, scans for DOI/arXiv
  IDs, resolves metadata against CrossRef and the arXiv API. `.bib`/`.ris` import too.
- **Reader**: PDFKit viewer with highlight/underline/note annotations, written
  into the PDF itself *and* mirrored to SQLite (searchable, listable, syncable).
- **Export**: BibTeX, RIS, CSL-JSON.
- **Assistant**: local-LLM chat over the [Agent Client Protocol](https://agentclientprotocol.com).
  The app spawns `refman-agent` (an ACP↔Ollama bridge) and exposes library
  tools (`search_library`, `get_document_text`, `get_annotations`, …) that the
  model calls to ground its answers in your actual papers.

## Run

```sh
swift run RefMan
```

Requirements: macOS 14+, Xcode toolchain. For the assistant: [Ollama](https://ollama.com)
running locally with at least one tool-capable model pulled (e.g. `ollama pull qwen3:14b`).
Override with `REFMAN_OLLAMA_MODEL` / `REFMAN_OLLAMA_HOST`.

## Test

```sh
swift test                      # 26 unit/integration tests
python3 scripts/acp_smoke.py    # end-to-end ACP agent test (needs Ollama)
```

## Layout

```
Sources/RefManCore/    # UI-free engine: database, storage, metadata, citation IO, ACP
Sources/RefMan/        # SwiftUI app (library browser, PDF reader, assistant panel)
Sources/RefManAgent/   # refman-agent: ACP agent bridging to Ollama
Tests/RefManCoreTests/
```

See `todo.md` for status and roadmap (citeproc bibliographies and CloudKit
sync across devices are the next phases).
