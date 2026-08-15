import Testing
@testable import ClipdCore

@Test("Core is reachable and reports its version")
func coreVersion() {
    #expect(ClipdCore.version == "0.1.1")
}
