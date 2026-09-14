import Foundation
import CryptoKit
import Security

/// Owns one-time pairing grants and durable hashed device credentials.
actor MachineTrustStore {
    struct State: Codable {
        var serverID = UUID()
        var port: UInt16 = 0
        var sharing = false
        var devices: [String: String] = [:]
    }
    private let url: URL
    private let now: @Sendable () -> Date
    private var state: State
    private var invitation: (digest: String, expiry: Date)?

    init(url: URL, now: @escaping @Sendable () -> Date = { Date() }) throws {
        self.url = url; self.now = now
        if FileManager.default.fileExists(atPath: url.path) {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
        } else { state = State() }
    }

    func snapshot() -> State { state }

    func listening(port: UInt16, sharing: Bool) throws {
        var next = state; next.port = port; next.sharing = sharing
        try save(next)
    }

    func invite(host: String, name: String) throws -> MachinePairingCode {
        let secret = try randomSecret()
        let expiry = now().addingTimeInterval(600)
        invitation = (digest(secret), expiry)
        return MachinePairingCode(endpoint: MachineEndpoint(serverID: state.serverID, host: host, port: state.port, credential: secret), name: name, expiresAt: expiry)
    }

    func redeem(_ secret: String, name: String) throws -> String {
        guard let invitation, invitation.expiry > now(), secret.count == 64,
              constantEqual(digest(secret), invitation.digest), state.devices.count < 100 else { throw MachineSessionError.pairingDenied }
        let credential = try randomSecret()
        var next = state
        next.devices[digest(credential)] = String(name.prefix(100))
        try save(next)
        self.invitation = nil
        return credential
    }

    func authorize(_ secret: String) -> Bool {
        guard secret.count == 64 else { return false }
        let candidate = digest(secret)
        return state.devices.keys.contains { constantEqual(candidate, $0) }
    }

    func revokeAll() throws {
        var next = state; next.devices = [:]
        try save(next)
        invitation = nil
    }

    func cancelInvitation() { invitation = nil }

    private func save(_ next: State) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(next)
        try MachinePrivateFile().write(data, to: url)
        state = next
    }

    private func randomSecret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw MachineSessionError.pairingDenied }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func digest(_ secret: String) -> String { SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func constantEqual(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8), rhs = Array(b.utf8)
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
