import Foundation
import Observation
import CmuxMachineSessions

/// Owns the computer picker, persisted catalog, and one in-flight host operation.
@MainActor @Observable
final class MachineSessionsModel {
    var machines: [MachineProfile] = []
    var selectedID: UUID?
    var sessions: [MachineSession] = []
    var agents: [MachineAgent] = []
    var agent: MachineAgent = .claude
    var project = ""
    var title = ""
    var newMachineName = ""
    var newMachineDestination = ""
    var busy = false
    var connected = false
    var error: String?
    var catalogLoaded = false
    var sharing = false
    var pairingCode = ""
    private let sharingHost: MachineSharingHost?
    private let tailscaleAddress: @Sendable () async throws -> String
    private let network = MachineNetworkClient()
    private var generation = UUID()
    private var pendingLaunch: (machineID: UUID, session: MachineSession)?
    private let service: MachineSessionService
    private let repository: MachineProfileRepository
    private let localProfile: MachineProfile
    private let openSession: @MainActor (MachineProfile, MachineSession) async throws -> Void

    init(
        service: MachineSessionService,
        repository: MachineProfileRepository,
        localProfile: MachineProfile,
        sharingHost: MachineSharingHost? = nil,
        tailscaleAddress: @escaping @Sendable () async throws -> String = { throw MachineSessionError.invalidInput },
        openSession: @escaping @MainActor (MachineProfile, MachineSession) async throws -> Void
    ) {
        self.service = service
        self.repository = repository
        self.localProfile = localProfile
        self.sharingHost = sharingHost
        self.tailscaleAddress = tailscaleAddress
        self.openSession = openSession
    }

    var selectedMachine: MachineProfile? { machines.first { $0.id == selectedID } }

    func load() async {
        guard !catalogLoaded else { return }
        do {
            let saved = try await repository.load()
            machines = saved.isEmpty ? [localProfile] : saved
            catalogLoaded = true
            selectedID = machines.first?.id
            project = machines.first?.projects.first ?? ""
        } catch { self.error = error.localizedDescription }
    }

    func select(_ id: UUID) {
        guard !busy, id != selectedID else { return }
        selectedID = id
        project = selectedMachine?.projects.first ?? ""
        sessions = []
        connected = false
    }

    func refresh() async {
        guard let machine = selectedMachine else { return }
        let token = UUID()
        generation = token
        busy = true
        connected = false
        error = nil
        defer { if generation == token { busy = false } }
        do {
            let installed = try await service.probe(machine)
            let discovered = try await service.sessions(machine)
            guard generation == token, selectedID == machine.id else { return }
            agents = installed
            if !installed.contains(agent), let first = installed.first { agent = first }
            sessions = discovered
            connected = true
            if installed.isEmpty { error = MachineSessionError.agentMissing.localizedDescription }
        } catch {
            guard generation == token else { return }
            sessions = []
            agents = []
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }

    func addMachine() async {
        guard catalogLoaded, !busy else { return }
        let code = newMachineDestination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            let machine = try await network.pair(code: code, clientName: localProfile.name)
            let updated = machines.filter { $0.endpoint?.serverID != machine.endpoint?.serverID } + [machine]
            try await repository.save(updated)
            machines = updated
            newMachineName = ""
            newMachineDestination = ""
            busy = false
            select(machine.id)
        } catch { self.error = error.localizedDescription }
    }

    func restoreSharing() async {
        guard let sharingHost, await sharingHost.shouldRestoreSharing() else { return }
        do {
            try await sharingHost.start(address: tailscaleAddress())
            sharing = true
        } catch { self.error = error.localizedDescription }
    }

    func share() async {
        guard let sharingHost, !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            try await sharingHost.start(address: tailscaleAddress())
            sharing = true
            pairingCode = try await sharingHost.createCode()
        } catch { self.error = error.localizedDescription }
    }

    func stopSharing() async {
        guard let sharingHost, !busy else { return }
        busy = true
        defer { busy = false }
        do { try await sharingHost.stop(); sharing = false; pairingCode = "" }
        catch { self.error = error.localizedDescription }
    }

    func revokeDevices() async {
        guard let sharingHost, !busy else { return }
        busy = true
        defer { busy = false }
        do { try await sharingHost.revokeAll(); pairingCode = "" }
        catch { self.error = error.localizedDescription }
    }

    func removeMachine() async {
        guard let machine = selectedMachine, !machine.isLocal, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let updated = machines.filter { $0.id != machine.id }
            try await repository.save(updated)
            machines = updated
            selectedID = machines.first?.id
            project = machines.first?.projects.first ?? ""
            sessions = []
        } catch { self.error = error.localizedDescription }
    }

    func create() async {
        guard let machine = selectedMachine, !busy, connected, agents.contains(agent) else { return }
        busy = true
        error = nil
        defer { busy = false }
        let path = project.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let proposed = MachineSession(
            id: "cmux-agent-" + UUID().uuidString.lowercased(),
            title: label.isEmpty ? URL(fileURLWithPath: path).lastPathComponent + " · " + agent.displayName : label,
            project: path, agent: agent
        )
        let session: MachineSession
        if let pending = pendingLaunch, pending.machineID == machine.id,
           pending.session.project == proposed.project, pending.session.title == proposed.title,
           pending.session.agent == proposed.agent {
            session = pending.session
        } else {
            session = proposed
        }
        pendingLaunch = (machine.id, session)
        do {
            try await service.create(session, on: machine)
            // Publish the created identity before later persistence/attach can fail. Retrying
            // Open never launches a second agent after a lost client connection.
            sessions.removeAll { $0.id == session.id }
            sessions.insert(session, at: 0)
            var updated = machines
            if let index = updated.firstIndex(where: { $0.id == machine.id }) {
                updated[index].projects = [path] + updated[index].projects.filter { $0 != path }.prefix(30)
            }
            try await repository.save(updated)
            machines = updated
            try await openSession(machine, session)
            pendingLaunch = nil
            title = ""
        } catch { self.error = error.localizedDescription }
    }

    func open(_ session: MachineSession) async {
        guard let machine = selectedMachine, !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let current = try await service.sessions(machine)
            sessions = current
            guard current.contains(where: { $0.id == session.id }) else { throw MachineSessionError.sessionMissing }
            try await openSession(machine, session)
        } catch { self.error = error.localizedDescription }
    }

    func end(_ session: MachineSession) async {
        guard let machine = selectedMachine, !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await service.end(session, on: machine)
            sessions = try await service.sessions(machine)
        } catch { self.error = error.localizedDescription }
    }
}
