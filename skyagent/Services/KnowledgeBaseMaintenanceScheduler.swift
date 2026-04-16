import Foundation

final class KnowledgeBaseMaintenanceScheduler {
    static let shared = KnowledgeBaseMaintenanceScheduler()

    private let queue = DispatchQueue(label: "SkyAgent.KnowledgeBaseMaintenanceScheduler", qos: .utility)
    private var loopTask: Task<Void, Never>?

    private init() {}

    func start() {
        queue.sync {
            guard loopTask == nil else { return }
            loopTask = Task.detached(priority: .utility) {
                while !Task.isCancelled {
                    _ = await KnowledgeBaseService.shared.runAutomaticMaintenanceIfNeeded()
                    try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
                }
            }
        }
    }

    func stop() {
        queue.sync {
            loopTask?.cancel()
            loopTask = nil
        }
    }
}
