import Foundation

final class KnowledgeBaseSidecarManager {
    static let shared = KnowledgeBaseSidecarManager()

    private let queue = DispatchQueue(label: "SkyAgent.KnowledgeBaseSidecarManager", qos: .utility)
    private let fileManager: FileManager
    private let runtimeDir: URL
    private var launchInProgress = false
    private var trackedProcesses: [pid_t: Process] = [:]

    private init(
        fileManager: FileManager = .default,
        runtimeDir: URL = AppStoragePaths.knowledgeSidecarRuntimeDir
    ) {
        self.fileManager = fileManager
        self.runtimeDir = runtimeDir
        AppStoragePaths.prepareDataDirectories()
    }

    var pidFileURL: URL {
        runtimeDir.appendingPathComponent("sidecar.pid", isDirectory: false)
    }

    func status() async -> KnowledgeBaseSidecarStatus {
        switch await KnowledgeBaseSidecarClient.shared.status() {
        case .success(let status):
            return status
        case .failure(let error):
            return KnowledgeBaseSidecarStatus(status: "offline", message: error.description, version: nil)
        }
    }

    func isRunning() -> Bool {
        queue.sync {
            isRunningLocked()
        }
    }

    func stop() {
        queue.sync {
            guard let pid = readPIDLocked() else { return }
            launchInProgress = false
            if let process = trackedProcesses.removeValue(forKey: pid) {
                if process.isRunning {
                    process.terminate()
                }
            } else {
                _ = kill(pid, SIGTERM)
            }
            try? fileManager.removeItem(at: pidFileURL)
        }
    }

    func start() {
        queue.sync {
            startLocked()
        }
    }

    private func startLocked() {
        guard !isRunningLocked() else {
            launchInProgress = false
            return
        }
        guard !launchInProgress else { return }
        launchInProgress = true
        AppStoragePaths.prepareDataDirectories()

        let sidecarScript = AppStoragePaths.knowledgeSidecarDir.appendingPathComponent("sidecar.py", isDirectory: false)
        guard fileManager.fileExists(atPath: sidecarScript.path) else {
            launchInProgress = false
            return
        }

        let stalePID = readPIDLocked()
        if stalePID != nil {
            try? fileManager.removeItem(at: pidFileURL)
        }

        let logFile = AppStoragePaths.knowledgeSidecarLogsDir.appendingPathComponent("sidecar.log", isDirectory: false)
        if !fileManager.fileExists(atPath: logFile.path) {
            fileManager.createFile(atPath: logFile.path, contents: nil)
        }

        guard let logHandle = try? FileHandle(forWritingTo: logFile) else {
            launchInProgress = false
            return
        }

        do {
            try logHandle.seekToEnd()

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [sidecarScript.path]
            process.currentDirectoryURL = AppStoragePaths.knowledgeSidecarDir
            process.standardOutput = logHandle
            process.standardError = logHandle
            process.standardInput = FileHandle.nullDevice

            var environment = ProcessInfo.processInfo.environment
            environment["PYTHONUNBUFFERED"] = "1"
            process.environment = environment

            process.terminationHandler = { [weak self] terminatedProcess in
                guard let self else { return }
                self.queue.async {
                    let pid = terminatedProcess.processIdentifier
                    self.trackedProcesses.removeValue(forKey: pid)
                    if self.readPIDLocked() == pid {
                        try? self.fileManager.removeItem(at: self.pidFileURL)
                    }
                    self.launchInProgress = false
                }
                try? logHandle.close()
            }

            try process.run()

            let pid = process.processIdentifier
            trackedProcesses[pid] = process
            try String(pid).write(to: pidFileURL, atomically: true, encoding: .utf8)
            launchInProgress = false
        } catch {
            launchInProgress = false
            try? logHandle.close()
        }
    }

    func ensureStarted(timeout: TimeInterval = 3.0) async -> Bool {
        start()
        let deadline = Date().addingTimeInterval(timeout)
        var hasRestartedForVersionMismatch = false
        while Date() < deadline {
            switch await KnowledgeBaseSidecarClient.shared.status(autostartIfNeeded: false) {
            case .success(let status):
                if status.status.lowercased() == "online" {
                    queue.sync {
                        launchInProgress = false
                    }
                    if let version = status.version,
                       !version.isEmpty,
                       version != KnowledgeBaseSidecarBootstrap.version,
                       !hasRestartedForVersionMismatch {
                        hasRestartedForVersionMismatch = true
                        stop()
                        start()
                        continue
                    }
                    return true
                }
            case .failure:
                break
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        queue.sync {
            launchInProgress = false
        }
        return isRunning()
    }

    private func isRunningLocked() -> Bool {
        guard let pid = readPIDLocked() else { return false }
        let isAlive = isProcessAlive(pid)
        if !isAlive {
            trackedProcesses.removeValue(forKey: pid)
            try? fileManager.removeItem(at: pidFileURL)
        }
        return isAlive
    }

    private func readPID() -> pid_t? {
        queue.sync {
            readPIDLocked()
        }
    }

    private func readPIDLocked() -> pid_t? {
        guard let data = try? Data(contentsOf: pidFileURL),
              let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(raw) else {
            return nil
        }
        return pid
    }

    private func isProcessAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }
}
