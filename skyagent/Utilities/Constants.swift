import Foundation

// Process timeout helper
extension Process {
    var timeout: TimeInterval? {
        get { nil }
        set {
            guard let interval = newValue else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + interval) { [weak self] in
                if self?.isRunning == true {
                    self?.terminate()
                }
            }
        }
    }
}

extension String {
    static func collectingErrorBody(from bytes: URLSession.AsyncBytes) async throws -> String {
        var result = ""
        for try await line in bytes.lines {
            result += line
        }
        return result
    }
}
