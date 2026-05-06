import Foundation

/// Identifies a GitLab project by host and full project path.
/// Supports gitlab.com plus self-hosted instances and subgroups.
struct GitLabProjectIdentity: Hashable, Sendable {
    let host: String
    let projectPath: String

    /// Slug used to key the candidate map alongside GitHub `owner/repo` slugs.
    /// Prefixed so the fetch dispatch can tell providers apart without parsing remote URLs again.
    var slug: String {
        "gitlab://\(host)/\(projectPath)"
    }

    /// Percent-encoded project path suitable for `/api/v4/projects/:id`.
    var apiProjectIdentifier: String {
        projectPath
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            ?? projectPath.replacingOccurrences(of: "/", with: "%2F")
    }
}

extension GitLabProjectIdentity {
    static let slugPrefix = "gitlab://"

    static func fromSlug(_ slug: String) -> GitLabProjectIdentity? {
        guard slug.hasPrefix(slugPrefix) else { return nil }
        let body = String(slug.dropFirst(slugPrefix.count))
        guard let firstSlash = body.firstIndex(of: "/") else { return nil }
        let host = String(body[..<firstSlash])
        let path = String(body[body.index(after: firstSlash)...])
        guard !host.isEmpty, !path.isEmpty else { return nil }
        return GitLabProjectIdentity(host: host, projectPath: path)
    }
}

enum GitLabRemoteParser {
    /// Heuristic GitLab host detection. Treats anything containing "gitlab" in the host name as a
    /// GitLab instance to support self-hosted deployments (e.g. `gitlab.orfeus-space.com`).
    static func looksLikeGitLabHost(_ host: String) -> Bool {
        host.lowercased().contains("gitlab")
    }

    static func projectIdentity(fromRemoteURL remoteURL: String) -> GitLabProjectIdentity? {
        let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // SCP-style: git@host:group/proj.git
        if trimmed.contains("@") && trimmed.contains(":") && !trimmed.hasPrefix("http") && !trimmed.hasPrefix("ssh://") && !trimmed.hasPrefix("git://") {
            let afterAt = trimmed.split(separator: "@", maxSplits: 1).last.map(String.init) ?? ""
            let parts = afterAt.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            let host = parts[0]
            guard looksLikeGitLabHost(host) else { return nil }
            return identity(host: host, rawPath: parts[1])
        }

        guard let url = URL(string: trimmed),
              let host = url.host?.lowercased() else {
            return nil
        }

        // ssh://git@host/group/proj.git, https://host/group/proj.git, git://host/group/proj.git
        guard looksLikeGitLabHost(host) else { return nil }
        return identity(host: host, rawPath: url.path)
    }

    private static func identity(host: String, rawPath: String) -> GitLabProjectIdentity? {
        var path = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty else { return nil }
        if path.hasSuffix(".git") {
            path.removeLast(4)
        }
        guard !path.isEmpty, path.contains("/") else { return nil }
        return GitLabProjectIdentity(host: host, projectPath: path)
    }
}

/// Single merge request entry in the cache. Mirrors the shape of the GitHub probe item so the
/// existing apply path can stay agnostic, but encodes a few GitLab-specific fields used elsewhere.
struct GitLabMergeRequestProbeItem: Equatable, Sendable {
    let iid: Int
    let state: String
    let webURL: String
    let updatedAt: String?
    let mergedAt: String?
    let sourceBranch: String?
    let targetBranch: String?
}

/// JSON shape returned by `glab api projects/:id/merge_requests`.
struct GitLabMergeRequestRESTItem: Decodable, Sendable {
    let iid: Int
    let state: String
    let web_url: String
    let updated_at: String?
    let merged_at: String?
    let source_branch: String?
    let target_branch: String?
}

enum GitLabFetcher {
    /// Run `glab api ...` and return raw stdout. Relies on glab's per-host auth from
    /// `~/.config/glab-cli/config.yml`, the keyring, or `GITLAB_TOKEN`.
    static func runGlabAPI(
        host: String,
        endpoint: String,
        timeout: TimeInterval = 6.0
    ) async -> Data? {
        let arguments = ["api", "--hostname", host, endpoint]
        return await runGlabRaw(arguments: arguments, timeout: timeout)
    }

    /// Diagnostic helper: confirms whether the process spawn machinery itself works.
    /// Spawns `/bin/echo` so the result has nothing to do with glab, network, or auth.
    static func runEchoSmokeTest() async -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/echo")
        process.arguments = ["smoke"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice
        return await withCheckedContinuation { continuation in
            var didResume = false
            let resumeOnce: (Data?) -> Void = { value in
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: value)
            }
            let timeoutItem = DispatchWorkItem {
#if DEBUG
                cmuxDebugLog("gitlab.smoke.echo.timeout")
#endif
                if process.isRunning { process.terminate() }
                resumeOnce(nil)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0, execute: timeoutItem)
            process.terminationHandler = { proc in
                timeoutItem.cancel()
                let data = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
#if DEBUG
                cmuxDebugLog("gitlab.smoke.echo.terminate status=\(proc.terminationStatus) bytes=\(data.count)")
#endif
                resumeOnce(data)
            }
            do {
                try process.run()
            } catch {
                timeoutItem.cancel()
#if DEBUG
                cmuxDebugLog("gitlab.smoke.echo.spawnFail error=\(error)")
#endif
                resumeOnce(nil)
            }
        }
    }

    /// Multi-page fetch of merge requests for a single project. Pages stop early when fewer items
    /// than perPage come back (last page) or when the page limit is hit.
    static func fetchProjectMergeRequests(
        identity: GitLabProjectIdentity,
        perPage: Int = 100,
        pageLimit: Int = 2,
        timeout: TimeInterval = 6.0
    ) async -> [GitLabMergeRequestProbeItem]? {
        var collected: [GitLabMergeRequestProbeItem] = []
        var page = 1
        while page <= pageLimit {
            let endpoint = "projects/\(identity.apiProjectIdentifier)/merge_requests?state=all&order_by=updated_at&sort=desc&per_page=\(perPage)&page=\(page)"
            guard let data = await runGlabAPI(host: identity.host, endpoint: endpoint, timeout: timeout) else {
                return nil
            }
            let decoder = JSONDecoder()
            guard let items = try? decoder.decode([GitLabMergeRequestRESTItem].self, from: data) else {
                return nil
            }
            collected.append(contentsOf: items.map(probeItem))
            if items.count < perPage {
                break
            }
            page += 1
        }
        return collected
    }

    private static func probeItem(from rest: GitLabMergeRequestRESTItem) -> GitLabMergeRequestProbeItem {
        GitLabMergeRequestProbeItem(
            iid: rest.iid,
            state: rest.state.lowercased(),
            webURL: rest.web_url,
            updatedAt: rest.updated_at,
            mergedAt: rest.merged_at,
            sourceBranch: rest.source_branch,
            targetBranch: rest.target_branch
        )
    }

    static func sidebarStatus(forStateLower stateLower: String) -> SidebarPullRequestStatus? {
        switch stateLower {
        case "opened", "open", "locked":
            return .open
        case "closed":
            return .closed
        case "merged":
            return .merged
        default:
            return nil
        }
    }

    /// Resolve glab's executable path, preferring an explicit env override and falling back to the
    /// well-known Homebrew location used in our setup.
    private static func glabExecutableURL() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["CMUX_GLAB_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let candidates = [
            "/opt/homebrew/bin/glab",
            "/usr/local/bin/glab",
            "\(NSHomeDirectory())/.local/bin/glab"
        ]
        let fileManager = FileManager.default
        return candidates
            .lazy
            .map { URL(fileURLWithPath: $0) }
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private static func runGlabRaw(arguments: [String], timeout: TimeInterval) async -> Data? {
        guard let executableURL = glabExecutableURL() else {
#if DEBUG
            cmuxDebugLog("gitlab.glab.exec.notFound")
#endif
            return nil
        }
#if DEBUG
        let envInfo = ProcessInfo.processInfo.environment
        cmuxDebugLog(
            "gitlab.glab.exec.spawn path=\(executableURL.path) " +
            "HOME=\(envInfo["HOME"] ?? "<missing>") " +
            "hasGLABTOKEN=\(envInfo["GLAB_TOKEN"] != nil) " +
            "hasGITLABTOKEN=\(envInfo["GITLAB_TOKEN"] != nil)"
        )
#endif
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = FileHandle.nullDevice

            // Provide a minimal environment so glab can read its config from $HOME/.config/glab-cli.
            var env = ProcessInfo.processInfo.environment
            if env["HOME"] == nil {
                env["HOME"] = NSHomeDirectory()
            }
            if env["PATH"] == nil {
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            }
            env["GLAB_NO_PROMPT"] = "1"
            env["NO_COLOR"] = "1"
            env["GLAB_NO_UPDATE_NOTIFIER"] = "1"
            process.environment = env

            // Drain stdout / stderr continuously so glab cannot block on write when its output
            // exceeds the OS pipe buffer (~64kB on macOS). Without this, large JSON responses
            // from `glab api` deadlock the child process and our terminationHandler never fires.
            let outBuffer = OutputBuffer()
            let errBuffer = OutputBuffer()
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    outBuffer.append(chunk)
                }
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    errBuffer.append(chunk)
                }
            }

            var didResume = false
            let resumeOnce: (Data?) -> Void = { value in
                guard !didResume else { return }
                didResume = true
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: value)
            }

            let timeoutItem = DispatchWorkItem {
                if process.isRunning {
#if DEBUG
                    let argSummary = arguments.suffix(2).joined(separator: " ")
                    cmuxDebugLog("gitlab.glab.exec.timeout args=\(argSummary)")
#endif
                    process.terminate()
                }
                resumeOnce(nil)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

            process.terminationHandler = { proc in
                timeoutItem.cancel()
                // Give the readabilityHandler a moment to drain final bytes before we tear down.
                let outData = outBuffer.snapshot()
                let errData = errBuffer.snapshot()
#if DEBUG
                cmuxDebugLog(
                    "gitlab.glab.exec.terminate status=\(proc.terminationStatus) " +
                    "reason=\(proc.terminationReason.rawValue) bytes=\(outData.count)"
                )
#endif
                if proc.terminationStatus == 0 {
#if DEBUG
                    cmuxDebugLog("gitlab.glab.exec.ok status=0 bytes=\(outData.count)")
#endif
                    resumeOnce(outData)
                } else {
#if DEBUG
                    let errSnippet = String(data: errData.prefix(160), encoding: .utf8) ?? "<binary>"
                    cmuxDebugLog("gitlab.glab.exec.fail status=\(proc.terminationStatus) err=\(errSnippet)")
#endif
                    resumeOnce(nil)
                }
            }

            do {
                try process.run()
            } catch {
#if DEBUG
                cmuxDebugLog("gitlab.glab.exec.spawnFail error=\(error)")
#endif
                timeoutItem.cancel()
                resumeOnce(nil)
            }
        }
    }
}

/// Thread-safe accumulator for child-process pipe output read via `readabilityHandler`.
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

extension GitLabRemoteParser {
    /// Parses `git remote -v` output and returns identities for any GitLab remotes found.
    static func projectIdentities(fromGitRemoteVOutput output: String) -> [GitLabProjectIdentity] {
        var seen = Set<GitLabProjectIdentity>()
        var ordered: [GitLabProjectIdentity] = []
        for line in output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let columns = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard columns.count >= 2 else { continue }
            let remoteURL = String(columns[1])
            guard let identity = projectIdentity(fromRemoteURL: remoteURL) else { continue }
            if seen.insert(identity).inserted {
                ordered.append(identity)
            }
        }
        return ordered
    }
}
