import Foundation

/// Persists the client-local computer catalog without storing SSH or provider secrets.
public actor MachineProfileRepository {
    private let url: URL

    /// Creates a repository at an explicit configuration path.
    /// - Parameter url: JSON catalog location; injectable for isolated tests and app tags.
    public init(url: URL) { self.url = url }

    /// Loads saved computers, returning an empty catalog only when no file exists.
    /// - Returns: Saved host profiles.
    /// - Throws: Read or decoding failures; damaged catalogs are never silently replaced.
    public func load() throws -> [MachineProfile] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([MachineProfile].self, from: Data(contentsOf: url))
    }

    /// Atomically saves host profiles.
    /// - Parameter profiles: Entire current catalog.
    /// - Throws: Encoding or filesystem errors.
    public func save(_ profiles: [MachineProfile]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profiles).write(to: url, options: .atomic)
    }
}
