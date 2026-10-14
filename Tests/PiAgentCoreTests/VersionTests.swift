import Testing

@testable import PiAgentCore

@Suite("Package")
struct VersionTests {
    @Test("exposes the semantic version")
    func version() {
        #expect(PiAgentCore.version == "0.1.0")
    }
}
