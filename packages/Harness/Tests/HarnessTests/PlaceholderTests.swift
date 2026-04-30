import Testing
@testable import Harness

@Suite("PlaceholderTests")
struct PlaceholderTests {
    @Test("Harness library links and exports a version stamp")
    func smoke() {
        #expect(HarnessVersion.value == "0.1.0")
    }
}
