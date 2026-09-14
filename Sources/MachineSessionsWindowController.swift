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

    func show(appDelegate: AppDelegate) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            if let model, !model.busy { Task { await model.refresh() } }
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let bundleID = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app"
        let model = MachineSessionsModel(
            service: MachineSessionService(runner: CommandRunner(), directory: home.path),
            repository: MachineProfileRepository(url: home.appendingPathComponent(".config/cmux/\(bundleID)/machines.json")),
            localProfile: MachineProfile(
                name: Host.current().localizedName ?? String(localized: "machines.local", defaultValue: "This computer"),
                destination: "", projects: [home.path]
            ),
            openSession: { [weak self, weak appDelegate] machine, session in
                guard let self, let appDelegate else { return }
                try await self.open(machine: machine, session: session, appDelegate: appDelegate)
            }
        )
        self.model = model
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
        if machine.isLocal {
            if let id = localWorkspaces[session.id], let owner = appDelegate.tabManagerFor(tabId: id) {
                manager = owner
                manager.selectedTabId = id
            } else {
                let command = try MachineSessionCommands().attach(machine: machine, session: session)
                guard let workspace = manager.addWorkspaceIfActive(
                    title: session.title + " · " + machine.name,
                    workingDirectory: session.project,
                    initialTerminalCommand: command,
                    autoWelcomeIfNeeded: false
                ) else { throw MachineSessionError.sessionMissing }
                localWorkspaces[session.id] = workspace.id
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
