import SwiftUI
import CmuxMachineSessions

/// Computer selection and agent launch UI, shared by the File menu and workspace plus menu.
struct MachineSessionsView: View {
    @Bindable var model: MachineSessionsModel
    @State private var sessionToEnd: MachineSession?

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text(String(localized: "machines.computers", defaultValue: "Computers"))
                    .font(.title2.weight(.semibold))
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(model.machines) { machine in
                            Button { model.select(machine.id) } label: {
                                HStack {
                                    Image(systemName: machine.isLocal ? "laptopcomputer" : "desktopcomputer")
                                    VStack(alignment: .leading) {
                                        Text(verbatim: machine.name).fontWeight(.medium)
                                        Text(machine.isLocal ? String(localized: "machines.local", defaultValue: "This computer") : machine.destination)
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(10)
                                .background(model.selectedID == machine.id ? Color.accentColor.opacity(0.14) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain).disabled(model.busy)
                        }
                    }
                }
                Divider()
                Text(String(localized: "machines.add", defaultValue: "Add computer")).font(.headline)
                TextField(String(localized: "machines.name", defaultValue: "Name"), text: $model.newMachineName)
                TextField(String(localized: "machines.destination", defaultValue: "user@machine.tailnet.ts.net or SSH alias"), text: $model.newMachineDestination)
                Button(String(localized: "machines.save", defaultValue: "Save computer")) { Task { await model.addMachine() } }
                    .disabled(model.busy || !model.catalogLoaded || model.newMachineDestination.isEmpty)
                Text(String(localized: "machines.sshHelp", defaultValue: "Use a Tailscale address or an SSH alias pointing to it. Set up SSH key access once in Terminal; existing SSH configuration is respected."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .textFieldStyle(.roundedBorder)
            .padding(20).frame(width: 275)
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(localized: "machines.title", defaultValue: "Agent Sessions")).font(.largeTitle.weight(.semibold))
                        Text(model.selectedMachine?.name ?? "").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small) }
                    Button(String(localized: "machines.refresh", defaultValue: "Connect / Refresh")) { Task { await model.refresh() } }
                        .disabled(model.busy || model.selectedMachine == nil)
                }
                if let error = model.error {
                    ScrollView {
                        Text(verbatim: error).foregroundStyle(.red).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 90)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(String(localized: "machines.new", defaultValue: "New session")).font(.headline)
                        HStack {
                            TextField(String(localized: "machines.project", defaultValue: "Absolute project path on this computer"), text: $model.project)
                                .accessibilityIdentifier("machines.project")
                            if let projects = model.selectedMachine?.projects, !projects.isEmpty {
                                Menu(String(localized: "machines.recent", defaultValue: "Recent")) {
                                    ForEach(projects, id: \.self) { path in Button(path) { model.project = path } }
                                }.fixedSize()
                            }
                        }
                        TextField(String(localized: "machines.sessionName", defaultValue: "Session name (optional)"), text: $model.title)
                        Picker(String(localized: "machines.agent", defaultValue: "Agent"), selection: $model.agent) {
                            ForEach(MachineAgent.allCases) { agent in
                                Text(verbatim: agent.displayName).tag(agent).disabled(!model.agents.contains(agent))
                            }
                        }.pickerStyle(.segmented)
                        HStack {
                            Text(String(localized: "machines.hostHelp", defaultValue: "Files and agent credentials stay on the selected computer."))
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button(String(localized: "machines.start", defaultValue: "Start session")) { Task { await model.create() } }
                                .buttonStyle(.borderedProminent)
                                .disabled(!model.connected || model.busy || !model.agents.contains(model.agent) || !model.project.hasPrefix("/"))
                                .accessibilityIdentifier("machines.start")
                        }
                    }.padding(8)
                }.disabled(model.busy)
                HStack {
                    Text(String(localized: "machines.existing", defaultValue: "Sessions on this computer")).font(.headline)
                    Spacer()
                    if model.connected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                }
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(model.sessions) { session in
                            HStack(spacing: 12) {
                                Image(systemName: "terminal")
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(verbatim: session.title).fontWeight(.medium)
                                    Text(verbatim: session.agent.displayName + " · " + session.project)
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Button(String(localized: "machines.open", defaultValue: "Open")) { Task { await model.open(session) } }
                                Button(String(localized: "machines.end", defaultValue: "End"), role: .destructive) { sessionToEnd = session }
                            }.padding(10).background(.quaternary.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        if model.sessions.isEmpty, model.connected {
                            Text(String(localized: "machines.empty", defaultValue: "No agent sessions yet. Start one above."))
                                .foregroundStyle(.secondary).padding(20)
                        }
                    }
                }.disabled(model.busy)
                Text(String(localized: "machines.persistence", defaultValue: "Closing a session workspace disconnects this viewer. Use End to stop the agent. The host must stay awake."))
                    .font(.caption).foregroundStyle(.secondary)
                if model.selectedMachine?.isLocal == false {
                    Button(String(localized: "machines.remove", defaultValue: "Forget computer"), role: .destructive) { Task { await model.removeMachine() } }
                        .disabled(model.busy)
                }
            }
            .textFieldStyle(.roundedBorder).padding(24).frame(minWidth: 570)
        }
        .frame(minWidth: 850, minHeight: 600)
        .task { await model.load() }
        .task(id: model.selectedID) { await model.refresh() }
        .confirmationDialog(String(localized: "machines.endConfirm", defaultValue: "End this session and stop its running processes?"), isPresented: Binding(
            get: { sessionToEnd != nil }, set: { if !$0 { sessionToEnd = nil } }
        ), titleVisibility: .visible) {
            if let session = sessionToEnd {
                Button(String(localized: "machines.end", defaultValue: "End"), role: .destructive) { Task { await model.end(session) } }
            }
        }
    }
}
