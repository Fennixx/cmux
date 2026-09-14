/// The agent executable to launch on the selected host using its existing credentials.
public enum MachineAgent: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Anthropic's Claude Code CLI.
    case claude
    /// OpenAI's Codex CLI.
    case codex
    /// Stable provider identifier.
    public var id: String { rawValue }
    /// Invariant provider product name.
    public var displayName: String { self == .claude ? "Claude Code" : "Codex" }
}
