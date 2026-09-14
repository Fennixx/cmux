import AppKit
import SwiftUI
import CmuxFoundation
import CmuxMachineSessions

/// Composes the machine-session feature and owns its auxiliary window.
@MainActor
final class MachineSessionsWindowController {
    private var window: NSWindow?
    private var model: MachineSessionsModel?
    private var localWorkspaces: [String: UUID] = [:]
    private let service: MachineSessionService
    private let catalogURL: URL

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let bundleID = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app"
        let directory = home.appendingPathComponent(".config/cmux/\(bundleID)")
        catalogURL = directory.appendingPathComponent("machines.json")
        let name = Host.current().localizedName ?? String(localized: "machines.local", defaultValue: "This computer")
        service = MachineSessionService(runner: CommandRunner(), directory: home.path,
            bundledBin: Bundle.main.resourceURL?.appendingPathComponent("machine/bin").path)
        var host: MachineSharingHost?
        var hostError: Error?
        do { host = try MachineSharingHost(service: service, stateURL: directory.appendingPathComponent("machine-trust.json"), name: name) }
        catch { hostError = error }
        let model = MachineSessionsModel(
            service: service,
            repository: MachineProfileRepository(url: catalogURL),
            localProfile: MachineProfile(
                name: name,
                destination: "", projects: [home.path]
            ),
            sharingHost: host,
            tailscaleAddress: {
                let data = try await SystemTailscaleStatusProvider().statusJSON()
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let own = object?["Self"] as? [String: Any]
                guard object?["BackendState"] as? String == "Running",
                      let address = (own?["TailscaleIPs"] as? [String])?.first(where: MachineEndpoint.isTailnet)
                else { throw MachineSessionError.connection(String(localized: "machines.tailscaleRequired", defaultValue: "Connect this Mac to Tailscale, then try again.")) }
                return address
            },
            openSession: { [weak self] machine, session in
                guard let self, let appDelegate = AppDelegate.shared else { return }
                try await self.open(machine: machine, session: session, appDelegate: appDelegate)
            }
        )
        self.model = model
        if let hostError { model.error = hostError.localizedDescription }
        Task { await model.restoreSharing() }
    }

    func show(appDelegate: AppDelegate) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            if let model, !model.busy { Task { await model.refresh() } }
            return
        }
        guard let model else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 670), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = String(localized: "machines.title", defaultValue: "Agent Sessions")
        window.identifier = NSUserInterfaceItemIdentifier("cmux.machine-sessions")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MachineSessionsView(model: model))
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    private func open(machine: MachineProfile, session: MachineSession, appDelegate: AppDelegate) async throws {
        if appDelegate.activeTabManagerForCommands() == nil { _ = appDelegate.createMainWindow() }
        guard var manager = appDelegate.activeTabManagerForCommands() else { throw MachineSessionError.connection("No active cmux window") }
        if machine.isLocal || machine.endpoint != nil {
            let key = machine.id.uuidString + ":" + session.id
            if let id = localWorkspaces[key], let owner = appDelegate.tabManagerFor(tabId: id) {
                manager = owner
                manager.selectedTabId = id
            } else {
                let command: String
                if machine.endpoint != nil {
                    guard let helper = Bundle.main.resourceURL?.appendingPathComponent("machine/bin/cmux-machine"),
                          FileManager.default.isExecutableFile(atPath: helper.path) else { throw MachineSessionError.connection("Missing bundled terminal bridge.") }
                    command = [helper.path, catalogURL.path, machine.id.uuidString, session.id].map(MachineSessionCommands().quote).joined(separator: " ")
                } else { command = try await service.localAttachCommand(session) }
                guard let workspace = manager.addWorkspaceIfActive(
                    title: session.title + " · " + machine.name,
                    workingDirectory: machine.isLocal ? session.project : FileManager.default.homeDirectoryForCurrentUser.path,
                    initialTerminalCommand: command,
                    autoWelcomeIfNeeded: false
                ) else { throw MachineSessionError.sessionMissing }
                localWorkspaces[key] = workspace.id
            }
        } else {
            let host = RemoteTmuxHost(destination: machine.destination)
            let controller = appDelegate.remoteTmuxController
            try await controller.transport(for: host).assertMinimumTmuxVersion(checkClientWhenNoServer: false)
            try await controller.ensureControlMasterReadyForBurst(host: host)
            _ = try controller.mirrorSession(host: host, sessionName: session.id, into: manager)
            if let mirror = controller.sessionMirror(host: host, sessionName: session.id) {
                mirror.preserveSessionOnClose = true
                mirror.agentSessionDisplayTitle = session.title + " · " + machine.name
                if let workspaceID = mirror.mirroredWorkspaceId {
                    if let owner = appDelegate.tabManagerFor(tabId: workspaceID) { manager = owner }
                    manager.selectedTabId = workspaceID
                    // A custom title would rename the remote tmux session and destroy its stable ID.
                    mirror.applySessionNameToWorkspaceTitle(session.id)
                }
                guard await mirror.connection.waitUntilConnected() else {
                    throw MachineSessionError.connection("The tmux control connection ended before attachment.")
                }
            }
        }
        if let windowID = appDelegate.windowId(for: manager) { _ = appDelegate.focusMainWindow(windowId: windowID) }
    }
}
