import Foundation

/// Helpers for locating command-line tools (Codex, Claude, Ollama, …) from a
/// GUI-spawned process, which inherits only a minimal `PATH`. Mirrors the
/// resolution the bundled agent already does, in one reusable place.
public enum CLIEnvironment {
    /// Common install locations for CLIs not on the GUI `PATH`.
    public static let commonBinDirs = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "\(NSHomeDirectory())/.local/bin",
        "\(NSHomeDirectory())/.npm-global/bin",
    ]

    /// Absolute path to the first of `names` found in `commonBinDirs` (plus any
    /// `extraDirs`), falling back to a login-shell `command -v` so user-specific
    /// PATH entries (nvm, asdf, …) still resolve. Returns nil if not found.
    public static func resolve(_ names: [String], extraDirs: [String] = []) -> String? {
        let fm = FileManager.default
        for dir in extraDirs + commonBinDirs {
            for name in names {
                let path = "\(dir)/\(name)"
                if fm.isExecutableFile(atPath: path) { return path }
            }
        }
        for name in names {
            if let path = loginShellLookup(name) { return path }
        }
        return nil
    }

    /// `zsh -lc "command -v <name>"` — resolves tools on the user's real PATH.
    public static func loginShellLookup(_ name: String) -> String? {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/zsh")
        probe.arguments = ["-lc", "command -v \(name)"]
        let pipe = Pipe()
        probe.standardInput = FileHandle.nullDevice
        probe.standardOutput = pipe
        probe.standardError = FileHandle.nullDevice
        guard (try? probe.run()) != nil else { return nil }
        probe.waitUntilExit()
        let out =
            String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !out.isEmpty, FileManager.default.isExecutableFile(atPath: out) else { return nil }
        return out
    }

    /// True if a generic-password Keychain item exists for `service`. Looks up
    /// only the item's attributes (no `-w`/`-g`), so it never reads the secret
    /// and never prompts for Keychain access. Used to detect CLIs that store
    /// their login in the Keychain (e.g. Claude Code → "Claude Code-credentials").
    public static func keychainGenericPasswordExists(service: String) -> Bool {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        probe.arguments = ["find-generic-password", "-s", service]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        guard (try? probe.run()) != nil else { return false }
        probe.waitUntilExit()
        return probe.terminationStatus == 0
    }

    /// Expands a leading `~` to the user's home directory.
    public static func expandingTilde(_ path: String) -> String {
        path.hasPrefix("~")
            ? NSHomeDirectory() + path.dropFirst().description
            : path
    }
}
