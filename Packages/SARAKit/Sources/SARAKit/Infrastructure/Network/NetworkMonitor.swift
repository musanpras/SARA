import Foundation
import Network
import SARACore

/// Tracks whether the device has a usable network path.
///
/// Routing needs a truthful answer before it offers a cloud provider, so this
/// reports the current path rather than discovering the problem by failing a
/// request.
public actor NetworkMonitor: NetworkAvailability {
    private let monitor = NWPathMonitor()
    private var currentlyOnline = false
    private var started = false

    public init() {}

    public var isOnline: Bool {
        get async {
            start()
            return currentlyOnline
        }
    }

    private func start() {
        guard !started else { return }
        started = true

        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { await self?.update(online: online) }
        }
        monitor.start(queue: DispatchQueue(label: "com.sara.network-monitor"))
        currentlyOnline = monitor.currentPath.status == .satisfied
    }

    private func update(online: Bool) {
        currentlyOnline = online
    }
}
