import Foundation

/// A short-lived, single-use invitation containing a private route and a pairing secret.
public struct MachinePairingCode: Codable, Sendable {
    /// Endpoint whose credential is a pairing secret, not a reusable device credential.
    public let endpoint: MachineEndpoint
    /// Host display name, confirmed again by the server during pairing.
    public let name: String
    /// Absolute expiry; the host enforces this independently of the receiving device.
    public let expiresAt: Date

    /// Creates an invitation for an already-running server.
    /// - Parameters:
    ///   - endpoint: Server route and one-time secret.
    ///   - name: Display name.
    ///   - expiresAt: Host-controlled expiry.
    public init(endpoint: MachineEndpoint, name: String, expiresAt: Date) {
        self.endpoint = endpoint; self.name = name; self.expiresAt = expiresAt
    }

    /// Encodes a copyable code; callers must never log this value.
    /// - Returns: Versioned code accepted by the other Mac's pairing form.
    /// - Throws: An encoding failure.
    public func encoded() throws -> String {
        "CMUX1-" + (try JSONEncoder().encode(self)).base64EncodedString()
    }

    /// Decodes and validates an invitation without contacting any network endpoint.
    /// - Parameter text: Code copied from the host.
    /// - Returns: Validated invitation; expiry is checked by the host on redemption.
    /// - Throws: Invalid or non-Tailscale input.
    public static func decode(_ text: String) throws -> Self {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 4096, text.hasPrefix("CMUX1-"),
              let data = Data(base64Encoded: String(text.dropFirst(6))) else { throw MachineSessionError.invalidInput }
        let code = try JSONDecoder().decode(Self.self, from: data)
        guard MachineEndpoint.isTailnet(code.endpoint.host), code.endpoint.port != 0,
              code.endpoint.credential.count == 64, code.name.count <= 200 else { throw MachineSessionError.invalidInput }
        return code
    }
}
