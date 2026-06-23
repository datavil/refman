# iPad Port Plan

## Verdict

RefMan is currently **macOS-only** ([Package.swift](Package.swift) declares
`platforms: [.macOS(.v14)]`, built as a SwiftPM *executable* — not an app
bundle). An iPad port is feasible but blocked on one architectural decision
(the assistant) and a moderate amount of AppKit→UIKit glue.

The good news: **`RefmanCore` has zero AppKit imports** and the entire UI is
SwiftUI. The data layer (GRDB/SQLite), citation IO, and metadata clients
(URLSession) are already portable.

---

## The one hard blocker: the assistant / local-LLM

On macOS the assistant launches LLM CLIs as **child processes**:

- [ACPClient.swift](Sources/RefmanCore/ACP/ACPClient.swift) — `Process()`,
  `Pipe()`, `executableURL`
- [CLIEnvironment.swift](Sources/RefmanCore/CLI/CLIEnvironment.swift) — spawns
  `/bin/zsh`, `/usr/bin/security` (Keychain probe)
- [ProviderSetup.swift](Sources/Refman/ProviderSetup.swift) — `osascript`,
  Terminal, `NSWorkspace`

**iOS/iPadOS does not allow spawning subprocesses.** None of the
Claude Code / Codex / Ollama-as-subprocess flow can run on iPad as-is. This is
a core feature, so it needs one of:

| Option | What it means | Effort |
|--------|---------------|--------|
| **A. Remote agent** | iPad talks (HTTP/CloudKit) to `refman-agent` running on the user's Mac, which spawns the CLIs. Keeps the ACP/subprocess design, moves it off-device. | Medium–High |
| **B. Direct HTTP providers** | iPad calls provider HTTP endpoints (Ollama server URL, Anthropic/OpenAI API) instead of CLIs. No subprocess. New auth path (API keys, not CLI Keychain login). | Medium |
| **C. Ship iPad without assistant** | Reader + library only on iPad; assistant stays Mac-only. | Low |

**Decision needed before coding.** The rest of this plan assumes the UI port
proceeds regardless; the assistant target is gated on this choice.

---

## Inventory of platform-specific code

### Fully portable (no changes)
- All of `RefmanCore` except `ACP/` and `CLI/` (see blocker above)
- `Database/`, `CitationIO/`, `Metadata/`, `Import/`, most of `Storage/`
- SwiftUI views with no `NS*`: [AssistantPanel.swift](Sources/Refman/AssistantPanel.swift)
  (only `NSLock`), [InspectorView.swift](Sources/Refman/InspectorView.swift)
  (only `NSPasteboard`)

### AppKit → UIKit glue needed
| File | AppKit usage | iOS replacement |
|------|--------------|-----------------|
| [ReaderView.swift](Sources/Refman/ReaderView.swift) | `NSViewRepresentable` wrapping `PDFView`, `NSColor`, `NSMenu`, `NSEvent`, `NSPasteboard` | `UIViewRepresentable` + `PDFView` (PDFKit exists on iOS); `UIColor`; context menu; `UIPasteboard` |
| [LibraryView.swift](Sources/Refman/LibraryView.swift) | custom `NSSplitViewController`, `NSSearchToolbarItem`, `NSWindow`, `NSImage`, `NSItemProvider` | `NavigationSplitView`, `.searchable`, drag-drop via `Transferable` |
| [AppModel.swift](Sources/Refman/AppModel.swift) | `NSOpenPanel`/`NSSavePanel`, `NSPasteboard`, `NSWorkspace`, `ditto` Process | `.fileImporter`/`.fileExporter`, `UIPasteboard`, `UIApplication.open`, Foundation zip |
| [SettingsView.swift](Sources/Refman/SettingsView.swift) | `NSOpenPanel`, `NSApp` | `.fileImporter`; settings as a screen, not a `Settings` scene |
| [ProviderSetup.swift](Sources/Refman/ProviderSetup.swift) | `NSPasteboard`, `NSWorkspace`, subprocess | depends on assistant decision |
| [RefmanApp.swift](Sources/Refman/RefmanApp.swift) | `NSApplication`, `Settings{}`, `CommandMenu` | iOS `App`/`WindowGroup`; menus → toolbar/buttons; multi-window via scenes |

### Exclude from iOS target
- [AppIcon.swift](Sources/Refman/AppIcon.swift) — runtime icon drawing with
  `NSBezierPath`/`NSBitmapImageRep`; ship a static asset catalog instead.
- [Updater.swift](Sources/Refman/Updater.swift) — self-update via `ditto`/
  `NSWorkspace`; not allowed on iOS (App Store handles updates).

### Storage / file access
- [LibraryLocation.swift](Sources/RefmanCore/Storage/LibraryLocation.swift)
  uses `homeDirectoryForCurrentUser` + the macOS iCloud Drive path
  (`Library/Mobile Documents/...`). On iOS:
  - Default root → app's own container (`Application Support` works).
  - User-chosen folders → `UIDocumentPickerViewController` + **security-scoped
    bookmarks** (no free filesystem access).
  - Sync → CloudKit (already the stated direction) rather than an iCloud Drive
    folder path.

---

## Build system

SPM `.executableTarget` does **not** produce an iOS `.app`. Need a real app
target with `Info.plist`, asset catalog, and code signing:

1. Add an Xcode project (or `xcodegen`/Tuist) wrapping the SPM packages, with a
   `Refman-iOS` app target.
2. Add `.iOS(.v17)` to `Package.swift` `platforms` for `RefmanCore` (and the UI
   sources if they stay in SPM).
3. Wrap macOS-only code in `#if os(macOS)` / `#if canImport(AppKit)` so one
   source tree builds both, or split a thin platform layer
   (`PlatformPasteboard`, `PlatformImage`, file-picker, color helpers).

---

## Phased plan

### Phase 0 — Decide the assistant strategy
→ verify: pick option A / B / C above. Blocks the assistant target only.

### Phase 1 — Make `RefmanCore` build for iOS
1. Add `.iOS(.v17)` platform; move `ACP/` + `CLI/` behind `#if os(macOS)`.
2. Refactor `LibraryLocation` file access behind a protocol with mac + iOS impls.
→ verify: `swift build` for iOS Simulator succeeds; `RefmanCoreTests` pass on
both platforms.

### Phase 2 — Platform abstraction layer
3. Introduce `PlatformColor`, `PlatformImage`, `PlatformPasteboard`, and a
   file import/export wrapper; replace direct `NS*`/`UI*` calls in views.
→ verify: shared views compile under `canImport(UIKit)`.

### Phase 3 — Reader on iPad
4. Add `UIViewRepresentable` PDF wrapper mirroring the macOS one; port
   annotations, selection, search, zoom toolbar to touch.
→ verify: open a PDF, highlight, search, copy-with-citation on iPad sim.

### Phase 4 — Library + navigation on iPad
5. Replace the custom `NSSplitViewController` with `NavigationSplitView`;
   `.searchable`; drag-drop import via `Transferable`/document picker.
→ verify: browse, search, import a PDF, see metadata fetch on iPad sim.

### Phase 5 — App shell, settings, sync
6. iOS `App` scene; settings as a screen; CloudKit sync wired to the iOS
   container.
→ verify: library syncs Mac ↔ iPad; settings persist.

### Phase 6 — Assistant (per Phase 0)
7. Implement chosen option; gate UI when unavailable.
→ verify: assistant responds on iPad (or is cleanly hidden under option C).

---

## Effort estimate

- Phases 1–5 (reader + library + sync, no assistant): **moderate** — the
  SwiftUI + clean core makes this the bulk of a usable iPad app.
- Phase 6 assistant: **the real cost**, driven entirely by the Phase 0 choice.
- Biggest non-code task: standing up the Xcode app target + signing (already a
  known friction point for this project).
