import Foundation

enum LogLevel: String, Sendable {
    case debug
    case info
    case warn
    case error
}

enum LogCategory: String, Sendable {
    case app
    case conversation
    case llm
    case orchestrator
    case tool
    case skill
    case mcp
    case shell
    case memory
    case context
    case ui
    case render
    case file
}

enum LogStatus: String, Sendable {
    case started
    case progress
    case succeeded
    case failed
    case cancelled
    case skipped
    case timeout
    case retrying
}

enum LogErrorKind: String, Sendable {
    case timeout
    case network
    case permission = "permission"
    case invalidArgs = "invalid_args"
    case invalidState = "invalid_state"
    case dependencyMissing = "dependency_missing"
    case processExitNonzero = "process_exit_nonzero"
    case toolLoopLimit = "tool_loop_limit"
    case cancelled
    case unknown
}

enum LogRecoveryAction: String, Sendable {
    case retry
    case fallback
    case abort
    case none
}

enum LogValue: Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case strings([String])

    nonisolated var jsonObject: Any {
        switch self {
        case .string(let value):
            return value
        case .int(let value):
            return value
        case .double(let value):
            return value
        case .bool(let value):
            return value
        case .strings(let value):
            return value
        }
    }
}

struct TraceContext: Sendable {
    let traceID: String
    let conversationID: UUID?
    let messageID: UUID?
    let operationID: String?
    let requestID: String?

    nonisolated init(
        traceID: String = "tr_\(UUID().uuidString.lowercased())",
        conversationID: UUID? = nil,
        messageID: UUID? = nil,
        operationID: String? = nil,
        requestID: String? = "req_\(UUID().uuidString.lowercased())"
    ) {
        self.traceID = traceID
        self.conversationID = conversationID
        self.messageID = messageID
        self.operationID = operationID
        self.requestID = requestID
    }

    nonisolated func with(
        conversationID: UUID? = nil,
        messageID: UUID? = nil,
        operationID: String? = nil,
        requestID: String? = nil
    ) -> TraceContext {
        TraceContext(
            traceID: traceID,
            conversationID: conversationID ?? self.conversationID,
            messageID: messageID ?? self.messageID,
            operationID: operationID ?? self.operationID,
            requestID: requestID ?? self.requestID
        )
    }
}

struct LogEvent: Sendable {
    let id: UUID
    let timestamp: Date
    let level: LogLevel
    let category: LogCategory
    let event: String
    let traceID: String?
    let conversationID: UUID?
    let messageID: UUID?
    let operationID: String?
    let requestID: String?
    let status: LogStatus?
    let durationMs: Double?
    let summary: String
    let metadata: [String: LogValue]

    nonisolated init(
        level: LogLevel,
        category: LogCategory,
        event: String,
        traceContext: TraceContext? = nil,
        status: LogStatus? = nil,
        durationMs: Double? = nil,
        summary: String,
        metadata: [String: LogValue] = [:]
    ) {
        self.id = UUID()
        self.timestamp = Date()
        self.level = level
        self.category = category
        self.event = event
        self.traceID = traceContext?.traceID
        self.conversationID = traceContext?.conversationID
        self.messageID = traceContext?.messageID
        self.operationID = traceContext?.operationID
        self.requestID = traceContext?.requestID
        self.status = status
        self.durationMs = durationMs
        self.summary = summary
        self.metadata = metadata
    }

    nonisolated var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "id": id.uuidString,
            "timestamp": ISO8601DateFormatter().string(from: timestamp),
            "level": level.rawValue,
            "category": category.rawValue,
            "event": event,
            "summary": summary,
            "metadata": metadata.mapValues(\.jsonObject)
        ]
        object["traceID"] = traceID
        object["conversationID"] = conversationID?.uuidString
        object["messageID"] = messageID?.uuidString
        object["operationID"] = operationID
        object["requestID"] = requestID
        object["status"] = status?.rawValue
        object["durationMs"] = durationMs
        return object
    }
}

enum LogRedactor {
    nonisolated private static let sensitiveKeyFragments = [
        "token",
        "authorization",
        "api_key",
        "apikey",
        "secret",
        "password"
    ]

    nonisolated private static let previewKeyFragments = [
        "content",
        "prompt",
        "input",
        "output",
        "arguments",
        "stdout",
        "stderr",
        "systemprompt",
        "system_prompt"
    ]

    nonisolated static func sanitizeSummary(_ summary: String) -> String {
        truncate(summary, maxLength: 180)
    }

    nonisolated static func sanitizeMetadata(_ metadata: [String: LogValue]) -> [String: LogValue] {
        var sanitized: [String: LogValue] = [:]
        sanitized.reserveCapacity(metadata.count)

        for (key, value) in metadata {
            let normalizedKey = key.lowercased()
            if sensitiveKeyFragments.contains(where: { normalizedKey.contains($0) }) {
                sanitized[key] = .string("<redacted>")
                continue
            }

            if previewKeyFragments.contains(where: { normalizedKey.contains($0) }) {
                switch value {
                case .string(let string):
                    sanitized[key] = .string(truncate(string, maxLength: 120))
                    sanitized["\(key)_length"] = .int(string.count)
                case .strings(let strings):
                    sanitized[key] = .strings(strings.map { truncate($0, maxLength: 80) })
                    sanitized["\(key)_count"] = .int(strings.count)
                default:
                    sanitized[key] = value
                }
                continue
            }

            switch value {
            case .string(let string):
                sanitized[key] = .string(truncate(string, maxLength: 300))
            case .strings(let strings):
                sanitized[key] = .strings(strings.map { truncate($0, maxLength: 120) })
            default:
                sanitized[key] = value
            }
        }

        return sanitized
    }

    nonisolated static func preview(_ text: String, maxLength: Int = 120) -> String {
        truncate(
            text
                .components(separatedBy: .newlines)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            maxLength: maxLength
        )
    }

    nonisolated private static func truncate(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        return String(text.prefix(maxLength)) + "…"
    }
}

enum LogMetadataBuilder {
    static func failure(
        errorKind: LogErrorKind,
        retryCount: Int? = nil,
        recoveryAction: LogRecoveryAction,
        isUserVisible: Bool,
        extra: [String: LogValue] = [:]
    ) -> [String: LogValue] {
        var metadata = extra
        metadata["error_kind"] = .string(errorKind.rawValue)
        metadata["recovery_action"] = .string(recoveryAction.rawValue)
        metadata["is_user_visible"] = .bool(isUserVisible)
        if let retryCount {
            metadata["retry_count"] = .int(retryCount)
        }
        return metadata
    }
}

actor LogStore {
    private let fileManager = FileManager.default

    func append(_ event: LogEvent) {
        let url = fileURL(for: event.timestamp)
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }

        guard JSONSerialization.isValidJSONObject(event.jsonObject),
              let data = try? JSONSerialization.data(withJSONObject: event.jsonObject, options: [.sortedKeys]) else { return }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data([0x0A]))
        } catch {
            return
        }
    }

    private func fileURL(for date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        AppStoragePaths.prepareDataDirectories()
        let logsDir = AppStoragePaths.eventLogsDir
        return logsDir.appendingPathComponent("\(formatter.string(from: date)).ndjson")
    }
}

actor LoggerService {
    static let shared = LoggerService()

    private let store = LogStore()

    func log(
        level: LogLevel = .info,
        category: LogCategory,
        event: String,
        traceContext: TraceContext? = nil,
        status: LogStatus? = nil,
        durationMs: Double? = nil,
        summary: String,
        metadata: [String: LogValue] = [:]
    ) async {
        let sanitizedEvent = LogEvent(
            level: level,
            category: category,
            event: event,
            traceContext: traceContext,
            status: status,
            durationMs: durationMs,
            summary: LogRedactor.sanitizeSummary(summary),
            metadata: LogRedactor.sanitizeMetadata(metadata)
        )
        await store.append(sanitizedEvent)
    }
}

struct PersistedLogEvent: Identifiable, Sendable {
    let id: String
    let timestamp: Date
    let level: String
    let category: String
    let event: String
    let traceID: String?
    let conversationID: String?
    let messageID: String?
    let operationID: String?
    let requestID: String?
    let status: String?
    let durationMs: Double?
    let summary: String
    let metadata: [String: String]

    var relativeTimestamp: String {
        RelativeDateTimeFormatter().localizedString(for: timestamp, relativeTo: Date())
    }

    var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: timestamp)
    }
}

enum LogFileReader {
    nonisolated static func loadRecentEvents(limit: Int = 250, maxFiles: Int = 5) -> [PersistedLogEvent] {
        AppStoragePaths.prepareDataDirectories()
        let directory = AppStoragePaths.eventLogsDir
        let fileManager = FileManager.default
        let urls = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let candidateFiles = urls
            .filter { $0.pathExtension.lowercased() == "ndjson" }
            .sorted { lhs, rhs in
                let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if leftDate != rightDate {
                    return leftDate > rightDate
                }
                return lhs.lastPathComponent > rhs.lastPathComponent
            }
            .prefix(maxFiles)

        var events: [PersistedLogEvent] = []
        events.reserveCapacity(limit)

        for url in candidateFiles {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let lines = raw.split(whereSeparator: \.isNewline)
            for line in lines.reversed() {
                guard let event = parse(line: String(line)) else { continue }
                events.append(event)
                if events.count >= limit {
                    return events.sorted { $0.timestamp > $1.timestamp }
                }
            }
        }

        return events.sorted { $0.timestamp > $1.timestamp }
    }

    nonisolated static func availableLogFiles() -> [URL] {
        AppStoragePaths.prepareDataDirectories()
        let directory = AppStoragePaths.eventLogsDir
        let fileManager = FileManager.default
        return ((try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension.lowercased() == "ndjson" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    nonisolated private static func parse(line: String) -> PersistedLogEvent? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        guard let id = object["id"] as? String,
              let timestampString = object["timestamp"] as? String,
              let timestamp = formatter.date(from: timestampString),
              let level = object["level"] as? String,
              let category = object["category"] as? String,
              let event = object["event"] as? String,
              let summary = object["summary"] as? String else {
            return nil
        }

        let metadataObject = (object["metadata"] as? [String: Any]) ?? [:]
        let metadata = metadataObject.mapValues(stringifyMetadataValue(_:))

        return PersistedLogEvent(
            id: id,
            timestamp: timestamp,
            level: level,
            category: category,
            event: event,
            traceID: object["traceID"] as? String,
            conversationID: object["conversationID"] as? String,
            messageID: object["messageID"] as? String,
            operationID: object["operationID"] as? String,
            requestID: object["requestID"] as? String,
            status: object["status"] as? String,
            durationMs: object["durationMs"] as? Double,
            summary: summary,
            metadata: metadata
        )
    }

    nonisolated private static func stringifyMetadataValue(_ value: Any) -> String {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        case let array as [Any]:
            return array.map(stringifyMetadataValue(_:)).joined(separator: ", ")
        case let dictionary as [String: Any]:
            return dictionary
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\(stringifyMetadataValue($0.value))" }
                .joined(separator: ", ")
        default:
            return String(describing: value)
        }
    }
}
