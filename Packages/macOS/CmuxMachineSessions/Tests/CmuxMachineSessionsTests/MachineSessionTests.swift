import Foundation
import Testing
import CmuxFoundation
@testable import CmuxMachineSessions

struct MachineSessionTests {
    private let local = MachineProfile(name: "Local", destination: "")

    @Test(arguments: ["-oProxyCommand=touch /tmp/bad", "host;false", "host\nother", "$(whoami)", "a b"])
    func rejectsUnsafeDestinations(_ destination: String) {
        #expect(throws: MachineSessionError.self) {
            try MachineSessionCommands().validate(MachineProfile(name: "Test", destination: destination))
        }
    }

    @Test(arguments: ["me@orion.tail123.ts.net", "orion", "me@[fd7a:115c:a1e0::1]"])
    func acceptsSSHDestinations(_ destination: String) throws {
        try MachineSessionCommands().validate(MachineProfile(name: "Test", destination: destination))
    }

    @Test func shellArgumentsRemainLiteral() async throws {
        let payload = "a ' quote; $(printf INJECTED) `printf INJECTED` $PATH\nsecond line"
        let result = await CommandRunner().run(directory: "/private/tmp", executable: "/bin/sh", arguments: [
            "-c", "printf %s " + MachineSessionCommands().quote(payload)
        ], timeout: 5)
        #expect(result.exitStatus == 0)
        #expect(result.stdout == payload)
    }

    @Test func discoversOnlyCompleteManagedSessions() {
        let id = "cmux-agent-" + UUID().uuidString.lowercased()
        let output = "main\tOther\t/tmp\tclaude\n\(id)\tFix invoices\t/work/a b\tcodex\ncmux-agent-bad\tBad\t/tmp\tclaude\n"
        let sessions = MachineSessionCommands().parseSessions(output)
        #expect(sessions == [MachineSession(id: id, title: "Fix invoices", project: "/work/a b", agent: .codex)])
    }

    @Test func missingAgentDoesNotReportLaunchSuccess() async {
        let runner = MachineTestRunner(result: .init(stdout: "", stderr: "", exitStatus: 73, timedOut: false, executionError: nil))
        let service = MachineSessionService(runner: runner, directory: "/private/tmp")
        do {
            try await service.create(sample(), on: local)
            Issue.record("Expected missing agent")
        } catch MachineSessionError.agentMissing {} catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test func remoteProbeCannotExecuteLocallyOnFailure() async {
        let runner = MachineTestRunner(result: .init(stdout: nil, stderr: "Permission denied", exitStatus: 255, timedOut: false, executionError: nil))
        let service = MachineSessionService(runner: runner, directory: "/private/tmp")
        await #expect(throws: MachineSessionError.self) {
            _ = try await service.probe(MachineProfile(name: "Remote", destination: "me@orion"))
        }
        let calls = await runner.executables
        #expect(calls == ["/usr/bin/ssh"])
    }

    @Test func oldTmuxIsRejected() async {
        let runner = MachineTestRunner(result: .init(stdout: "tmux 3.1c\nclaude\n", stderr: "", exitStatus: 0, timedOut: false, executionError: nil))
        let service = MachineSessionService(runner: runner, directory: "/private/tmp")
        await #expect(throws: MachineSessionError.self) { _ = try await service.probe(local) }
    }

    @Test func repositoryRoundTripAndCorruptionPreservation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("machines.json")
        let repository = MachineProfileRepository(url: url)
        #expect(try await repository.load().isEmpty)
        let profiles = [local, MachineProfile(name: "Mini", destination: "me@mini", projects: ["/work/project"])]
        try await repository.save(profiles)
        #expect(try await repository.load() == profiles)
        try Data("broken".utf8).write(to: url)
        await #expect(throws: (any Error).self) { _ = try await repository.load() }
        #expect(try String(contentsOf: url, encoding: .utf8) == "broken")
    }

    @Test func refusesTerminationOfUnmanagedSessions() {
        #expect(throws: MachineSessionError.self) { _ = try MachineSessionCommands().end("main") }
    }

    @Test func liveSessionSurvivesAClientAndIsDiscoveredByAnother() async throws {
        let tmux = "/opt/homebrew/bin/tmux"
        guard FileManager.default.isExecutableFile(atPath: tmux) else { return }
        let runner = CommandRunner()
        let session = sample()
        let started = await runner.run(directory: "/private/tmp", executable: tmux, arguments: [
            "new-session", "-d", "-s", session.id,
            "-e", "CMUX_MACHINE_TITLE=" + session.title,
            "-e", "CMUX_MACHINE_PROJECT=" + session.project,
            "-e", "CMUX_MACHINE_AGENT=" + session.agent.rawValue,
            "/bin/sleep 60"
        ], timeout: 5)
        #expect(started.exitStatus == 0)
        let firstClient = MachineSessionService(runner: runner, directory: "/private/tmp")
        let secondClient = MachineSessionService(runner: runner, directory: "/private/tmp")
        do {
            #expect(try await firstClient.sessions(local).contains(session))
            let detached = await runner.run(directory: "/private/tmp", executable: "/bin/sh", arguments: [
                "-c", "printf 'detach-client\\n' | " + tmux + " -C attach-session -t " + MachineSessionCommands().quote("=" + session.id)
            ], timeout: 5)
            #expect(detached.exitStatus == 0)
            #expect(try await secondClient.sessions(local).contains(session))
            // Retrying a launch with the same ID must preserve the existing process.
            try await secondClient.create(session, on: local)
            let process = await runner.run(directory: "/private/tmp", executable: tmux, arguments: [
                "list-panes", "-t", "=" + session.id, "-F", "#{pane_current_command}"
            ], timeout: 5)
            #expect(process.exitStatus == 0)
            #expect(process.stdout?.trimmingCharacters(in: .whitespacesAndNewlines) == "sleep")
            try await secondClient.end(session, on: local)
            #expect(try await firstClient.sessions(local).allSatisfy { $0.id != session.id })
        } catch {
            _ = await runner.run(directory: "/private/tmp", executable: tmux, arguments: ["kill-session", "-t", "=" + session.id], timeout: 5)
            throw error
        }
    }

    private func sample() -> MachineSession {
        MachineSession(id: "cmux-agent-" + UUID().uuidString.lowercased(), title: "Test", project: "/private/tmp", agent: .claude)
    }
}
