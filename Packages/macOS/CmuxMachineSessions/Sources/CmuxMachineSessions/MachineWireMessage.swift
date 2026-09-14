import Foundation

/// Closed protocol vocabulary; remote clients never submit shell commands or arbitrary RPC names.
struct MachineWireMessage: Codable, Sendable {
    enum Operation: String, Codable, Sendable { case pair, probe, list, create, end, attach, input, resize, output, result, failure }
    var operation: Operation
    var version = 1
    var serverID: UUID?
    var credential: String?
    var name: String?
    var session: MachineSession?
    var sessions: [MachineSession]?
    var agents: [MachineAgent]?
    var bytes: Data?
    var columns: UInt16?
    var rows: UInt16?
    var error: String?
}
