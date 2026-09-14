import CmuxFoundation
import Foundation

actor MachineTestRunner: CommandRunning {
    private let result: CommandResult
    private(set) var executables: [String] = []
    init(result: CommandResult) { self.result = result }
    func run(directory: String, executable: String, arguments: [String], timeout: TimeInterval?) async -> CommandResult {
        executables.append(executable)
        return result
    }
}
