import Foundation
import Network
import Observation

/// Lightweight network reachability observer using NWPathMonitor.
/// Publishes a simple `isConnected` boolean that SwiftUI views can
/// observe to show/hide offline banners.
///
/// Usage: Access the shared instance via `NetworkMonitor.shared`.
/// The monitor starts automatically on first access.
@Observable
@MainActor
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private(set) var isConnected: Bool = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "tula.network.monitor")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.isConnected = connected
            }
        }
        monitor.start(queue: queue)
    }
}
