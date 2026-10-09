import Testing
@testable import TokenGlanceCore

@Test func versionIsSet() {
    #expect(!TokenGlanceCore.version.isEmpty)
}
