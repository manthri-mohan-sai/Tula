import SwiftUI
import UIKit
import PhotosUI

/// SwiftUI wrapper for receipt photo capture/selection. Routes to the
/// camera or the PhotosUI picker based on the `source` parameter.
///
/// Why two pickers and not just PHPickerViewController? PHPicker doesn't
/// support the camera (it's library-only by design). For camera capture
/// we need the older UIImagePickerController, which is also the only
/// path for "take a photo right now."
///
/// Calls `onPick` with the chosen image, or nil if the user cancelled.
/// Caller is expected to dismiss the sheet after invocation by setting
/// the bound state to nil — we don't manage the sheet's lifecycle here.
struct ReceiptPicker: UIViewControllerRepresentable {

    let source: AddExpenseView.ReceiptSource
    let onPick: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        switch source {
        case .camera:
            // UIImagePickerController is the only way to get the system
            // camera UI. PHPicker is library-only. Camera availability
            // check is for the rare case (simulator, restricted devices)
            // where the camera isn't reachable — we fall back to library.
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                let picker = UIImagePickerController()
                picker.sourceType = .camera
                picker.delegate = context.coordinator
                picker.allowsEditing = false
                return picker
            }
            return libraryPicker(coordinator: context.coordinator)
        case .library:
            return libraryPicker(coordinator: context.coordinator)
        }
    }

    func updateUIViewController(_ uiViewController: UIViewControllerType, context: Context) {
        // No dynamic config — the picker is fully configured at creation.
    }

    /// PHPicker config: single image, no editing, .images filter.
    private func libraryPicker(coordinator: Coordinator) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
        config.selectionLimit = 1
        // `.compatible` is the older but more predictable PHPicker
        // delivery mode. `.current` (the default) sometimes returns
        // HEIC/RAW data the way it's stored on disk, which can fail
        // to load as UIImage via the standard provider. Forcing
        // `.compatible` makes PHPicker convert to JPEG/PNG before
        // handing back the item, which loads reliably via
        // loadObject(ofClass: UIImage.self).
        config.preferredAssetRepresentationMode = .compatible
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = coordinator
        return picker
    }

    // MARK: - Coordinator
    //
    // Bridges UIKit's two different delegate protocols (legacy UIImagePicker
    // and modern PHPicker) into a single `onPick(UIImage?)` callback.
    // The complexity lives here so the rest of the view tree doesn't have
    // to think about delegate methods or NSItemProvider gymnastics.

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate, PHPickerViewControllerDelegate {
        let onPick: (UIImage?) -> Void

        init(onPick: @escaping (UIImage?) -> Void) {
            self.onPick = onPick
        }

        // MARK: UIImagePickerController (camera path)

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            let image = info[.originalImage] as? UIImage
            picker.dismiss(animated: true) { [weak self] in
                self?.onPick(image)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true) { [weak self] in
                self?.onPick(nil)
            }
        }

        // MARK: PHPickerViewController (library path)
        //
        // **Image loading is two-step**: try `loadObject(ofClass: UIImage)`
        // first (works for standard JPEG/PNG and `.compatible`-mode HEIC),
        // fall back to `loadDataRepresentation` for anything else.
        //
        // **Dismissal**: load BEFORE dismissing — PHPicker's itemProvider
        // is backed by the picker's internal photo storage and gets
        // invalidated on dismissal. Dismissing first silently breaks
        // image loading.
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            // User tapped Cancel — empty results, dismiss + propagate nil.
            guard let provider = results.first?.itemProvider else {
                picker.dismiss(animated: true) { [weak self] in
                    self?.onPick(nil)
                }
                return
            }

            // Strategy 1: standard UIImage load. Works for the vast
            // majority of photos.
            if provider.canLoadObject(ofClass: UIImage.self) {
                provider.loadObject(ofClass: UIImage.self) { [weak self, weak picker] object, _ in
                    let image = object as? UIImage
                    DispatchQueue.main.async {
                        picker?.dismiss(animated: true) {
                            self?.onPick(image)
                        }
                    }
                }
                return
            }

            // Strategy 2: fall back to raw data → UIImage manually.
            // Some HEIC/RAW photos don't conform to UIImage class
            // through the provider but ARE decodable via UIImage(data:).
            // Try the public.image type which covers most formats.
            let typeID = provider.registeredTypeIdentifiers.first ?? "public.image"
            provider.loadDataRepresentation(forTypeIdentifier: typeID) { [weak self, weak picker] data, _ in
                let image = data.flatMap { UIImage(data: $0) }
                DispatchQueue.main.async {
                    picker?.dismiss(animated: true) {
                        self?.onPick(image)
                    }
                }
            }
        }
    }
}
