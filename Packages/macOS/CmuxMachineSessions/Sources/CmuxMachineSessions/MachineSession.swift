/// A live session owned by the selected host's tmux server.
public struct MachineSession: Codable, Sendable, Identifiable, Equatable {
    /// Opaque tmux session name, independent of its display title.
    public let id: String
    /// User-assigned display title.
    public let title: String
    /// Absolute project path on the execution host.
    public let project: String
    /// Agent originally launched in the session.
    public let agent: MachineAgent

    /// Creates a session descriptor.
    /// - Parameters:
    ///   - id: Opaque host-owned session name.
    ///   - title: Display title.
    ///   - project: Host project path.
    ///   - agent: Agent provider.
    public init(id: String, title: String, project: String, agent: MachineAgent) {
        self.id = id
        self.title = title
        self.project = project
        self.agent = agent
    }
}
