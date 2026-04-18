import Foundation

struct AsyncProcessResult: Sendable {
    let terminationStatus: Int32
    let stdout: Data
    let stderr: Data

    var stdoutString: String {
        String(data: stdout, encoding: .utf8) ?? ""
    }

    var stderrString: String {
        String(data: stderr, encoding: .utf8) ?? ""
    }

    var combinedMessage: String {
        [stderrString, stdoutString]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

enum AsyncProcessRunnerError: LocalizedError {
    case launchFailed(String)
    case timedOut(command: String, timeout: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let message):
            return message
        case .timedOut(let command, let timeout):
            return "\(command) 执行超时（\(Int(timeout))s）"
        }
    }
}

final class AsyncProcessRunner: @unchecked Sendable {
    static let shared = AsyncProcessRunner()

    private init() {}

    func run(
        executableURL: URL,
        arguments: [String] = [],
        currentDirectoryURL: URL? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> AsyncProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let stdoutCollector = ProcessPipeBuffer()
            let stderrCollector = ProcessPipeBuffer()
            let state = ProcessContinuationState(continuation: continuation)

            process.executableURL = executableURL
            process.arguments = arguments
            process.currentDirectoryURL = currentDirectoryURL
            process.environment = environment
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            stdoutCollector.attach(to: stdoutPipe)
            stderrCollector.attach(to: stderrPipe)

            process.terminationHandler = { terminatedProcess in
                let stdout = stdoutCollector.finishReading(from: stdoutPipe)
                let stderr = stderrCollector.finishReading(from: stderrPipe)
                let result = AsyncProcessResult(
                    terminationStatus: terminatedProcess.terminationStatus,
                    stdout: stdout,
                    stderr: stderr
                )
                state.resume(with: .success(result))
            }

            do {
                try process.run()
            } catch {
                stdoutCollector.finishReading(from: stdoutPipe)
                stderrCollector.finishReading(from: stderrPipe)
                state.resume(
                    with: .failure(
                        AsyncProcessRunnerError.launchFailed(error.localizedDescription)
                    )
                )
                return
            }

            if let timeout, timeout > 0 {
                Task.detached(priority: .utility) {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    guard state.markTimedOut() else { return }
                    if process.isRunning {
                        process.terminate()
                    }
                    let stdout = stdoutCollector.finishReading(from: stdoutPipe)
                    let stderr = stderrCollector.finishReading(from: stderrPipe)
                    _ = stdout
                    _ = stderr
                    state.resume(
                        with: .failure(
                            AsyncProcessRunnerError.timedOut(
                                command: executableURL.lastPathComponent,
                                timeout: timeout
                            )
                        )
                    )
                }
            }
        }
    }
}

private final class ProcessPipeBuffer: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var buffer = Data()

    nonisolated func attach(to pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            lock.lock()
            buffer.append(chunk)
            lock.unlock()
        }
    }

    @discardableResult
    nonisolated func finishReading(from pipe: Pipe) -> Data {
        pipe.fileHandleForReading.readabilityHandler = nil
        let tail = pipe.fileHandleForReading.readDataToEndOfFile()
        lock.lock()
        buffer.append(tail)
        let data = buffer
        lock.unlock()
        return data
    }
}

private final class ProcessContinuationState: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var continuation: CheckedContinuation<AsyncProcessResult, Error>?
    nonisolated(unsafe) private var isCompleted = false

    init(continuation: CheckedContinuation<AsyncProcessResult, Error>) {
        self.continuation = continuation
    }

    nonisolated func markTimedOut() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !isCompleted
    }

    nonisolated func resume(with result: Result<AsyncProcessResult, Error>) {
        lock.lock()
        guard !isCompleted, let continuation else {
            lock.unlock()
            return
        }
        isCompleted = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}
