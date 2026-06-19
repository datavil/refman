import Foundation
import Testing

@testable import RefmanCore

@Suite struct CLIEnvironmentTests {
    @Test func resolvesToolOnPath() {
        // `ls` is always present; resolved via the login-shell fallback.
        let path = CLIEnvironment.resolve(["ls"])
        #expect(path != nil)
        #expect(path.map { FileManager.default.isExecutableFile(atPath: $0) } == true)
    }

    @Test func missingToolReturnsNil() {
        #expect(CLIEnvironment.resolve(["definitely-not-a-real-binary-xyz"]) == nil)
    }

    @Test func prefersExtraDir() {
        // /bin/ls exists; passing /bin as an extra dir should resolve it directly.
        #expect(CLIEnvironment.resolve(["ls"], extraDirs: ["/bin"]) == "/bin/ls")
    }

    @Test func missingKeychainItemReturnsFalse() {
        #expect(
            CLIEnvironment.keychainGenericPasswordExists(
                service: "refman-nonexistent-service-xyz") == false)
    }

    @Test func expandsTilde() {
        #expect(CLIEnvironment.expandingTilde("~/x") == "\(NSHomeDirectory())/x")
        #expect(CLIEnvironment.expandingTilde("/abs") == "/abs")
    }
}
