# Refman implementation plan

This is the ordered delivery plan for Refman. It is deliberately split into
small checkpoints so each change can be tested, approved, and committed on its
own.

## Working agreement

For every step:

1. Implement only that step and its tests.
2. Run `swift test`, `swift build`, and any step-specific checks.
3. Give the user a short, non-technical manual test checklist.
4. Wait for the user to confirm that the behavior is correct.
5. Commit the approved step, mark it complete here, and begin the next step.

No step is committed before user confirmation. Unrelated cleanup is excluded.
Database migrations must be backward-safe and tested. New third-party
dependencies require approval first.

Status: `[ ]` pending, `[~]` in progress, `[x]` approved and committed,
`[!]` blocked by an external requirement.

## Ordered steps

### 1. [x] Make search respect the selected library section

**Deliverable:** Searching inside a collection, tag, recent list, reading list,
uncategorized list, duplicates, or Trash stays inside that section. Add a short
typing debounce so every keystroke does not immediately query the database.

**Automated acceptance:** Repository tests cover every search scope; all tests
and the full build pass.

**Manual acceptance:** Put two papers in different collections, search from one
collection, and confirm the other collection's paper does not appear. Repeat in
Trash.

### 2. [x] Adopt the project's modern Swift baseline

**Deliverable:** Move targets to Swift 6.2 strict concurrency and migrate shared
UI state from `ObservableObject`/`@Published` to Observation's `@Observable`
where practical. Replace legacy concurrency calls touched by the migration.

**Automated acceptance:** Clean build under Swift 6.2 with strict concurrency;
all tests pass.

**Manual acceptance:** Launch Refman, import/select/open a paper, open Settings,
and use the assistant panel without regressions.

### 3. [ ] Add application and assistant contract tests

**Deliverable:** Testable app-state operations for search, import outcomes,
trash/restore, and assistant tool requests. Split only the seams required for
testing; do not redesign the UI.

**Automated acceptance:** Tests demonstrate failure paths as well as success
paths and run without a live model or network connection.

**Manual acceptance:** Smoke-test import, trash/restore, and opening the reader.

### 4. [ ] Make duplicate imports explicit

**Deliverable:** When the same PDF or identifier already exists, offer clear
choices: use the existing reference, attach/replace where appropriate, or keep
a separate copy. Never create a duplicate silently.

**Automated acceptance:** Tests cover live, metadata-only, and trashed matches.

**Manual acceptance:** Import the same PDF twice and verify each choice and its
message.

### 5. [ ] Implement true duplicate merging

**Deliverable:** The duplicate screen can merge records while preserving the
best metadata and unioning collections, tags, annotations, and attachments.
The user previews the result before confirming.

**Automated acceptance:** Transactional merge tests prove that no linked data
is lost and rollback works on failure.

**Manual acceptance:** Merge two prepared duplicates and inspect metadata,
collections, tags, annotations, PDF access, and Trash.

### 6. [ ] Make startup, backup, and restore failure-safe

**Deliverable:** Replace the startup crash with a recovery window. Create
database-consistent backups, validate restore archives first, and atomically
replace the library while preserving a rollback copy.

**Automated acceptance:** Tests cover invalid/corrupt archives, failed restore,
and successful round-trip backup/restore in temporary libraries.

**Manual acceptance:** Back up a small library, add a temporary paper, restore,
relaunch, and confirm the temporary paper is gone and the original papers open.

### 7. [ ] Verify updates before installation

**Deliverable:** Refuse any update that lacks a trusted signature/checksum,
validate the expected app bundle, and remove the unsafe unsigned replacement
path. Add release automation that publishes the verification metadata.

**Automated acceptance:** Valid, modified, missing-signature, and malformed
update fixtures are tested.

**Manual acceptance:** Check for updates and verify that “up to date” and a
verified test update behave normally.

### 8. [ ] Add a real reading workflow and restore reader position

**Deliverable:** Replace the single “Currently Reading” flag with To Read,
Reading, and Read states. Persist last page, zoom/display mode, and last-opened
time per document.

**Automated acceptance:** State-transition and reading-position persistence
tests pass.

**Manual acceptance:** Set each state, reopen Refman, and confirm a PDF returns
to the previous reading position.

### 9. [ ] Export annotations as useful research notes

**Deliverable:** Export one paper, a selection, or a collection to Markdown,
grouped by document and annotation color label, with page numbers and notes.

**Automated acceptance:** Snapshot tests cover empty notes, special characters,
multiple papers, and deterministic ordering.

**Manual acceptance:** Export an annotated paper and confirm the Markdown is
readable in a normal text editor.

### 10. [ ] Add a global annotations workspace

**Deliverable:** A library-level view of all highlights and notes, searchable
and filterable by paper, collection, tag, color/label, and whether a note exists.
Selecting an item opens the PDF at its page.

**Automated acceptance:** Repository filtering and navigation-target tests pass.

**Manual acceptance:** Find an annotation from another paper and jump to it.

### 11. [ ] Add faceted search and smart collections

**Deliverable:** Filters for year, author, type, tag, PDF presence, and reading
state. Any query/filter combination can be saved as a dynamic smart collection.

**Automated acceptance:** Query-composition, persistence, rename, and delete
tests pass.

**Manual acceptance:** Save a multi-filter search, restart Refman, and confirm it
updates automatically when a matching paper is added.

### 12. [ ] Scale library loading for large collections

**Deliverable:** Remove per-row author/tag queries, move heavy database work off
the main actor, and page or incrementally fetch large result sets without
breaking sorting and selection.

**Automated acceptance:** A generated 10,000-reference library meets an agreed
load/search benchmark and existing behavior tests pass.

**Manual acceptance:** Scroll, sort, search, and switch collections in the large
fixture without visible stalls.

### 13. [ ] Support multiple files per reference

**Deliverable:** Attach a primary paper plus supplements, datasets, images, or
other files. Files remain content-addressed and survive export, merge, backup,
restore, and later sync.

**Automated acceptance:** Migration, CRUD, deduplication, merge, and bundle
round-trip tests pass.

**Manual acceptance:** Attach several file types, open/reveal them, export the
reference, and verify every attachment is present.

### 14. [ ] Improve metadata coverage and scanned-PDF support

**Deliverable:** Detect PMID during PDF import, support bioRxiv/medRxiv and ISBN,
offer batch metadata repair, and add opt-in Vision OCR for image-only PDFs.

**Automated acceptance:** Resolver fixtures, identifier priority, offline
fallback, OCR cancellation, and re-indexing tests pass.

**Manual acceptance:** Import representative PMID, preprint, book, and scanned
PDF fixtures and inspect/search the results.

### 15. [ ] Deepen citation output without committing to a Word add-in

**Deliverable:** Import custom CSL styles/locales, ensure collision-free citation
keys, add drag-to-cite, and export formatted collection bibliographies.

**Automated acceptance:** CSL import validation, locale, collision, and drag
payload tests pass.

**Manual acceptance:** Import a style, drag a citation into a text editor, and
export a collection bibliography.

### 16. [ ] Make assistant answers traceable and privacy-clear

**Deliverable:** Page-aware source links from answers back to PDFs, selectable
paper/collection scope, explicit local-versus-remote data disclosure, and stored
generation provenance (provider, model, date, source revision).

**Automated acceptance:** Tool contracts, source mapping, stale-result marking,
and privacy-mode tests run without contacting a provider.

**Manual acceptance:** Ask a factual question, follow its source to the PDF, and
confirm the provider disclosure matches the selected backend.

### 17. [ ] Add semantic retrieval and research discovery

**Deliverable:** Opt-in chunk embeddings, “find similar,” selected-paper
synthesis, and reference/cited-by relationships. Answers must retain document
and page provenance.

**Automated acceptance:** Deterministic retrieval fixtures measure recall and
prove incremental re-indexing and deletion behavior.

**Manual acceptance:** Find a conceptually related paper that shares no obvious
keywords and verify the cited passages.

### 18. [ ] Replace file-level iCloud database sync with CloudKit

**Deliverable:** Create a proper Xcode app target and sync documents,
collections, tags, annotations, reading state, and attachments as records/assets
with explicit conflict handling. Remove the unsafe “one Mac at a time” mode.

**External requirement:** Apple Developer team, signing identity, CloudKit
container, and test devices. This step pauses for those credentials if they are
not available.

**Automated acceptance:** Sync-engine tests cover first sync, concurrent edits,
deletion, offline changes, conflicts, and account changes.

**Manual acceptance:** Make offline and conflicting edits on two devices and
confirm convergence without lost data.

### 19. [ ] Ship a signed and notarized release

**Deliverable:** Signed/notarized app and installer, hardened runtime, verified
updates, release notes, and a clean first-launch experience without Terminal or
quarantine instructions.

**External requirement:** Apple Developer signing and notarization credentials.

**Automated acceptance:** CI builds the release artifact and verifies its code
signature, notarization ticket, resources, updater metadata, and smoke launch.

**Manual acceptance:** Install on a clean Mac account, launch without security
workarounds, update, and reopen the existing library.

## Explicitly deferred

- A live Microsoft Word add-in: revisit only after citation drag/drop and CSL
  import are validated by real use.
- iPad support: revisit after the shared core is Swift 6.2-clean and CloudKit
  synchronization is reliable.
- Ink/figure extraction: useful, but lower priority than searchable annotations,
  OCR, attachments, and safe synchronization.
