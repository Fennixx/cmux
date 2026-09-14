import Foundation

/// Connects to an authenticated cmux host without SSH or a cloud account.
public actor MachineNetworkClient {
    private let allowLoopback: Bool

    /// Creates a client restricted to the Tailscale network.
    public init() { allowLoopback = false }
    init(allowLoopback: Bool) { self.allowLoopback = allowLoopback }

    /// Redeems a one-time code and returns a reusable device profile.
    /// - Parameters:
    ///   - code: Invitation copied from the other Mac.
    ///   - clientName: This device's human-readable name.
    /// - Returns: Paired host profile to persist privately.
    /// - Throws: Invalid input, connection failure, or rejected invitation.
    public func pair(code: String, clientName: String) async throws -> MachineProfile {
        let invitation = try MachinePairingCode.decode(code)
        let response = try await request(.init(operation: .pair, name: clientName), endpoint: invitation.endpoint)
        guard let credential = response.credential, credential.count == 64 else { throw MachineSessionError.pairingDenied }
        var machine = MachineProfile(id: invitation.endpoint.serverID, name: response.name ?? invitation.name, destination: invitation.endpoint.host)
        machine.endpoint = invitation.endpoint
        machine.endpoint?.credential = credential
        return machine
    }

    func request(_ message: MachineWireMessage, endpoint: MachineEndpoint) async throws -> MachineWireMessage {
        let channel = try MachineChannel(endpoint: endpoint, allowLoopback: allowLoopback)
        // A bounded request deadline also covers an endpoint that accepts TCP but never replies.
        let deadline = Task { try await Task.sleep(for: .seconds(25)); await channel.close() }
        defer { deadline.cancel(); Task { await channel.close() } }
        return try await withTaskCancellationHandler {
            var authenticated = message
            authenticated.serverID = endpoint.serverID
            authenticated.credential = endpoint.credential
            try await channel.send(authenticated)
            let response = try await channel.receive()
            guard response.serverID == endpoint.serverID else { throw MachineSessionError.pairingDenied }
            if response.operation == .failure {
                if response.error == "unauthorized" { throw MachineSessionError.pairingDenied }
                throw MachineSessionError.connection(response.error ?? "Host request failed.")
            }
            guard response.operation == .result else { throw MachineSessionError.invalidInput }
            return response
        } onCancel: { Task { await channel.close() } }
    }
}
