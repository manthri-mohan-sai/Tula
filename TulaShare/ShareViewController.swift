//
//  ShareViewController.swift
//  Tula
//
//  Created by Mohan Manthri on 30/05/26.
//


import UIKit
import SwiftUI
import UniformTypeIdentifiers
import os.log

private let shareLog = Logger(subsystem: "com.app.alpha.Tula.TulaShare", category: "ShareExtension")

// MARK: - Crash Logger (writes before extension is killed)

/// Writes a log entry synchronously to the App Group container.
/// Uses low-level file I/O to survive even during memory pressure kills.
private func writeShareLog(_ message: String) {
    let groupID = "group.com.app.alpha.Tula"
    guard let containerURL = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: groupID
    ) else { return }

    let logFile = containerURL.appendingPathComponent("share_crash.log")
    let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
    let entry = "[\(timestamp)] \(message)\n"

    if let data = entry.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logFile.path) {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: logFile)
        }
    }
}

/// Installs a global uncaught exception handler that writes the crash
/// reason to the shared log file before the process terminates.
private func installCrashHandler() {
    NSSetUncaughtExceptionHandler { exception in
        let msg = """
        UNCAUGHT EXCEPTION: \(exception.name.rawValue)
        Reason: \(exception.reason ?? "nil")
        Stack: \(exception.callStackSymbols.prefix(10).joined(separator: "\n"))
        """
        writeShareLog(msg)
    }
}

/// The Tula share extension's principal view controller. Replaces the
/// Apple-default storyboard-based UI with a SwiftUI-hosted preview that
/// matches Tula's brand and gives the user one-tap "Add" / "Edit in Tula"
/// actions.
///
/// **Lifecycle**:
/// 1. iOS instantiates this controller when the user picks Tula from
///    the share sheet
/// 2. We read `extensionContext.inputItems` to find what the user
///    shared (image, text, URL)
/// 3. Hand the raw content to a `ShareSession` ObservableObject that
///    runs the OCR + smart parser pipeline asynchronously
/// 4. SwiftUI binds to that session and renders the preview UI
/// 5. Tapping "Add" commits to the shared SwiftData store and dismisses
///    the extension via `completeRequest`
/// 6. Tapping "Cancel" dismisses without saving via `cancelRequest`
///
/// **Why a UIViewController wrapper?** Apple's share extension
/// infrastructure expects a UIViewController as the principal class.
/// SwiftUI runs inside a `UIHostingController` we add as a child.
class ShareViewController: UIViewController {

    /// The session object holds the extracted content + parse state.
    /// SwiftUI views observe it for live updates. Created in viewDidLoad
    /// once we've read the input items, retained as a property so
    /// async parsing tasks can update it without escaping.
    private var session: ShareSession?

    override func viewDidLoad() {
        super.viewDidLoad()
        installCrashHandler()
        writeShareLog("viewDidLoad START")
        shareLog.info("ShareViewController viewDidLoad started")

        // Log memory usage
        let memUsage = ProcessInfo.processInfo.physicalMemory
        writeShareLog("Device memory: \(memUsage / 1024 / 1024)MB")

        // Log input items
        if let items = extensionContext?.inputItems as? [NSExtensionItem] {
            let providers = items.flatMap { $0.attachments ?? [] }
            writeShareLog("Providers: \(providers.count)")
            for (i, p) in providers.enumerated() {
                writeShareLog("  [\(i)] types: \(p.registeredTypeIdentifiers)")
            }
        } else {
            writeShareLog("No extensionContext or inputItems")
        }

        // Background matches the app's surface so the share sheet
        // doesn't look like a system dialog.
        view.backgroundColor = .systemBackground

        // Build the session from whatever the user shared. This is
        // synchronous — just extracts the NSItemProvider references.
        // The actual content load (image bytes, text) happens
        // asynchronously inside the session.
        let session = ShareSession(
            extensionContext: extensionContext,
            onComplete: { [weak self] in
                // Successful save — tell iOS the extension is done.
                // completeRequest dismisses the share sheet and
                // returns the user to the host app (Photos, Messages,
                // etc.) with a checkmark animation.
                self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            },
            onCancel: { [weak self] in
                // User tapped Cancel or there was nothing to share.
                // cancelRequest dismisses without the success animation.
                self?.extensionContext?.cancelRequest(
                    withError: NSError(domain: "TulaShare",
                                       code: NSUserCancelledError,
                                       userInfo: nil)
                )
            }
        )
        self.session = session

        shareLog.info("ShareSession created, starting content load")
        writeShareLog("Session created, calling start()")
        // Begin loading the shared content. Updates `session` state
        // as content arrives and parsing completes; SwiftUI re-renders
        // automatically via @Published.
        session.start()
        writeShareLog("session.start() returned")

        // Host the SwiftUI root inside a child UIHostingController.
        // Auto layout pins it to all edges so it fills the share-sheet
        // modal exactly.
        writeShareLog("Creating UIHostingController...")
        let host = UIHostingController(rootView: ShareRootView(session: session))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
        writeShareLog("viewDidLoad COMPLETE — UI hosted successfully")
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        writeShareLog("⚠️ MEMORY WARNING received — iOS may kill extension soon")
        shareLog.warning("Memory warning in share extension")
    }
}
