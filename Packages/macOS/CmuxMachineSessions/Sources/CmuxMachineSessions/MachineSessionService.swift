import Foundation
import CmuxFoundation

/// Executes bounded host commands; persistent agents belong to tmux, never to this client.
public actor MachineSessionService {
    private let runner: any CommandRunning
    private let directory: String
    private let commands: MachineSessionCommands
    private let network = MachineNetworkClient()
    private let bundledBin: String?

    /// Creates an execution service with an injectable command runner.
    /// - Parameters:
    ///   - runner: Process execution implementation.
    ///   - directory: Local working directory for SSH and local probes.
    ///   - bundledBin: App-owned tmux directory; absent for standalone tests.
    public init(runner: any CommandRunning, directory: String, bundledBin: String? = nil) {
        self.runner = runner
        self.directory = directory
        self.bundledBin = bundledBin
        commands = MachineSessionCommands(bundledBin: bundledBin)
    }

    /// Checks tmux compatibility and discovers installed agent executables.
    /// - Parameter machine: Host to probe.
    /// - Returns: Installed providers; credentials remain on the host and are checked by the agent.
    /// - Throws: A connection or prerequisite error.
    public func probe(_ machine: MachineProfile) async throws -> [MachineAgent] {
        if let endpoint = machine.endpoint { return try await network.request(.init(operation: .probe), endpoint: endpoint).agents ?? [] }
        let output = try await run(commands.probe, on: machine)
        let lines = output.split(separator: "\n").map(String.init)
        guard let version = lines.first(where: { $0.hasPrefix("tmux ") }) else { throw MachineSessionError.tmuxMissing }
        let numbers = version.dropFirst(5).split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard numbers.count >= 2, numbers[0] > 3 || (numbers[0] == 3 && numbers[1] >= 2)
        else { throw MachineSessionError.tmuxMissing }
        return MachineAgent.allCases.filter { lines.contains($0.rawValue) }
    }

    /// Lists managed sessions directly from the host, including ones started on another client.
    /// - Parameter machine: Host to query.
    /// - Returns: Live sessions created by this feature.
    /// - Throws: A connection error.
    public func sessions(_ machine: MachineProfile) async throws -> [MachineSession] {
        if let endpoint = machine.endpoint { return try await network.request(.init(operation: .list), endpoint: endpoint).sessions ?? [] }
        return commands.parseSessions(try await run(commands.list, on: machine))
    }

    /// Creates one detached agent session with a caller-owned idempotency identifier.
    /// - Parameters:
    ///   - session: Session identity and launch parameters.
    ///   - machine: Execution host.
    /// - Throws: A prerequisite or execution error. Existing IDs are never overwritten.
    public func create(_ session: MachineSession, on machine: MachineProfile) async throws {
        if let endpoint = machine.endpoint { _ = try await network.request(.init(operation: .create, session: session), endpoint: endpoint); return }
        _ = try await run(commands.create(session), on: machine)
    }

    /// Terminates a managed session after explicit user confirmation.
    /// - Parameters:
    ///   - session: Exact session to terminate.
    ///   - machine: Owning host.
    /// - Throws: A connection error.
    public func end(_ session: MachineSession, on machine: MachineProfile) async throws {
        if let endpoint = machine.endpoint { _ = try await network.request(.init(operation: .end, session: session), endpoint: endpoint); return }
        _ = try await run(commands.end(session.id), on: machine)
    }

    private func run(_ script: String, on machine: MachineProfile) async throws -> String {
        try commands.validate(machine)
        let prefix = bundledBin.map { "export PATH=" + commands.quote($0) + ":\"$PATH\"\n" } ?? ""
        let login = "exec \"${SHELL:-/bin/sh}\" -lc " + commands.quote(prefix + script)
        let executable = machine.isLocal ? "/bin/sh" : "/usr/bin/ssh"
        let arguments = machine.isLocal ? ["-c", login] : [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
            "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
            "--", machine.destination, login
        ]
        let result = await runner.run(directory: directory, executable: executable, arguments: arguments, timeout: 20)
        try Task.checkCancellation()
        guard result.executionError == nil, !result.timedOut, result.exitStatus == 0 else {
            switch result.exitStatus {
            case 72: throw MachineSessionError.tmuxMissing
            case 73: throw MachineSessionError.agentMissing
            case 74: throw MachineSessionError.projectMissing
            default: throw MachineSessionError.connection(String((result.stderr ?? result.executionError ?? "SSH timeout").suffix(2000)))
            }
        }
        return result.stdout ?? ""
    }

    /// Builds the local viewer command using the bundled tmux when available.
    /// - Parameter session: Exact managed session.
    /// - Returns: Quoted command that attaches without starting another agent.
    /// - Throws: Invalid session identity.
    public func localAttachCommand(_ session: MachineSession) throws -> String {
        // Ghostty prepends exec to initial commands. Environment setup must stay
        // inside the executable shell invocation, never before it as a builtin.
        try commands.attach(machine: MachineProfile(name: "", destination: ""), session: session)
    }
}
