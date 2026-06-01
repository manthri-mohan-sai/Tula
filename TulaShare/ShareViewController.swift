//
//  ShareViewController.swift
//  Tula
//
//  Created by Mohan Manthri on 30/05/26.
//


import UIKit
import SwiftUI
import UniformTypeIdentifiers

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

        view.backgroundColor = .systemBackground

        let session = ShareSession(
            extensionContext: extensionContext,
            onComplete: { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            },
            onCancel: { [weak self] in
                self?.extensionContext?.cancelRequest(
                    withError: NSError(domain: "TulaShare",
                                       code: NSUserCancelledError,
                                       userInfo: nil)
                )
            }
        )
        self.session = session
        session.start()

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
    }
}
