//
//  ShareViewController.swift
//  Tula Share
//
//  Share Extension: receives photos from the iOS Share Sheet,
//  performs OCR + AI extraction, and shows an expense form for
//  the user to verify and save.
//

import UIKit
import SwiftUI
import Vision
import UniformTypeIdentifiers

class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        loadSharedImage()
    }

    private func loadSharedImage() {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            dismissExtension()
            return
        }

        for item in extensionItems {
            guard let attachments = item.attachments else { continue }
            for provider in attachments {
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { [weak self] data, error in
                        DispatchQueue.main.async {
                            self?.handleLoadedImage(data: data, error: error)
                        }
                    }
                    return
                }
            }
        }
        dismissExtension()
    }

    private func handleLoadedImage(data: Any?, error: Error?) {
        var image: UIImage?

        if let url = data as? URL {
            image = UIImage(contentsOfFile: url.path)
        } else if let imageData = data as? Data {
            image = UIImage(data: imageData)
        } else if let uiImage = data as? UIImage {
            image = uiImage
        }

        guard let finalImage = image else {
            dismissExtension()
            return
        }

        presentExpenseForm(with: finalImage)
    }

    private func presentExpenseForm(with image: UIImage) {
        let formView = ShareExpenseFormView(
            image: image,
            onDismiss: { [weak self] in self?.dismissExtension() }
        )

        let hostingController = UIHostingController(rootView: formView)
        addChild(hostingController)
        view.addSubview(hostingController.view)
        hostingController.view.frame = view.bounds
        hostingController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hostingController.didMove(toParent: self)
    }

    private func dismissExtension() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

