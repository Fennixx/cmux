import Foundation
import Darwin

/// Adapts the client's existing terminal without allowing descriptor callbacks to mutate shared state.
actor MachineTerminalIO {
    private var original: termios?
    private var originalFlags: Int32?
    private var inputSource: DispatchSourceRead?
    private var resizeSource: DispatchSourceSignal?
    private var continuation: AsyncThrowingStream<MachineWireMessage, Error>.Continuation?

    func start() throws -> AsyncThrowingStream<MachineWireMessage, Error> {
        var settings = termios()
        guard tcgetattr(STDIN_FILENO, &settings) == 0 else { throw POSIXError(.ENOTTY) }
        original = settings
        originalFlags = fcntl(STDIN_FILENO, F_GETFL)
        _ = fcntl(STDIN_FILENO, F_SETFL, (originalFlags ?? 0) | O_NONBLOCK)
        cfmakeraw(&settings)
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &settings) == 0 else { throw POSIXError(.ENOTTY) }
        let stream = AsyncThrowingStream<MachineWireMessage, Error>(bufferingPolicy: .bufferingOldest(128)) { self.continuation = $0 }
        // Dispatch sources are the macOS readiness/signal adapters; actor isolation owns their state.
        let input = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .global())
        input.setEventHandler { [weak self] in Task { await self?.readInput() } }
        inputSource = input; input.resume()
        signal(SIGWINCH, SIG_IGN)
        let resize = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
        resize.setEventHandler { [weak self] in Task { await self?.resized() } }
        resizeSource = resize; resize.resume()
        resized()
        return stream
    }

    func stop() {
        inputSource?.cancel(); inputSource = nil
        resizeSource?.cancel(); resizeSource = nil
        continuation?.finish(); continuation = nil
        if var original { _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &original) }
        original = nil
        if let originalFlags { _ = fcntl(STDIN_FILENO, F_SETFL, originalFlags) }
        originalFlags = nil
    }

    func size() -> (UInt16, UInt16) {
        var size = winsize()
        _ = ioctl(STDIN_FILENO, TIOCGWINSZ, &size)
        return (min(max(size.ws_col, 2), 1000), min(max(size.ws_row, 2), 1000))
    }

    private func resized() {
        let (columns, rows) = size()
        yield(.init(operation: .resize, columns: columns, rows: rows))
    }

    private func readInput() {
        guard continuation != nil else { return }
        var data = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(STDIN_FILENO, &data, data.count)
        if count > 0 { yield(.init(operation: .input, bytes: Data(data.prefix(count)))) }
        else if count == 0 || (errno != EINTR && errno != EAGAIN) { continuation?.finish(); continuation = nil }
    }

    private func yield(_ message: MachineWireMessage) {
        if case .dropped = continuation?.yield(message) { continuation?.finish(throwing: POSIXError(.ENOBUFS)); continuation = nil }
    }
}
