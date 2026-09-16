import Testing
@testable import SARACore

@Suite("Permissions")
struct PermissionTests {
    @Test("Write-only calendar access cannot read")
    func writeOnlyCannotRead() {
        #expect(PermissionStatus.writeOnly.canWrite)
        #expect(!PermissionStatus.writeOnly.canRead)
    }

    @Test("Only an undetermined status should trigger a prompt")
    func promptable() {
        #expect(PermissionStatus.notDetermined.isPromptable)
        #expect(!PermissionStatus.denied.isPromptable)
        #expect(!PermissionStatus.restricted.isPromptable)
        #expect(!PermissionStatus.authorized.isPromptable)
    }

    @Test("Denied and restricted read differently to the user")
    func messagesDiffer() {
        let denied = PermissionError(capability: .calendar, status: .denied)
        let restricted = PermissionError(capability: .calendar, status: .restricted)

        #expect(denied.userMessage.contains("Settings"))
        #expect(restricted.userMessage.contains("restricted"))
        #expect(denied.userMessage != restricted.userMessage)
    }
}
