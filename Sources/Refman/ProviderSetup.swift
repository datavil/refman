import AppKit
import RefmanCore
import SwiftUI

/// The assistant providers we offer guided setup for. Raw values match the
/// stored `llmProvider` setting.
enum LLMProvider: String, CaseIterable, Identifiable {
    case ollama, openai, claude
    var id: String { rawValue }

    var title: String {
        switch self {
        case .ollama: return "Ollama"
        case .openai: return "OpenAI (Codex)"
        case .claude: return "Claude"
        }
    }

    var binaryNames: [String] {
        switch self {
        case .ollama: return ["ollama"]
        case .openai: return ["codex"]
        case .claude: return ["claude"]
        }
    }

    enum Install { case script(String) }
    enum SignIn { case browserCLI(String), none }

    var install: Install {
        switch self {
        case .ollama:
            return .script(
                "curl -fsSL https://ollama.com/download/Ollama-darwin.zip -o /tmp/Ollama-darwin.zip"
                    + " && ditto -x -k /tmp/Ollama-darwin.zip /Applications"
                    + " && rm -f /tmp/Ollama-darwin.zip && open -a Ollama")
        case .openai: return .script("curl -fsSL https://chatgpt.com/codex/install.sh | sh")
        case .claude: return .script("curl -fsSL https://claude.ai/install.sh | bash")
        }
    }

    /// How sign-in is triggered. Both Codex and Claude expose a browser-callback
    /// `login` that completes on its own — no Terminal, no paste-back.
    var signIn: SignIn {
        switch self {
        case .ollama: return .none
        case .openai: return .browserCLI("codex login")
        case .claude: return .browserCLI("claude auth login --claudeai")
        }
    }

    /// Whether "signed in" can be detected: Codex writes `~/.codex/auth.json`
    /// and Claude stores a Keychain item; Ollama needs no account.
    var detectsSignIn: Bool { self == .openai || self == .claude }

    /// The shell install command, for script-based installs (nil for Ollama,
    /// which is installed from its download page).
    var installCommand: String? {
        if case .script(let command) = install { return command }
        return nil
    }
}

struct ProviderStatus: Equatable {
    var installed: Bool
    var signedIn: Bool?  // nil when not applicable / undetectable
}

/// Detects provider CLI install/sign-in state and drives install + sign-in,
/// using each CLI's own browser login and credential storage (no API keys).
@MainActor
final class ProviderSetupModel: ObservableObject {
    @Published private(set) var statuses: [String: ProviderStatus] = [:]
    @Published private(set) var busyProvider: LLMProvider?
    /// Whether the local Ollama server answered; nil while unknown/checking.
    @Published private(set) var ollamaRunning: Bool?
    @Published var message: String?
    /// The model currently being pulled, plus its progress (nil fraction while
    /// the size is still unknown, e.g. during "pulling manifest").
    @Published private(set) var pullingModel: String?
    @Published private(set) var pullFraction: Double?
    @Published private(set) var pullStatus: String?

    private var ollamaHost: String {
        ProcessInfo.processInfo.environment["REFMAN_OLLAMA_HOST"] ?? "http://127.0.0.1:11434"
    }

    func status(_ p: LLMProvider) -> ProviderStatus {
        statuses[p.id] ?? ProviderStatus(installed: false, signedIn: nil)
    }

    func refresh() {
        for p in LLMProvider.allCases {
            let installed = CLIEnvironment.resolve(p.binaryNames) != nil
            var signedIn: Bool? = nil
            if p == .openai {
                signedIn = FileManager.default.fileExists(
                    atPath: CLIEnvironment.expandingTilde("~/.codex/auth.json"))
            } else if p == .claude {
                // Claude Code stores its login in the macOS Keychain.
                signedIn = CLIEnvironment.keychainGenericPasswordExists(
                    service: "Claude Code-credentials")
            }
            statuses[p.id] = ProviderStatus(installed: installed, signedIn: signedIn)
        }
        checkOllama()
    }

    /// Pings the local Ollama server so "Running" reflects reality, not just
    /// whether the binary is installed.
    private func checkOllama() {
        Task {
            guard let url = URL(string: "\(ollamaHost)/api/tags") else {
                ollamaRunning = false
                return
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 2
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                ollamaRunning = (response as? HTTPURLResponse)?.statusCode == 200
            } catch {
                ollamaRunning = false
            }
        }
    }

    /// Launches the Ollama app (or the bare server) and re-checks.
    func startOllama() {
        busyProvider = .ollama
        message = "Starting Ollama…"
        Task {
            await runLoginShell("open -a Ollama 2>/dev/null || (nohup ollama serve >/dev/null 2>&1 &)")
            try? await Task.sleep(for: .seconds(2))
            busyProvider = nil
            message = nil
            refresh()
        }
    }

    /// Pulls an Ollama model via the streaming pull API so progress can be shown,
    /// then runs `onDone` so the caller can reload the model list and select it.
    func pullOllamaModel(_ name: String, then onDone: @MainActor @escaping () -> Void = {}) {
        guard pullingModel == nil else { return }
        pullingModel = name
        pullFraction = nil
        pullStatus = "Starting…"
        Task {
            let ok = await streamPull(name)
            pullingModel = nil
            pullFraction = nil
            pullStatus = nil
            refresh()
            if ok { onDone() }
        }
    }

    /// Streams `POST /api/pull`, updating `pullFraction`/`pullStatus` from each
    /// newline-delimited JSON event. Returns whether the pull completed cleanly.
    private func streamPull(_ name: String) async -> Bool {
        guard let url = URL(string: "\(ollamaHost)/api/pull") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Send both keys so old and new Ollama servers both accept it.
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["model": name, "name": name])
        struct Event: Decodable {
            let status: String?
            let total: Int64?
            let completed: Int64?
            let error: String?
        }
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                pullStatus = "Couldn't reach Ollama — start it above, then try again."
                return false
            }
            for try await line in bytes.lines {
                guard let data = line.data(using: .utf8),
                    let event = try? JSONDecoder().decode(Event.self, from: data)
                else { continue }
                if let error = event.error {
                    pullStatus = error
                    return false
                }
                if let total = event.total, total > 0, let completed = event.completed {
                    pullFraction = Double(completed) / Double(total)
                } else {
                    pullFraction = nil
                }
                if let status = event.status { pullStatus = status }
            }
            return true
        } catch {
            pullStatus = "Download failed: \(error.localizedDescription)"
            return false
        }
    }

    func install(_ p: LLMProvider) {
        if case .script(let command) = p.install {
            run(p, message: "Installing \(p.title)…", shell: command)
        }
    }

    func signIn(_ p: LLMProvider) {
        switch p.signIn {
        case .browserCLI(let command):
            run(p, message: "Complete sign-in in your browser…", shell: command)
        case .none:
            break
        }
    }

    func signOut(_ p: LLMProvider) {
        switch p {
        case .openai: run(p, message: "Signing out…", shell: "codex logout")
        case .claude: run(p, message: "Signing out…", shell: "claude auth logout")
        case .ollama: break
        }
    }

    // MARK: - Subprocess

    private func run(_ p: LLMProvider, message: String, shell command: String) {
        busyProvider = p
        self.message = message
        Task {
            await runLoginShell(command)
            busyProvider = nil
            self.message = nil
            refresh()
        }
    }

    /// Runs `command` in a login shell so the user's real PATH (homebrew, nvm…)
    /// applies, and waits for it to finish.
    private func runLoginShell(_ command: String) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-lc", command]
                process.standardInput = FileHandle.nullDevice
                try? process.run()
                process.waitUntilExit()
                cont.resume()
            }
        }
    }

}

/// Status + one-click Install / Sign In controls for one provider, shown inside
/// its Settings section.
struct ProviderSetupView: View {
    let provider: LLMProvider
    @ObservedObject var setup: ProviderSetupModel

    var body: some View {
        let status = setup.status(provider)
        let busy = setup.busyProvider == provider
        let ollamaDown = provider == .ollama && status.installed && setup.ollamaRunning == false
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                badge("Installed", ok: status.installed)
                if provider.detectsSignIn {
                    badge("Signed in", ok: status.signedIn ?? false)
                }
                if provider == .ollama, status.installed {
                    badge("Running", ok: setup.ollamaRunning ?? false)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }
            HStack {
                if !status.installed {
                    Button("Install") {
                        setup.install(provider)
                    }
                } else if provider == .ollama {
                    if ollamaDown {
                        Button("Start Ollama") { setup.startOllama() }
                    }
                } else {
                    switch provider.signIn {
                    case .none:
                        EmptyView()
                    case .browserCLI:
                        Button(status.signedIn == true ? "Re-sign In" : "Sign In") {
                            setup.signIn(provider)
                        }
                        if status.signedIn == true {
                            Button("Sign Out") { setup.signOut(provider) }
                        }
                    }
                }
                Button("Refresh") { setup.refresh() }
                Spacer()
            }
            .buttonStyle(.bordered)
            .disabled(busy)
            if let command = provider.installCommand {
                VStack(alignment: .leading, spacing: 4) {
                    if status.installed {
                        Text("Install command (to reinstall or update):")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("The Install button above does this for you. To do it yourself:")
                            .font(.caption).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("1. Open the Terminal app (press ⌘-Space, type “Terminal”, hit Return).")
                            Text("2. Copy the command below and paste it into the Terminal window.")
                            Text("3. Press Return and wait for it to finish.")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Text(command)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color.secondary.opacity(0.12)))
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                            setup.message = "Copied install command."
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy install command")
                    }
                }
            }
            if ollamaDown {
                Label(
                    "Ollama isn't running — the assistant can't reach it. "
                        + "Start it, then Refresh.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
            if let message = setup.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func badge(_ label: String, ok: Bool) -> some View {
        Label(label, systemImage: ok ? "checkmark.circle.fill" : "circle")
            .font(.caption)
            .foregroundStyle(ok ? Color.green : Color.secondary)
    }
}
