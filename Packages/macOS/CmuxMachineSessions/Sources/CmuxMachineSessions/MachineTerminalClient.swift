import Foundation

/// Runs the app-bundled terminal bridge; secrets are read from a private catalog, never process arguments.
public struct MachineTerminalClient: Sendable {
    /// Constructs a private-network terminal client.
    public init() {}

    /// Attaches the current terminal to one host-owned agent session.
    /// - Parameters:
    ///   - catalogURL: The containing app's private computer catalog.
    ///   - machineID: Paired computer identity in the catalog.
    ///   - sessionID: Exact managed tmux session ID.
    /// - Throws: Missing profile, authentication failure, or a lost terminal connection.
    public func run(catalogURL: URL, machineID: UUID, sessionID: String) async throws {
        try MachineSessionCommands().validateID(sessionID)
        let profiles = try await MachineProfileRepository(url: catalogURL).load()
        guard let endpoint = profiles.first(where: { $0.id == machineID })?.endpoint else { throw MachineSessionError.pairingDenied }
        let channel = try MachineChannel(endpoint: endpoint)
        let terminal = MachineTerminalIO()
        let (columns, rows) = await terminal.size()
        let deadline = Task { try await Task.sleep(for: .seconds(15)); await channel.close() }
        do {
            try await channel.send(.init(operation: .attach, serverID: endpoint.serverID, credential: endpoint.credential,
                session: MachineSession(id: sessionID, title: "", project: "", agent: .codex), columns: columns, rows: rows))
            let response = try await channel.receive()
            guard response.operation == .result, response.serverID == endpoint.serverID else { throw MachineSessionError.pairingDenied }
            deadline.cancel()
            let input = try await terminal.start()
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    defer { Task { await channel.close() } }
                    for try await message in input { try await channel.send(message) }
                }
                group.addTask {
                    defer { Task { await terminal.stop() } }
                    while !Task.isCancelled {
                        let message = try await channel.receive()
                        guard message.operation == .output, let data = message.bytes else { throw MachineSessionError.invalidInput }
                        try FileHandle.standardOutput.write(contentsOf: data)
                    }
                }
                defer { group.cancelAll() }
                _ = try await group.next()
                await channel.close(); await terminal.stop()
            }
        } catch {
            deadline.cancel()
            await terminal.stop(); await channel.close()
            throw error
        }
        await terminal.stop(); await channel.close()
    }
}
