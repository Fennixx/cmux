import Foundation

/// A private-network server and its device-specific access credential.
public struct MachineEndpoint: Codable, Sendable, Equatable {
    /// Stable identity of the server, independent of the client catalog.
    public var serverID: UUID
    /// Numeric Tailscale IPv4 address; DNS and public endpoints are deliberately rejected.
    public var host: String
    /// Dedicated port owned by this cmux build.
    public var port: UInt16
    /// Device-specific secret, stored only in the owner's private configuration file.
    public var credential: String

    /// Constructs a paired endpoint.
    /// - Parameters:
    ///   - serverID: Expected server identity.
    ///   - host: Tailscale IPv4 address.
    ///   - port: Listening port.
    ///   - credential: Random access credential.
    public init(serverID: UUID, host: String, port: UInt16, credential: String) {
        self.serverID = serverID; self.host = host; self.port = port; self.credential = credential
    }

    /// Tests membership in Tailscale's IPv4 address range without DNS resolution.
    /// - Parameter host: Candidate literal address.
    /// - Returns: Whether the address is canonical IPv4 in 100.64.0.0/10.
    public static func isTailnet(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let values = parts.compactMap { UInt8($0) }
        return values.count == 4 && parts.count == 4 && values.map(String.init).joined(separator: ".") == host
            && values[0] == 100 && (64...127).contains(values[1])
    }
}
