import Foundation
import Network

/// The app-owned Tailscale listener; disabling sharing closes viewers but leaves agents running.
public actor MachineSharingHost {
    private let service: MachineSessionService
    private let trust: MachineTrustStore
    private let name: String
    private let local: MachineProfile
    private let allowLoopback: Bool
    private var listener: NWListener?
    private var channels: [UUID: MachineChannel] = [:]
    private var host: String?
    private var lifecycleGeneration = UUID()
    private let queue = DispatchQueue(label: "cmux.machine.listener")

    /// Creates an opt-in server owned by the containing cmux app.
    /// - Parameters:
    ///   - service: Local execution service; the wire protocol cannot choose an SSH target.
    ///   - stateURL: Private durable host identity and hashed device grants.
    ///   - name: Computer name advertised after authentication.
    /// - Throws: A damaged or unreadable trust store; it is never silently replaced.
    public init(service: MachineSessionService, stateURL: URL, name: String) throws {
        self.service = service; self.name = name; self.trust = try MachineTrustStore(url: stateURL)
        local = MachineProfile(name: name, destination: "")
        allowLoopback = false
    }

    init(service: MachineSessionService, trust: MachineTrustStore, name: String, allowLoopback: Bool) {
        self.service = service; self.trust = trust; self.name = name; self.allowLoopback = allowLoopback
        local = MachineProfile(name: name, destination: "")
    }

    /// Reports whether the user previously opted in to hosting on this build.
    /// - Returns: Persisted sharing preference, not a live network status.
    public func shouldRestoreSharing() async -> Bool { await trust.snapshot().sharing }

    /// Starts listening strictly on the supplied Tailscale address and returns the actual port.
    /// - Parameter address: Numeric local Tailscale IPv4 address.
    /// - Returns: Stable saved port, or a newly allocated port on first use.
    /// - Throws: Binding, prerequisites, or persistence failures; no public fallback is used.
    @discardableResult public func start(address: String) async throws -> UInt16 {
        guard MachineEndpoint.isTailnet(address) || (allowLoopback && address == "127.0.0.1") else { throw MachineSessionError.invalidInput }
        if let listener, host == address, let port = listener.port { return port.rawValue }
        let generation = UUID()
        lifecycleGeneration = generation
        _ = try await service.probe(local)
        guard generation == lifecycleGeneration else { throw CancellationError() }
        await stopConnections()
        let state = await trust.snapshot()
        guard generation == lifecycleGeneration else { throw CancellationError() }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: state.port) ?? .any)
        let candidate = try NWListener(using: parameters)
        candidate.newConnectionHandler = { [weak self] connection in Task { await self?.accept(connection) } }
        let states = AsyncThrowingStream<Void, Error> { continuation in
            candidate.stateUpdateHandler = { state in
                switch state {
                case .ready: continuation.yield(()); continuation.finish()
                case .failed(let error): continuation.finish(throwing: error)
                case .waiting(let error): continuation.finish(throwing: error)
                case .cancelled: continuation.finish(throwing: CancellationError())
                default: break
                }
            }
        }
        candidate.start(queue: queue)
        let deadline = Task { try await Task.sleep(for: .seconds(10)); candidate.cancel() }
        defer { deadline.cancel() }
        do {
            for try await _ in states { break }
            guard generation == lifecycleGeneration else { throw CancellationError() }
            guard let port = candidate.port?.rawValue else { throw MachineSessionError.connection("No listener port.") }
            try await trust.listening(port: port, sharing: true)
            guard generation == lifecycleGeneration else { throw CancellationError() }
            listener = candidate; host = address
            return port
        } catch { candidate.cancel(); throw error }
    }

    /// Generates a new ten-minute invitation, invalidating any unused previous invitation.
    /// - Returns: Copyable pairing code; never log it.
    /// - Throws: A stopped listener or secure random/persistence failure.
    public func createCode() async throws -> String {
        guard let host, listener != nil else { throw MachineSessionError.pairingDenied }
        return try await trust.invite(host: host, name: name).encoded()
    }

    /// Disables hosting, closes every viewer, and invalidates the current invitation.
    /// - Throws: A failure to persist the disabled preference.
    public func stop() async throws {
        lifecycleGeneration = UUID()
        await stopConnections()
        await trust.cancelInvitation()
        let state = await trust.snapshot()
        try await trust.listening(port: state.port, sharing: false)
    }

    /// Revokes all paired devices immediately, including currently attached viewers.
    /// - Throws: A persistence failure; callers must surface it rather than claim revocation.
    public func revokeAll() async throws {
        try await trust.revokeAll()
        for channel in channels.values { await channel.close() }
    }

    private func stopConnections() async {
        listener?.cancel(); listener = nil; host = nil
        for channel in channels.values { await channel.close() }
    }

    private func accept(_ connection: NWConnection) async {
        guard listener != nil, channels.count < 32,
              case let .hostPort(remote, _) = connection.endpoint,
              MachineEndpoint.isTailnet(remote.debugDescription) || (allowLoopback && remote.debugDescription == "127.0.0.1") else { connection.cancel(); return }
        let id = UUID(), channel = MachineChannel(connection: connection)
        channels[id] = channel
        // Unauthenticated peers cannot retain sockets indefinitely.
        let deadline = Task { try await Task.sleep(for: .seconds(15)); await channel.close() }
        defer { deadline.cancel(); channels.removeValue(forKey: id); Task { await channel.close() } }
        let identity = await trust.snapshot().serverID
        let generation = lifecycleGeneration
        do {
            let request = try await channel.receive()
            guard request.serverID == identity, let credential = request.credential else { throw MachineSessionError.pairingDenied }
            if request.operation == .pair {
                let secret = try await trust.redeem(credential, name: request.name ?? "Mac")
                try await channel.send(.init(operation: .result, serverID: identity, credential: secret, name: name))
                return
            }
            guard await trust.authorize(credential), listener != nil, generation == lifecycleGeneration else { throw MachineSessionError.pairingDenied }
            if request.operation == .attach {
                deadline.cancel()
                try await attach(request, channel: channel, identity: identity)
                return
            }
            var response = MachineWireMessage(operation: .result, serverID: identity)
            switch request.operation {
            case .probe: response.agents = try await service.probe(local)
            case .list: response.sessions = try await service.sessions(local)
            case .create:
                guard let session = request.session else { throw MachineSessionError.invalidInput }
                try await service.create(session, on: local)
            case .end:
                guard let session = request.session else { throw MachineSessionError.invalidInput }
                try await service.end(session, on: local)
            default: throw MachineSessionError.invalidInput
            }
            try await channel.send(response)
        } catch {
            let detail = (error as? MachineSessionError).map { if case .pairingDenied = $0 { return "unauthorized" }; return $0.localizedDescription } ?? "Host request failed."
            try? await channel.send(.init(operation: .failure, serverID: identity, error: String(detail.prefix(2000))))
        }
    }

    private func attach(_ request: MachineWireMessage, channel: MachineChannel, identity: UUID) async throws {
        guard let session = request.session,
              try await service.sessions(local).contains(where: { $0.id == session.id }) else { throw MachineSessionError.sessionMissing }
        let pty = MachinePTY()
        let stream = try await pty.start(command: service.localAttachCommand(session), columns: min(max(request.columns ?? 100, 2), 1000), rows: min(max(request.rows ?? 30, 2), 1000))
        defer { Task { await pty.close() } }
        try await channel.send(.init(operation: .result, serverID: identity))
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                defer { Task { await channel.close() } }
                for try await data in stream { try await channel.send(.init(operation: .output, bytes: data)) }
            }
            group.addTask {
                defer { Task { await pty.close() } }
                while !Task.isCancelled {
                    let input = try await channel.receive()
                    switch input.operation {
                    case .input: if let data = input.bytes { try await pty.input(data) }
                    case .resize: try await pty.resize(columns: input.columns ?? 100, rows: input.rows ?? 30)
                    default: throw MachineSessionError.invalidInput
                    }
                }
            }
            defer { group.cancelAll() }
            _ = try await group.next()
            await channel.close(); await pty.close()
        }
    }
}
