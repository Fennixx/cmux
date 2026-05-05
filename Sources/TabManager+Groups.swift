import Foundation

extension TabManager {
    @discardableResult
    func createGroup(name: String, color: String? = nil) -> WorkspaceGroup {
        let group = WorkspaceGroup(name: name, color: color)
        groups.append(group)
        bumpGroupRevision()
        return group
    }

    func deleteGroup(id: UUID) {
        groups.removeAll { $0.id == id }
        bumpGroupRevision()
    }

    func renameGroup(id: UUID, name: String) {
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[idx].name = name
        bumpGroupRevision()
    }

    func setGroupColor(id: UUID, color: String?) {
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[idx].color = color
        bumpGroupRevision()
    }

    func setGroupCollapsed(id: UUID, collapsed: Bool) {
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[idx].isCollapsed = collapsed
        bumpGroupRevision()
    }

    func addWorkspaceToGroup(groupId: UUID, workspaceId: UUID) {
        for i in groups.indices {
            groups[i].remove(workspaceId)
        }
        guard let idx = groups.firstIndex(where: { $0.id == groupId }) else { return }
        groups[idx].add(workspaceId)
        bumpGroupRevision()
    }

    func removeWorkspaceFromGroup(groupId: UUID, workspaceId: UUID) {
        guard let idx = groups.firstIndex(where: { $0.id == groupId }) else { return }
        groups[idx].remove(workspaceId)
        bumpGroupRevision()
    }

    func groupForWorkspace(_ workspaceId: UUID) -> WorkspaceGroup? {
        groups.first { $0.contains(workspaceId) }
    }

    func resolveGroup(nameOrRef: String) -> WorkspaceGroup? {
        if let group = groups.first(where: { $0.name == nameOrRef }) {
            return group
        }
        if let uuid = UUID(uuidString: nameOrRef) {
            return groups.first { $0.id == uuid }
        }
        return nil
    }

    struct SidebarLayoutSection {
        let group: WorkspaceGroup?
        let workspaces: [Workspace]
    }

    func sidebarLayout() -> [SidebarLayoutSection] {
        let tabById = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let groupedIds = Set(groups.flatMap(\.workspaceIds))

        var sections: [SidebarLayoutSection] = []

        let pinnedUngrouped = tabs.filter { $0.isPinned && !groupedIds.contains($0.id) }
        if !pinnedUngrouped.isEmpty {
            sections.append(SidebarLayoutSection(group: nil, workspaces: pinnedUngrouped))
        }

        for group in groups {
            let members = group.workspaceIds.compactMap { tabById[$0] }
            if !members.isEmpty {
                let pinned = members.filter(\.isPinned)
                let unpinned = members.filter { !$0.isPinned }
                sections.append(SidebarLayoutSection(group: group, workspaces: pinned + unpinned))
            }
        }

        let unpinnedUngrouped = tabs.filter { !$0.isPinned && !groupedIds.contains($0.id) }
        if !unpinnedUngrouped.isEmpty {
            sections.append(SidebarLayoutSection(group: nil, workspaces: unpinnedUngrouped))
        }

        return sections
    }

    func cleanupGroupsForRemovedWorkspace(_ workspaceId: UUID) {
        var changed = false
        for i in groups.indices {
            if groups[i].contains(workspaceId) {
                groups[i].remove(workspaceId)
                changed = true
            }
        }
        if changed { bumpGroupRevision() }
    }

    private func bumpGroupRevision() {
        groupStructureRevision &+= 1
    }
}
