import Foundation
import CmuxMachineSessions

@main
struct MachineAttachMain {
    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count == 4, let machineID = UUID(uuidString: arguments[2]) else { exit(64) }
        do {
            try await MachineTerminalClient().run(catalogURL: URL(fileURLWithPath: arguments[1]), machineID: machineID, sessionID: arguments[3])
        } catch {
            // Restore common terminal modes after a remote PTY disappears mid-frame.
            print("\u{1b}[?1049l\u{1b}[?25h\u{1b}[0m\r\n" + error.localizedDescription)
            exit(1)
        }
    }
}
