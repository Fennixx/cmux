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
    /// The invitation expired, was already used, or this device's access was revoked.
    case pairingDenied
    /// A host command failed; detail contains bounded diagnostic output.
    case connection(String)

    /// Localized explanation of the failure.
    public var errorDescription: String? {
        switch self {
        case .pairingDenied:
            String(localized: "machines.error.pairing", defaultValue: "Pairing failed or access was revoked. Generate a new code on the host Mac.")
        case .invalidInput:
            String(localized: "machines.error.fields", defaultValue: "Enter a valid pairing code, title, and absolute project path.")
        case .tmuxMissing:
            String(localized: "machines.error.tmux", defaultValue: "Install tmux 3.2 or newer on this computer, then connect again.")
        case .agentMissing:
            String(localized: "machines.error.agent", defaultValue: "The selected agent is not installed on this computer's login-shell PATH.")
        case .projectMissing:
            String(localized: "machines.error.project", defaultValue: "The project directory does not exist on the selected computer.")
        case .sessionMissing:
            String(localized: "machines.error.session", defaultValue: "This session has ended. Refresh the session list.")
        case .connection(let detail):
            String(localized: "machines.error.privateConnection", defaultValue: "Could not connect. Check Tailscale and that sharing is enabled in cmux on the host Mac.") + "\n" + detail
        }
    }
}
