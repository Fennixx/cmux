import Foundation
import Network

/// Bounded length-prefixed messages over the encrypted Tailscale network.
actor MachineChannel {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "cmux.machine.channel", qos: .userInitiated)

    init(connection: NWConnection) {
        self.connection = connection
        connection.start(queue: queue)
    }

    init(endpoint: MachineEndpoint, allowLoopback: Bool = false) throws {
        guard MachineEndpoint.isTailnet(endpoint.host) || (allowLoopback && endpoint.host == "127.0.0.1"),
              let port = NWEndpoint.Port(rawValue: endpoint.port) else { throw MachineSessionError.invalidInput }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 8
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: NWParameters(tls: nil, tcp: tcp))
        connection.start(queue: queue)
    }

    func close() { connection.cancel() }

    func send(_ message: MachineWireMessage) async throws {
        let payload = try JSONEncoder().encode(message)
        guard payload.count <= 65_536 else { throw MachineSessionError.invalidInput }
        var size = UInt32(payload.count).bigEndian
        var framed = withUnsafeBytes(of: &size) { Data($0) }
        framed.append(payload)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: framed, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    func receive() async throws -> MachineWireMessage {
        let header = try await read(4)
        let count = header.reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= 65_536 else { throw MachineSessionError.invalidInput }
        let message = try JSONDecoder().decode(MachineWireMessage.self, from: try await read(count))
        guard message.version == 1 else { throw MachineSessionError.invalidInput }
        return message
    }

    private func read(_ count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, data.count == count { continuation.resume(returning: data) }
                else { continuation.resume(throwing: MachineSessionError.connection("Connection closed.")) }
            }
        }
    }
}
