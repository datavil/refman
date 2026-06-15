# Refman — Enhancement Plan

Candidate utilities and features beyond the current `todo.md` roadmap (which
already covers citeproc bibliographies, CloudKit sync, watched-folder import,
GROBID extraction, word-processor citation, and notarization). This document is
a menu of *additional* ideas, grouped by area, with effort estimates and notes
on what existing infrastructure each builds on.

Effort key: **S** = small (hours), **M** = medium (1–2 days), **L** = large
(multi-day / new subsystem).

---

## 1. Metadata & Import

- **PMID / PubMed import path** *(S — already in progress)* — `PubMedClient` and
  `IdentifierScanner` are mid-flight. Finish wiring it into `ImportPipeline` so a
  scanned PMID resolves like a DOI, and add a "paste identifier" box (DOI / arXiv
  / PMID / ISBN) that creates a reference with no PDF.
- **Open-access PDF auto-fetch** *(S — `PDFFetcher` exists)* — finish the
  Unpaywall/arXiv fetcher: on import of a metadata-only reference, offer to pull
  the OA PDF. Surface a per-document "find PDF" action in the inspector.
- **ISBN / book metadata** *(M)* — resolve ISBNs via OpenLibrary or Google Books;
  fills the `book`/`chapter` document types that currently have no resolver.
- **Bibliographic enrichment / repair** *(M)* — a "complete metadata" action that
  re-queries CrossRef for references missing year/venue/authors; batch-runnable
  over a selection. Useful after `.bib` imports with sparse fields.
- **Duplicate detection & merge** *(M)* — `document(doi:)` and `document(fileHash:)`
  already exist; add a DOI/title-similarity scan that flags dupes and a merge UI
  that keeps one record, unions tags/collections/annotations, and re-points files.
- **Reference deduping on import** *(S)* — before inserting, warn if DOI/hash
  already present (currently silent re-add is possible).
- **Crossref/PubMed "cited-by" & references list** *(L)* — pull the reference list
  and citation count for a paper; store as related-document links (needs a new
  `documentLink` table). Foundation for a citation graph.
- **Batch re-extract text** *(S)* — re-run `PDFTextExtractor` over documents with
  empty `fullText` (e.g. PDFs that were image-only before OCR was added).
- **OCR for scanned PDFs** *(M)* — Vision framework (`VNRecognizeTextRequest`) to
  extract text from image-only PDFs so they become searchable and assistant-readable.

## 2. Reader & Annotations

- **Annotation export / report** *(S)* — export all highlights+notes for a document
  (or collection) to Markdown — a "reading notes" sheet. Pairs naturally with the
  existing color-label feature (purple = "key finding").
- **Annotation color picker + ink annotations** *(S–M)* — already in `todo.md`
  "Later"; lift to a real task. Free-draw ink for figure markup.
- **Cross-document annotation search view** *(M)* — annotations are already mirrored
  to SQLite; add a global "all my highlights" browser, filterable by color/tag/note.
- **Sticky reading position** *(S)* — remember last page + zoom per document, restore
  on reopen. Add `lastPageIndex` to `document` or a small `readingState` table.
- **Reading status / workflow** *(S)* — unread / reading / read flag + a "to-read"
  smart list. One column on `document`.
- **Figure / table extraction** *(L)* — detect and crop figures (Vision + PDF region
  parsing) into a per-document gallery; export figures as PNG.
- **Split view / tabbed reader** *(M)* — open multiple PDFs in tabs or side-by-side
  for comparison.
- **Citation-context jump** *(M)* — click an in-text "[12]" and jump to the
  reference entry; requires reference-list parsing (ties to §1 cited-by work).

## 3. Search & Organization

- **Saved searches / smart collections** *(M)* — persist an FTS query + filters
  (year range, tag, author, type, reading status) as a dynamic collection. Schema
  supports collections already; add a `query` column or `smartCollection` table.
- **Faceted filter bar** *(S–M)* — filter the document table by year, author, type,
  tag without typing FTS syntax.
- **Boolean / field-scoped search** *(S)* — expose FTS5 column filters
  (`author:smith year:2023`) in the search field; currently it is a flat match.
- **Author pages** *(M)* — click an author → all their papers in the library; dedupe
  author name variants ("J Smith" vs "John Smith").
- **Tag hierarchy / colored tags** *(S)* — nested or colored tags; `tag` table is
  currently flat name-only.
- **Bulk edit** *(S)* — multi-select rows → set type, add tag, add to collection,
  set reading status in one action.

## 4. Citation & Output (beyond planned citeproc)

- **Quick-copy citation** *(S)* — copy a formatted citation or BibTeX key for the
  selected reference to the clipboard (⌘-shortcut). Cheap win on top of existing
  `BibTeX`/`citationKey` code.
- **Drag-to-cite** *(M)* — drag a reference out of Refman as a formatted citation /
  BibTeX entry into any text field. Precursor to the planned word-processor plugin.
- **Per-collection bibliography export** *(S)* — export a whole collection to
  `.bib` / `.ris` / formatted `.md` / `.docx`. Export plumbing exists per-document.
- **EndNote XML / Zotero RDF import** *(M)* — broaden importer beyond BibTeX/RIS so
  users can migrate existing libraries.
- **Citation key collision handling** *(S)* — ensure generated keys are unique within
  the library (append a/b/c); verify current behavior.

## 5. Assistant (ACP / local-LLM) — extend `LibraryTools`

- **More library tools** *(S each)* — the tool dispatcher in `LibraryTools.handle`
  is trivially extensible. Add: `list_collections`, `add_to_collection`,
  `create_annotation`, `set_reading_status`, `find_similar`, `get_references`.
- **Multi-document Q&A / synthesis** *(M)* — "summarize what these 5 papers say about
  X." Assistant already has `search_library` + `get_document_text`; add a tool that
  fetches text from a set of IDs with token budgeting.
- **Literature-review / summary generation** *(M)* — generate a structured summary or
  comparison table across a collection; save the output as a document note.
- **Semantic search (embeddings)** *(L)* — embed abstracts + chunked full text (via
  Ollama embeddings), store vectors in SQLite, add a `semantic_search` tool and a
  "find similar papers" action. Biggest assistant upgrade; complements FTS5.
- **Auto-tagging / auto-classification** *(M)* — suggest tags or a collection for a
  new import based on title/abstract via the local model.
- **Chat over a collection, not just current doc** *(S)* — let the assistant scope to
  a selected collection rather than only `currentDocumentId`.
- **Per-document note field** *(S)* — a freeform Markdown note per reference (separate
  from PDF annotations) that the assistant can read and write. New `note` column/table.

## 6. Researcher Workflow (molecular-biology slant)

- **Identifier-rich inspector** *(S)* — show/link PMID, PMCID, DOI, accession numbers;
  one-click to PubMed / journal / NCBI.
- **Supplementary-file attachments** *(M)* — attach supplementary PDFs, datasets,
  spreadsheets to a reference (not just the primary PDF). Needs a `documentFile`
  table; storage is already content-addressed and ready for it.
- **Preprint ↔ published linking** *(M)* — detect when a library arXiv/bioRxiv
  preprint has a published DOI version and link them.
- **bioRxiv / medRxiv resolver** *(S)* — add a client (mirrors `ArXivClient`) for the
  bio/med preprint servers your field actually uses.
- **Grant / project tagging** *(S)* — tag references by grant or project for reporting;
  a special tag namespace plus an export of "papers cited under grant X."
- **Reading queue / weekly digest** *(M)* — a "what's new / unread this week" view;
  `recentDocuments(since:)` already exists.

## 7. Library Management & Safety

- **Backup / restore** *(S)* — one-click zip of the SQLite DB + `Storage/`; scheduled
  local backups. Important before CloudKit sync lands.
- **Database integrity / orphan check** *(S)* — find documents whose `fileHash` has no
  file on disk, and stored files no documents reference; offer cleanup.
- **Storage stats** *(S)* — library size, document count, PDFs missing/present, in a
  Settings pane.
- **Trash / soft delete** *(S)* — `delete(documentId:)` is permanent; add a recoverable
  trash with empty-trash. Also smooths CloudKit conflict handling later.
- **Import progress + error log** *(S)* — surface per-file import results (resolved /
  no-DOI / failed) instead of silent outcomes; a retry queue.
- **Quick Look / Spotlight integration** *(M)* — expose PDFs to macOS Quick Look and
  index metadata for system Spotlight search.

## 8. UI / UX Polish

- **Menu bar + keyboard shortcuts audit** *(S)* — ⌘F search, ⌘N new reference, space =
  Quick Look, ⌘-copy-citation, etc.
- **Column customization & sorting** *(S)* — choose/reorder/sort table columns
  (author, year, journal, added, reading status).
- **Dark-mode / density pass** *(S)* — verify the table and reader at compact density.
- **Empty / first-run states** *(S)* — onboarding for an empty library (import, paste
  DOI, connect Ollama).
- **Global command palette** *(M)* — ⌘K to jump to any document, collection, or action.

---

## Suggested first wave (high value / low cost, builds on in-flight work)

1. Finish **PubMed + OA PDF fetch** import paths (§1) — already half-built.
2. **Annotation export to Markdown** (§2) — fast, high utility for note-taking.
3. **Quick-copy citation / BibTeX key** (§4) — trivial on existing citation code.
4. **Reading status + smart "to-read" list** (§2/§3) — one column, big workflow gain.
5. **Backup/restore + orphan check** (§7) — safety net before CloudKit sync.
6. **Per-document Markdown note + extra assistant tools** (§5) — small, compounding.

## Bigger bets (plan separately)

- **Semantic search via embeddings** (§5) — the standout assistant upgrade.
- **Citation graph / cited-by** (§1/§2) — new data model, enables discovery features.
- **Supplementary-file attachments** (§6) — researcher-grade library, needs schema.
- **OCR + figure extraction** (§1/§2) — unlocks image-only and figure-heavy PDFs.
