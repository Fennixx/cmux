import Foundation
import Darwin

/// Owns only an attached tmux viewer; closing it never kills the detached agent.
actor MachinePTY {
    private var master: Int32?
    private var process: Process?
    // DispatchSource is the platform's readiness API for a PTY descriptor, not a state lock.
    private var source: DispatchSourceRead?
    private var output: AsyncThrowingStream<Data, Error>.Continuation?

    func start(command: String, columns: UInt16, rows: UInt16) throws -> AsyncThrowingStream<Data, Error> {
        var masterFD: Int32 = -1, slaveFD: Int32 = -1
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&masterFD, &slaveFD, nil, nil, &size) == 0 else { throw POSIXError(.EIO) }
        let slave = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)
        let child = Process()
        // script establishes a controlling terminal and propagates window size to its child.
        child.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        child.arguments = ["-q", "/dev/null", "/bin/sh", "-c", command]
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("CMUX_") || key == "TMUX" { environment.removeValue(forKey: key) }
        environment["TERM"] = "xterm-256color"
        child.environment = environment
        child.standardInput = slave; child.standardOutput = slave; child.standardError = slave
        do { try child.run() } catch { Darwin.close(masterFD); throw error }
        try? slave.close()
        _ = fcntl(masterFD, F_SETFL, O_NONBLOCK)
        master = masterFD; process = child
        let stream = AsyncThrowingStream<Data, Error>(bufferingPolicy: .bufferingOldest(128)) { self.output = $0 }
        let source = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: .global(qos: .userInitiated))
        source.setEventHandler { [weak self] in Task { await self?.readReady() } }
        // Closing only after source cancellation prevents descriptor reuse by a queued event.
        let ownedFD = masterFD
        source.setCancelHandler { Darwin.close(ownedFD) }
        self.source = source
        source.resume()
        return stream
    }

    func input(_ data: Data) throws {
        guard let master, data.count <= 4096 else { throw MachineSessionError.invalidInput }
        let count = data.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
        guard count == data.count else { throw POSIXError(.EIO) }
    }

    func resize(columns: UInt16, rows: UInt16) throws {
        guard let master, (2...1000).contains(columns), (2...1000).contains(rows) else { throw MachineSessionError.invalidInput }
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        guard ioctl(master, TIOCSWINSZ, &size) == 0 else { throw POSIXError(.EIO) }
        if let process, process.isRunning { kill(process.processIdentifier, SIGWINCH) }
    }

    func close() {
        master = nil
        source?.cancel(); source = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        output?.finish(); output = nil
    }

    private func readReady() {
        guard let master else { return }
        var buffer = [UInt8](repeating: 0, count: 16384)
        let count = Darwin.read(master, &buffer, buffer.count)
        if count > 0 {
            if case .dropped = output?.yield(Data(buffer.prefix(count))) {
                output?.finish(throwing: POSIXError(.ENOBUFS)); close()
            }
        } else if count == 0 || (errno != EAGAIN && errno != EINTR) { close() }
    }
}
