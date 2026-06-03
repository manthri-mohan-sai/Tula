//
//  SharedStorage.swift
//  Tula
//
//  Created by Mohan Manthri on 30/05/26.
//


import Foundation
import SwiftData

/// Shared infrastructure used by both the main Tula app and the
/// TulaShare extension. Centralizes:
///
/// - **App Group identifier**: `group.com.app.alpha.Tula` — the entitlement
///   that lets the two targets share a container directory.
/// - **Shared container URL**: where receipt photos live (outside the
///   SwiftData store, addressed by file URL).
/// - **Shared SwiftData store URL**: a single SQLite file in the App
///   Group container that both processes open. SwiftData on iOS 18 uses
///   SQLite's built-in locking for cross-process safety; this is enough
///   for the share-and-die pattern of an extension.
/// - **Darwin notification names**: cross-process pings the main app
///   listens for so it can refresh after the extension saves.
///
/// **Why this file lives in the main app and gets added to the share
/// extension target via "Target Membership"**: keeping a single
/// definition prevents drift. If you ever rename the App Group or
/// change container layout, you change it here and both targets pick
/// up the change automatically. The alternative — duplicating the
/// constants in the extension — is a bug waiting to happen.
enum SharedStorage {

    /// The App Group identifier. Must match exactly what's set in
    /// **Signing & Capabilities → App Groups** on BOTH the Tula target
    /// and the TulaShare target. If either is missing or mismatched,
    /// `sharedContainerURL` will return nil and the share flow breaks
    /// silently.
    static let appGroupID = "group.com.app.alpha.Tula"

    /// The shared container directory provided by the App Group.
    /// Both processes can read/write files here. Nil means the App
    /// Group entitlement isn't set up — surface this loudly in debug
    /// builds; ship as a no-op in release (extension just degrades to
    /// "couldn't save," main app behaves normally).
    static var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    /// The SwiftData store URL inside the shared container. Named
    /// `Tula.store` for clarity; SwiftData appends `-wal` and `-shm`
    /// siblings automatically (the SQLite WAL files for crash safety).
    ///
    /// Both the main app and the extension construct their
    /// `ModelContainer` against this URL. SwiftData on iOS 18 handles
    /// the cross-process locking via SQLite; concurrent writes are
    /// safe in practice because the extension only writes briefly and
    /// the main app is typically not writing at the same instant.
    static var sharedStoreURL: URL? {
        sharedContainerURL?.appending(path: "Tula.store")
    }

    /// Directory where the extension stores receipt photos that came
    /// in from share-sheet image attachments. The path inside the
    /// container is referenced by the saved Expense's metadata so the
    /// main app can find the photo on next launch.
    static var receiptsDirectoryURL: URL? {
        guard let base = sharedContainerURL else { return nil }
        let dir = base.appending(path: "Receipts", directoryHint: .isDirectory)
        // Create on first access. Idempotent — `createDirectory` with
        // `withIntermediateDirectories: true` is a no-op when the
        // directory already exists.
        try? FileManager.default.createDirectory(at: dir,
                                                  withIntermediateDirectories: true)
        return dir
    }

    /// Build a `ModelContainer` configured to use the shared store.
    /// Both targets call this — the main app at `TulaApp` init, the
    /// extension when it needs to write. Same schema, same store.
    ///
    /// Returns nil only if the App Group isn't configured. In that
    /// case the caller falls back to a local container in the main
    /// app (preserving normal operation) or aborts in the extension.
    @MainActor
    static func makeSharedContainer() -> ModelContainer? {
        guard let storeURL = sharedStoreURL else { return nil }
        let schema = Schema([
            Account.self,
            Category.self,
            Expense.self,
            Transfer.self,
            RecurringRule.self,
            MerchantRule.self,
            Budget.self
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            url: storeURL,
            // App Group identifier — SwiftData uses this to know
            // which sandbox the store belongs to. Without it,
            // CloudKit sync (when added) doesn't know where to map.
            cloudKitDatabase: .none
        )
        return try? ModelContainer(for: schema, configurations: [configuration])
    }
}

// MARK: - Cross-Process Notifications
//
// Darwin notifications are the only way to ping between separate
// processes on iOS (in-process NotificationCenter doesn't cross
// process boundaries). The share extension posts a "did-save" name
// when it commits an expense; the main app, if running, listens and
// triggers a refetch. If the main app isn't running, it picks up
// changes on its next foreground via SwiftData's normal fetch.

enum SharedNotifications {
    /// Posted by the share extension after a successful expense save.
    /// The main app listens for this name and refreshes its queries.
    static let didSaveExpense = "com.app.alpha.Tula.didSaveExpense"
}

/// Post a Darwin notification by name. Wrapped here so callers don't
/// have to import CoreFoundation directly or remember the bridging
/// dance.
func postDarwinNotification(_ name: String) {
    let center = CFNotificationCenterGetDarwinNotifyCenter()
    let cfName = CFNotificationName(name as CFString)
    CFNotificationCenterPostNotification(center, cfName, nil, nil, true)
}

/// Observe a Darwin notification by name. Returns a token; the caller
/// retains the token to keep the observation alive (releasing it
/// removes the observer). The handler is called on the main thread —
/// caller can update SwiftUI state directly without further hopping.
final class DarwinNotificationObserver {
    private let name: String
    private let handler: () -> Void
    private var observer: UnsafeMutableRawPointer?

    init(name: String, handler: @escaping () -> Void) {
        self.name = name
        self.handler = handler
        attach()
    }

    deinit {
        detach()
    }

    private func attach() {
        let observer = Unmanaged.passUnretained(self).toOpaque()
        self.observer = observer
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let me = Unmanaged<DarwinNotificationObserver>
                    .fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async {
                    me.handler()
                }
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
    }

    private func detach() {
        guard let observer else { return }
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer
        )
        self.observer = nil
    }
}
