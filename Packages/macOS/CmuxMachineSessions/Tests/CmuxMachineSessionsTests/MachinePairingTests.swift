import Foundation
import Testing
import CmuxFoundation
@testable import CmuxMachineSessions

struct MachinePairingTests {
    @Test(arguments: ["127.0.0.1", "0.0.0.0", "8.8.8.8", "100.63.0.1", "100.128.0.1", "100.064.0.1", "host.tailnet.ts.net", "100.64.0.1.evil.test"])
    func publicOrAmbiguousEndpointsAreRejected(_ host: String) throws {
        let code = MachinePairingCode(endpoint: MachineEndpoint(serverID: UUID(), host: host, port: 1234, credential: String(repeating: "a", count: 64)), name: "Mac", expiresAt: Date())
        #expect(throws: MachineSessionError.self) { _ = try MachinePairingCode.decode(code.encoded()) }
    }

    @Test func oneTimePairingAndRevocationSurviveRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("trust.json")
        let trust = try MachineTrustStore(url: url)
        try await trust.listening(port: 1234, sharing: true)
        let invitation = try await trust.invite(host: "100.64.1.2", name: "Mac")
        let secret = try await trust.redeem(invitation.endpoint.credential, name: "Second Mac")
        #expect(await trust.authorize(secret))
        #expect(!(await trust.authorize(invitation.endpoint.credential)))
        await #expect(throws: MachineSessionError.self) { _ = try await trust.redeem(invitation.endpoint.credential, name: "Replay") }
        let restarted = try MachineTrustStore(url: url)
        #expect(await restarted.authorize(secret))
        #expect(await restarted.snapshot().serverID == trust.snapshot().serverID)
        #expect(!(try String(contentsOf: url, encoding: .utf8)).contains(secret))
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) == 0o600)
        try await restarted.revokeAll()
        #expect(!(await restarted.authorize(secret)))
        #expect(!(try await MachineTrustStore(url: url).authorize(secret)))
    }

    @Test func replacingCodeInvalidatesPreviousGrant() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let trust = try MachineTrustStore(url: directory.appendingPathComponent("trust.json"))
        let first = try await trust.invite(host: "100.64.1.2", name: "Mac")
        let second = try await trust.invite(host: "100.64.1.2", name: "Mac")
        await #expect(throws: MachineSessionError.self) { _ = try await trust.redeem(first.endpoint.credential, name: "Old") }
        _ = try await trust.redeem(second.endpoint.credential, name: "New")
    }

    @Test func privateCatalogRoundTripsDeviceCredential() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("machines.json")
        let repository = MachineProfileRepository(url: url)
        var profile = MachineProfile(name: "Mini", destination: "100.64.1.2")
        profile.endpoint = MachineEndpoint(serverID: UUID(), host: "100.64.1.2", port: 1234, credential: "test")
        try await repository.save([profile])
        #expect(try await repository.load() == [profile])
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) == 0o600)
    }

    @Test func actualNetworkPairingRequiresAuthAndCanBeRevoked() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let trust = try MachineTrustStore(url: directory.appendingPathComponent("trust.json"))
        let runner = MachineTestRunner(result: .init(stdout: "tmux 3.7\nclaude\ncodex\n", stderr: "", exitStatus: 0, timedOut: false, executionError: nil))
        let service = MachineSessionService(runner: runner, directory: directory.path)
        let host = MachineSharingHost(service: service, trust: trust, name: "Fixture", allowLoopback: true)
        let port = try await host.start(address: "127.0.0.1")
        do {
            let invitation = try await trust.invite(host: "127.0.0.1", name: "Fixture")
            var endpoint = invitation.endpoint
            #expect(endpoint.port == port)
            let client = MachineNetworkClient(allowLoopback: true)
            await #expect(throws: MachineSessionError.self) { _ = try await client.request(.init(operation: .probe), endpoint: endpoint) }
            // The rejected request must not reach even the provider probe.
            #expect(await runner.executables.count == 1)
            let response = try await client.request(.init(operation: .pair, name: "Test Mac"), endpoint: endpoint)
            endpoint.credential = try #require(response.credential)
            let probe = try await client.request(.init(operation: .probe), endpoint: endpoint)
            #expect(probe.agents == [.claude, .codex])
            try await host.revokeAll()
            await #expect(throws: MachineSessionError.self) { _ = try await client.request(.init(operation: .probe), endpoint: endpoint) }
            try await host.stop()
            #expect(!(await host.shouldRestoreSharing()))
        } catch { try? await host.stop(); throw error }
    }

    @Test func realPTYCanSendInputResizeAndDetachWithoutKillingSession() async throws {
        let tmux = "/opt/homebrew/bin/tmux"
        guard FileManager.default.isExecutableFile(atPath: tmux) else { return }
        let runner = CommandRunner(), commands = MachineSessionCommands()
        let id = "cmux-agent-" + UUID().uuidString.lowercased()
        let started = await runner.run(directory: "/private/tmp", executable: tmux, arguments: ["new-session", "-d", "-s", id, "/bin/sh"], timeout: 5)
        try #require(started.exitStatus == 0)
        let pty = MachinePTY()
        do {
            let stream = try await pty.start(command: tmux + " attach -t " + commands.quote("=" + id), columns: 100, rows: 30)
            let deadline = Task { try await Task.sleep(for: .seconds(10)); await pty.close() }
            defer { deadline.cancel() }
            try await pty.resize(columns: 120, rows: 40)
            var output = ""
            var sent = false
            for try await bytes in stream {
                output += String(decoding: bytes, as: UTF8.self)
                if !sent && output.contains("sh-3.2$") {
                    sent = true
                    try await pty.input(Data("printf 'CMUX_PTY_%s\\n' VERIFIED\r".utf8))
                }
                if output.contains("CMUX_PTY_VERIFIED") { break }
            }
            #expect(output.contains("CMUX_PTY_VERIFIED"), "Expected marker from a real shell after writing through the PTY")
            await pty.close()
            let alive = await runner.run(directory: "/private/tmp", executable: tmux, arguments: ["has-session", "-t", "=" + id], timeout: 5)
            #expect(alive.exitStatus == 0)
        } catch {
            await pty.close()
            _ = await runner.run(directory: "/private/tmp", executable: tmux, arguments: ["kill-session", "-t", "=" + id], timeout: 5)
            throw error
        }
        _ = await runner.run(directory: "/private/tmp", executable: tmux, arguments: ["kill-session", "-t", "=" + id], timeout: 5)
    }

    @Test func pairedWireTerminalReopensTheSameHostSession() async throws {
        let tmux = "/opt/homebrew/bin/tmux"
        guard FileManager.default.isExecutableFile(atPath: tmux) else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = CommandRunner()
        let session = MachineSession(id: "cmux-agent-" + UUID().uuidString.lowercased(), title: "Wire fixture", project: "/private/tmp", agent: .codex)
        let started = await runner.run(directory: "/private/tmp", executable: tmux, arguments: [
            "new-session", "-d", "-s", session.id, "-e", "CMUX_MACHINE_TITLE=" + session.title,
            "-e", "CMUX_MACHINE_PROJECT=" + session.project, "-e", "CMUX_MACHINE_AGENT=codex", "/bin/sh"
        ], timeout: 5)
        try #require(started.exitStatus == 0)
        let trust = try MachineTrustStore(url: directory.appendingPathComponent("trust.json"))
        let service = MachineSessionService(runner: runner, directory: "/private/tmp")
        let host = MachineSharingHost(service: service, trust: trust, name: "Wire", allowLoopback: true)
        do {
            try await host.start(address: "127.0.0.1")
            let invitation = try await trust.invite(host: "127.0.0.1", name: "Wire")
            var endpoint = invitation.endpoint
            let client = MachineNetworkClient(allowLoopback: true)
            let paired = try await client.request(.init(operation: .pair, name: "Viewer"), endpoint: endpoint)
            endpoint.credential = try #require(paired.credential)
            for pass in 0..<2 {
                let listed = try await client.request(.init(operation: .list), endpoint: endpoint)
                #expect(listed.sessions?.contains(session) == true)
                let channel = try MachineChannel(endpoint: endpoint, allowLoopback: true)
                let deadline = Task { try await Task.sleep(for: .seconds(10)); await channel.close() }
                do {
                    try await channel.send(.init(operation: .attach, serverID: endpoint.serverID, credential: endpoint.credential, session: session, columns: 110, rows: 35))
                    #expect(try await channel.receive().operation == .result)
                    var output = "", sent = false
                    while true {
                        let message = try await channel.receive()
                        output += String(decoding: message.bytes ?? Data(), as: UTF8.self)
                        if !sent && output.contains("sh-3.2$") {
                            sent = true
                            try await channel.send(.init(operation: .input, bytes: Data("printf 'WIRE_%s\\n' PASS\(pass)\r".utf8)))
                        }
                        if output.contains("WIRE_PASS\(pass)") { break }
                    }
                    await channel.close()
                    deadline.cancel()
                } catch { deadline.cancel(); await channel.close(); throw error }
            }
            _ = try await client.request(.init(operation: .end, session: session), endpoint: endpoint)
            #expect(try await client.request(.init(operation: .list), endpoint: endpoint).sessions?.contains(session) == false)
            try await host.stop()
        } catch {
            try? await host.stop()
            _ = await runner.run(directory: "/private/tmp", executable: tmux, arguments: ["kill-session", "-t", "=" + session.id], timeout: 5)
            throw error
        }
    }
}
