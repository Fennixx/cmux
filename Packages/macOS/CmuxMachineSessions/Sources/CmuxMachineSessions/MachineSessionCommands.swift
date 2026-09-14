import Foundation

/// Builds quoted shell commands for host-owned sessions without interpolating executable input.
public struct MachineSessionCommands: Sendable {
    /// Constructs the command builder.
    public init() {}

    /// Quotes one POSIX shell argument, preserving all literal characters.
    /// - Parameter value: Argument contents.
    /// - Returns: A single shell word.
    public func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// Validates a host before any process is launched.
    /// - Parameter machine: Profile to validate.
    /// - Throws: ``MachineSessionError/invalidInput`` for option-like or malformed hosts.
    public func validate(_ machine: MachineProfile) throws {
        guard machine.isLocal || (
            !machine.destination.hasPrefix("-") &&
            machine.destination.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.@:\-\[\]]*$"#, options: .regularExpression) != nil
        ) else { throw MachineSessionError.invalidInput }
    }

    /// Builds an interactive attach command; closing its terminal only detaches the client.
    /// - Parameters:
    ///   - machine: Execution host.
    ///   - session: Existing host-owned session.
    /// - Returns: Command suitable for a cmux terminal startup.
    /// - Throws: ``MachineSessionError/invalidInput`` for malformed identifiers.
    public func attach(machine: MachineProfile, session: MachineSession) throws -> String {
        try validate(machine)
        try validateID(session.id)
        let body = prelude + "\nexec tmux attach-session -t " + quote("=" + session.id)
        let login = "exec \"${SHELL:-/bin/sh}\" -lc " + quote(body)
        if machine.isLocal { return "/bin/sh -c " + quote(login) }
        return "/usr/bin/ssh -tt -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -- "
            + quote(machine.destination) + " " + quote(login)
    }

    var prelude: String {
        """
        export PATH="$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
        unset TMUX CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_SOCKET_PATH CMUX_SOCKET CMUX_TAB_ID
        command -v tmux >/dev/null 2>&1 || exit 72
        """
    }

    var probe: String {
        prelude + """

        tmux -V
        command -v claude >/dev/null 2>&1 && printf 'claude\\n'
        command -v codex >/dev/null 2>&1 && printf 'codex\\n'
        exit 0
        """
    }

    var list: String {
        prelude + """

        if ! tmux list-sessions >/dev/null 2>&1; then exit 0; fi
        tmux list-sessions -F '#{session_name}\t#{CMUX_MACHINE_TITLE}\t#{CMUX_MACHINE_PROJECT}\t#{CMUX_MACHINE_AGENT}'
        """
    }

    func create(_ session: MachineSession) throws -> String {
        try validateID(session.id)
        guard session.project.hasPrefix("/"), !session.title.isEmpty,
              [session.title, session.project].allSatisfy({ !$0.contains(where: { $0.isNewline || $0 == "\t" || $0 == "\0" }) })
        else { throw MachineSessionError.invalidInput }
        // Metadata is part of new-session's environment, so discovery never observes half a record.
        let args = ["new-session", "-d", "-s", session.id, "-c", session.project,
                    "-e", "CMUX_MACHINE_TITLE=" + session.title,
                    "-e", "CMUX_MACHINE_PROJECT=" + session.project,
                    "-e", "CMUX_MACHINE_AGENT=" + session.agent.rawValue]
        return prelude + "\nif tmux has-session -t " + quote("=" + session.id) + " 2>/dev/null; then exit 0; fi\n"
            + "[ -d " + quote(session.project) + " ] || exit 74\n"
            + "command -v " + quote(session.agent.rawValue) + " >/dev/null 2>&1 || exit 73\n"
            + "tmux " + args.map(quote).joined(separator: " ")
            + " -e \"PATH=$PATH\" "
            + quote("exec \"${SHELL:-/bin/sh}\" -lc " + quote(prelude + "\nexec " + session.agent.rawValue))
            + "\n"
    }

    func validateID(_ id: String) throws {
        guard id.hasPrefix("cmux-agent-"), UUID(uuidString: String(id.dropFirst(11))) != nil
        else { throw MachineSessionError.invalidInput }
    }

    func end(_ id: String) throws -> String {
        try validateID(id)
        return prelude + "\ntmux kill-session -t " + quote("=" + id)
    }

    func parseSessions(_ output: String) -> [MachineSession] {
        output.split(separator: "\n").compactMap { row in
            let fields = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4, (try? validateID(fields[0])) != nil,
                  let agent = MachineAgent(rawValue: fields[3]) else { return nil }
            return MachineSession(id: fields[0], title: fields[1], project: fields[2], agent: agent)
        }
    }
}
