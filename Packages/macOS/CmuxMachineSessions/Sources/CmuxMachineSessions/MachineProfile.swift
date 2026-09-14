import Foundation

/// A saved execution host and the project paths previously used on it.
public struct MachineProfile: Codable, Sendable, Identifiable, Equatable {
    /// Stable local catalog identity; remote sessions have independent host-owned identities.
    public var id: UUID
    /// User-facing computer name.
    public var name: String
    /// SSH destination or alias; an empty value denotes this computer.
    public var destination: String
    /// Absolute project directories on this host, most recently used first.
    public var projects: [String]
    /// Paired private-network endpoint; absent for local or legacy SSH profiles.
    public var endpoint: MachineEndpoint?

    /// Creates a host profile.
    /// - Parameters:
    ///   - id: Stable catalog identity.
    ///   - name: Display name.
    ///   - destination: SSH destination; empty for local execution.
    ///   - projects: Previously used project directories.
    public init(id: UUID = UUID(), name: String, destination: String, projects: [String] = []) {
        self.id = id
        self.name = name
        self.destination = destination
        self.projects = projects
    }

    /// Whether commands execute on this computer without SSH.
    public var isLocal: Bool { destination.isEmpty && endpoint == nil }
}
