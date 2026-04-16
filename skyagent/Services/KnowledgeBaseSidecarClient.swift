import Foundation

struct KnowledgeBaseSidecarStatus: Codable {
    let status: String
    let message: String?
    let version: String?
    let parserBackend: String?
    let indexBackend: String?
    let capabilities: [String: Bool]?

    init(
        status: String,
        message: String?,
        version: String?,
        parserBackend: String? = nil,
        indexBackend: String? = nil,
        capabilities: [String: Bool]? = nil
    ) {
        self.status = status
        self.message = message
        self.version = version
        self.parserBackend = parserBackend
        self.indexBackend = indexBackend
        self.capabilities = capabilities
    }
}

struct KnowledgeBaseImportRequest: Codable {
    let libraryId: String
    let sources: [KnowledgeBaseImportSource]
}

struct KnowledgeBaseImportSource: Codable {
    let type: String
    let path: String
    let title: String?
}

struct KnowledgeBaseImportResponse: Codable {
    let imported: Int
    let skipped: Int?
    let failed: Int
    let errors: [String]?
}

struct KnowledgeBaseQueryRequest: Codable {
    let libraryId: String
    let query: String
    let topK: Int
}

struct KnowledgeBaseQueryHit: Codable {
    let id: String?
    let documentId: String?
    let title: String?
    let snippet: String
    let score: Double
    let citation: String?
    let source: String?
}

struct KnowledgeBaseQueryResponse: Codable {
    let hits: [KnowledgeBaseQueryHit]
}

enum KnowledgeBaseSidecarError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let text):
            return text
        }
    }
}

final class KnowledgeBaseSidecarClient {
    static let shared = KnowledgeBaseSidecarClient()

    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        session = URLSession(configuration: configuration)

        decoder = JSONDecoder()
        encoder = JSONEncoder()
    }

    func status(autostartIfNeeded: Bool = false) async -> Result<KnowledgeBaseSidecarStatus, KnowledgeBaseSidecarError> {
        guard let url = buildURL(path: "/kb/status") else {
            return .failure(.message("Sidecar 地址无效"))
        }
        if autostartIfNeeded {
            _ = await KnowledgeBaseSidecarManager.shared.ensureStarted()
        }
        return await fetch(url: url)
    }

    func importSources(_ request: KnowledgeBaseImportRequest) async -> Result<KnowledgeBaseImportResponse, KnowledgeBaseSidecarError> {
        guard let url = buildURL(path: "/kb/import") else {
            return .failure(.message("Sidecar 地址无效"))
        }
        return await postWithAutostart(url: url, payload: request)
    }

    func query(_ request: KnowledgeBaseQueryRequest) async -> Result<KnowledgeBaseQueryResponse, KnowledgeBaseSidecarError> {
        guard let url = buildURL(path: "/kb/query") else {
            return .failure(.message("Sidecar 地址无效"))
        }
        return await postWithAutostart(url: url, payload: request)
    }

    private func buildURL(path: String) -> URL? {
        let configURL = AppStoragePaths.knowledgeSidecarConfigFile
        guard let data = try? Data(contentsOf: configURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let endpoint = raw["endpoint"] as? String,
              !endpoint.isEmpty else {
            return URL(string: "http://127.0.0.1:9876\(path)")
        }
        let base = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        return URL(string: base + path)
    }

    private func fetch<T: Decodable>(url: URL) async -> Result<T, KnowledgeBaseSidecarError> {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.message("Sidecar 响应无效"))
            }
            guard (200 ..< 300).contains(http.statusCode) else {
                return .failure(.message("Sidecar 响应异常：\(http.statusCode)"))
            }
            let decoded = try decoder.decode(T.self, from: data)
            return .success(decoded)
        } catch {
            return .failure(.message("Sidecar 请求失败：\(error.localizedDescription)"))
        }
    }

    private func post<T: Codable, R: Decodable>(url: URL, payload: T) async -> Result<R, KnowledgeBaseSidecarError> {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try encoder.encode(payload)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.message("Sidecar 响应无效"))
            }
            guard (200 ..< 300).contains(http.statusCode) else {
                return .failure(.message("Sidecar 响应异常：\(http.statusCode)"))
            }
            let decoded = try decoder.decode(R.self, from: data)
            return .success(decoded)
        } catch {
            return .failure(.message("Sidecar 请求失败：\(error.localizedDescription)"))
        }
    }

    private func postWithAutostart<T: Codable, R: Decodable>(url: URL, payload: T) async -> Result<R, KnowledgeBaseSidecarError> {
        _ = await KnowledgeBaseSidecarManager.shared.ensureStarted()
        let firstAttempt: Result<R, KnowledgeBaseSidecarError> = await post(url: url, payload: payload)
        switch firstAttempt {
        case .success:
            return firstAttempt
        case .failure(let error):
            let description = error.description.lowercased()
            if description.contains("could not connect") ||
                description.contains("failed to connect") ||
                description.contains("network connection was lost") ||
                description.contains("无法连接") ||
                description.contains("连接被中断") {
                _ = await KnowledgeBaseSidecarManager.shared.ensureStarted(timeout: 4.0)
                return await post(url: url, payload: payload)
            }
            return firstAttempt
        }
    }
}
