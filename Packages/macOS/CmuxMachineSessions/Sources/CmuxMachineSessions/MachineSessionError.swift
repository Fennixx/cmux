import Foundation

/// A validation, host prerequisite, or connection failure safe to display to the user.
public enum MachineSessionError: Error, LocalizedError, Sendable {
    /// A destination or field contains characters incompatible with the session protocol.
    case invalidInput
    /// The host lacks a supported tmux installation.
    case tmuxMissing
    /// The selected agent is unavailable on the host's login-shell PATH.
    case agentMissing
    /// The project directory does not exist on the selected host.
    case projectMissing
    /// The session no longer exists on the host.
    case sessionMissing
    /// A host command failed; detail contains bounded diagnostic output.
    case connection(String)

    /// Localized explanation of the failure.
    public var errorDescription: String? {
        switch self {
        case .invalidInput:
            String(localized: "machines.error.input", defaultValue: "Enter a valid SSH host, title, and absolute project path. Tabs and line breaks are not supported.")
        case .tmuxMissing:
            String(localized: "machines.error.tmux", defaultValue: "Install tmux 3.2 or newer on this computer, then connect again.")
        case .agentMissing:
            String(localized: "machines.error.agent", defaultValue: "The selected agent is not installed on this computer's login-shell PATH.")
        case .projectMissing:
            String(localized: "machines.error.project", defaultValue: "The project directory does not exist on the selected computer.")
        case .sessionMissing:
            String(localized: "machines.error.session", defaultValue: "This session has ended. Refresh the session list.")
        case .connection(let detail):
            String(localized: "machines.error.connection", defaultValue: "Could not connect. Check Tailscale and SSH access.") + "\n" + detail
        }
    }
}
