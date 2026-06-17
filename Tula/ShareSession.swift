import Foundation
import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import UIKit
import Combine
import ImageIO

// MARK: - Memory-Safe Image Decoding

/// Decodes an image from data using ImageIO, downsampling at decode time
/// so the full-resolution bitmap is never loaded into memory. This prevents
/// the extension from being killed when sharing 48MP+ camera photos.
private func downsampleImageData(_ data: Data, maxPixels: CGFloat = 1500) -> UIImage? {
    let options: [CFString: Any] = [
        kCGImageSourceShouldCache: false
    ]
    guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
        return nil
    }

    // Get the image dimensions without decoding
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
          let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else {
        return nil
    }

    let maxDimension = max(width, height)
    let downsampleFactor = maxDimension > maxPixels ? maxPixels / maxDimension : 1.0
    let targetMaxPixels = max(width, height) * downsampleFactor

    let downsampleOptions: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: targetMaxPixels
    ]

    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions as CFDictionary) else {
        return nil
    }

    return UIImage(cgImage: cgImage)
}

/// Drives the share extension's parsing + UI state. Lives for the
/// lifetime of one share invocation. Holds the extracted content
/// (image / text), the parse results, and the eventual save outcome.
///
/// **Threading**: @Published mutations are always wrapped in
/// `MainActor.run` (or called from `@MainActor` annotated methods)
/// so SwiftUI bindings update on the main thread. The class itself
/// is NOT marked `@MainActor` because that conflicts with
/// `ObservableObject`'s synthesized `objectWillChange` requirement
/// (which expects `nonisolated` accessibility). Per-call isolation
/// is the right granularity here.
final class ShareSession: ObservableObject {

    // MARK: - State exposed to SwiftUI

    /// What the user shared, after we've classified it.
    enum SharedContent {
        case image(UIImage)
        case text(String)
        case empty  // share sheet opened with nothing parseable
    }

    /// Coarse-grained state machine for UI rendering. Drives which
    /// section the SwiftUI view shows (loading vs preview vs error).
    enum Phase: Equatable {
        case loading           // extracting content from item providers
        case parsing           // OCR / smart parser running
        case preview           // results ready for user confirmation
        case saving            // user tapped Add, write in progress
        case saved             // write succeeded — about to dismiss
        case failed(String)    // unrecoverable error with reason
    }

    @Published var phase: Phase = .loading
    @Published var content: SharedContent = .empty
    @Published var amount: Double = 0
    @Published var merchant: String = ""
    @Published var date: Date = .now
    @Published var note: String = ""
    @Published var categoryName: String?
    /// True when Apple Intelligence (Foundation Models) contributed to
    /// the parsed result. Drives the ✨ glyph next to the hero amount
    /// in the preview UI — the user's "AI did this" signal. Set when
    /// the smart parser returns a non-nil result during the parsing
    /// phase; stays false on FM-unavailable devices or pure regex paths.
    @Published var usedSmartParser: Bool = false
    /// Non-nil when the parse result has medium-or-low confidence —
    /// the UI surfaces this as a "please verify" banner so the user
    /// knows to double-check before tapping Add. Set during the
    /// parsing phase based on `ParseResult.confidenceReason`.
    /// Nil = high confidence = no banner.
    @Published var parseWarning: String?
    @Published var canRetryAIGate: Bool = false
    @Published var items: [ReceiptLineItem] = []
    @Published var discount: Double = 0
    @Published var tax: Double = 0
    @Published var parsingStatus: String = ""
    @Published var availableCategories: [String] = []
    @Published var availableAccounts: [(name: String, id: UUID)] = []
    @Published var selectedAccountName: String?

    // MARK: - Wiring

    private weak var extensionContext: NSExtensionContext?
    private let onComplete: () -> Void
    private let onCancel: () -> Void

    init(extensionContext: NSExtensionContext?,
         onComplete: @escaping () -> Void,
         onCancel: @escaping () -> Void) {
        self.extensionContext = extensionContext
        self.onComplete = onComplete
        self.onCancel = onCancel
    }

    // MARK: - Content extraction

    /// Begin processing the shared content. Reads NSItemProvider
    /// attachments off the input items, classifies each, and routes
    /// to OCR (for images) or text parsing.
    func start() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem],
              !items.isEmpty else {
            phase = .failed("Nothing shared")
            return
        }

        let providers = items.flatMap { $0.attachments ?? [] }

        if let imageProvider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }) {
            loadImage(from: imageProvider)
        } else if let textProvider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.text.identifier) }) {
            loadText(from: textProvider)
        } else if let urlProvider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
            loadText(from: urlProvider)
        } else {
            phase = .failed("Couldn't read what you shared")
        }
    }

    /// Load image bytes from the item provider, decode to UIImage,
    /// downscale aggressively for memory safety, then run the OCR +
    /// smart parser pipeline.
    ///
    /// **Why downscale immediately**: the full-res image gets stashed
    /// in `self.content` for the entire share extension lifetime so
    /// it can be displayed in the preview and used at save time.
    /// A 1290×2796 hospital bill screenshot decoded is ~14MB ARGB.
    /// Holding that for 30+ seconds while the user reviews can push
    /// the extension's ~120MB memory ceiling and get the process
    /// killed by iOS — manifests as "extension closes immediately".
    /// Downscaling to 1500px max yields ~4MB held, plenty of headroom
    /// for Vision OCR + FM model load.
    private func loadImage(from provider: NSItemProvider) {
        // Camera photos (HEIC/JPEG) may not respond to generic "public.image"
        // on all devices. Try the provider's first registered type that
        // conforms to public.image — this covers HEIC, JPEG, PNG, etc.
        let typeID = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .image) == true
        }) ?? UTType.image.identifier

        provider.loadItem(forTypeIdentifier: typeID, options: nil) { [weak self] item, error in
            if let error {
                Task { @MainActor in
                    self?.phase = .failed("Failed to load image: \(error.localizedDescription)")
                }
                return
            }

            // Use ImageIO-based downsampling to avoid decoding the full
            // bitmap of 48MP+ photos which would exceed memory limits.
            let downscaled: UIImage? = autoreleasepool {
                if let img = item as? UIImage {
                    // Some apps deliver a pre-decoded UIImage directly.
                    // UIGraphicsImageRenderer (used by downscaleForOCR) needs
                    // BOTH the full-res bitmap and the scaled result in memory
                    // simultaneously — 2× peak, OOM risk on large photos.
                    // Re-encode to JPEG first (avoids holding a second bitmap),
                    // then use ImageIO to thumbnail at decode time — the same
                    // memory-safe path taken by the URL and Data branches below.
                    if let jpegData = img.jpegData(compressionQuality: 0.85),
                       let downsampled = downsampleImageData(jpegData) {
                        return downsampled
                    }
                    // Last-resort fallback if JPEG encode fails.
                    return ReceiptStorage.downscaleForOCR(img)
                }
                if let url = item as? URL {
                    if let data = try? Data(contentsOf: url) {
                        // Use ImageIO to downsample at decode time — never loads full bitmap
                        if let img = downsampleImageData(data) {
                            return img
                        }
                        if let img = UIImage(data: data) {
                            return ReceiptStorage.downscaleForOCR(img)
                        }
                    }
                }
                if let data = item as? Data {
                    // Use ImageIO to downsample at decode time
                    if let img = downsampleImageData(data) {
                        return img
                    }
                    if let img = UIImage(data: data) {
                        return ReceiptStorage.downscaleForOCR(img)
                    }
                }
                return nil
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let downscaled else {
                    self.phase = .failed("Couldn't read the photo")
                    return
                }
                self.content = .image(downscaled)
                self.runImagePipeline(image: downscaled)
            }
        }
    }

    /// Load text from the item provider and run the smart parser on it.
    private func loadText(from provider: NSItemProvider) {
        // Try text first, fall back to URL string. The two types are
        // close cousins on iOS — a URL gets sent as both `public.url`
        // and `public.text`, and loadItem honors whichever we ask for.
        provider.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil) { [weak self] item, _ in
            var text: String? = nil
            if let s = item as? String { text = s }
            if text == nil, let url = item as? URL { text = url.absoluteString }
            if text == nil, let data = item as? Data { text = String(data: data, encoding: .utf8) }

            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.phase = .failed("No text to read")
                    return
                }
                self.content = .text(text)
                self.runTextPipeline(text: text)
            }
        }
    }

    // MARK: - Parsing pipelines

    /// Image pipeline: Vision OCR → regex + smart parser → preview state.
    /// Same logic as the main app's AddExpenseView OCR path. Aggressive
    /// timeouts because the extension only has ~30s before iOS may kill
    /// it; we want save to complete with whatever we got.
    ///
    /// **Memory-bounded**: uses `ReceiptStorage.parseForExtension(_:)`
    /// which downscales the image and skips CoreImage preprocessing.
    /// Share extensions have a ~120MB memory ceiling; full-page hospital
    /// bill screenshots will blow past it if processed at full res.
    private func runImagePipeline(image: UIImage, forceCloudAI: Bool = false) {
        phase = .parsing
        let isDirectImageMode = SmartExpenseParser.hasCloudVision

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try await self?.runImagePipelineInner(
                    image: image,
                    isDirectImageMode: isDirectImageMode,
                    forceCloudAI: forceCloudAI
                )
            } catch {
                await MainActor.run {
                    self?.phase = .failed("Parsing failed")
                }
            }
        }
    }

    private func runImagePipelineInner(image: UIImage,
                                       isDirectImageMode: Bool,
                                       forceCloudAI: Bool) async throws {
        await MainActor.run { [weak self] in self?.parsingStatus = "Preparing image…" }

        let categoryEntries = await Self.loadCategoryEntries()
        let fmContext = await Self.loadFMContext()

        let gateResult: ReceiptStorage.ReceiptLikelihoodResult?
        if isDirectImageMode && !forceCloudAI {
            gateResult = await ReceiptStorage.likelyExpenseDocument(from: image, extensionSafe: true)
        } else {
            gateResult = nil
        }

        let regexResult: ReceiptStorage.ParseResult?
        if isDirectImageMode {
            regexResult = nil
            await MainActor.run { [weak self] in self?.parsingStatus = "Analyzing receipt…" }
        } else {
            await MainActor.run { [weak self] in self?.parsingStatus = "Reading text from image…" }
            // parseForExtension is the memory-safe variant: skips the CoreImage
            // filter chain (which holds 3-5\u00d7 image size in intermediates) and
            // wraps Vision work in autoreleasepool. Calling parse() instead was
            // the root cause of silent OOM kills on the share extension.
            let result = await ReceiptStorage.parseForExtension(image)
            regexResult = result
            await MainActor.run { [weak self] in self?.parsingStatus = "Extracting details…" }
        }

        let smartResult: ReceiptSmartParseResult? = await withTaskGroup(of: ReceiptSmartParseResult?.self) { group in
            group.addTask {
                guard SmartExpenseParser.isAvailable else { return nil }

                if isDirectImageMode {
                    if let gateResult, !gateResult.shouldCallAI {
                        return nil
                    }
                    // Prepare a single optimised JPEG — screenshot-aware size +
                    // quality, optional grayscale for thermal receipts. Passing
                    // skipResize: true tells CloudAIParser not to re-encode,
                    // eliminating the old double-lossy-JPEG-pass.
                    guard let optimizedData = CloudAIParser.prepareImageForGemini(image) else { return nil }
                    return await SmartExpenseParser.parseReceiptImage(
                        optimizedData,
                        categories: categoryEntries,
                        contextBlock: fmContext,
                        skipResize: true
                    )
                }

                guard let regexResult else { return nil }
                return await SmartExpenseParser.parseReceipt(
                    regexResult.rawText,
                    categories: categoryEntries,
                    documentType: regexResult.documentType,
                    contextBlock: fmContext
                )
            }
            group.addTask {
                let timeout: Duration = isDirectImageMode ? .seconds(30) : .seconds(4)
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }



        await MainActor.run { [weak self] in self?.parsingStatus = "Finishing up…" }

        let mergedAmount: Double
        let mergedMerchant: String
        let resolvedDate: Date
        let noteText: String
        let extractedItems: [ReceiptLineItem]

        if isDirectImageMode {
            mergedAmount = smartResult?.amount ?? 0
            mergedMerchant = smartResult?.merchant ?? ""
            resolvedDate = Self.parseISODate(smartResult?.date, time: smartResult?.time) ?? .now
        } else {
            let isStructuredDoc = regexResult?.documentType == .upi
                || regexResult?.documentType == .orderSummary
            if isStructuredDoc, let rgx = regexResult?.amount, rgx > 0 {
                mergedAmount = rgx
            } else {
                mergedAmount = smartResult?.amount ?? regexResult?.amount ?? 0
            }
            if isStructuredDoc, let rgx = regexResult?.merchant, !rgx.isEmpty {
                mergedMerchant = rgx
            } else {
                mergedMerchant = smartResult?.merchant ?? regexResult?.merchant ?? ""
            }
            if let regDate = regexResult?.date {
                let cal = Calendar.current
                let dayComps = cal.dateComponents([.year, .month, .day], from: regDate)
                let nowTime = cal.dateComponents([.hour, .minute, .second], from: .now)
                var merged = dayComps
                merged.hour = nowTime.hour
                merged.minute = nowTime.minute
                merged.second = nowTime.second
                resolvedDate = cal.date(from: merged) ?? regDate
            } else {
                resolvedDate = Self.parseISODate(smartResult?.date, time: smartResult?.time) ?? .now
            }
        }

        if let smart = smartResult, !smart.items.isEmpty {
            extractedItems = smart.items
            let parts = smart.items.map { item in
                let qty = item.quantity > 1 ? " ×\(item.quantity)" : ""
                return "\(item.name)\(qty) ₹\(Int(item.price))"
            }
            noteText = parts.joined(separator: " · ")
        } else if !isDirectImageMode {
            extractedItems = []
            noteText = regexResult?.formattedNote(currencyCode: "INR") ?? ""
        } else {
            extractedItems = []
            noteText = ""
        }

        let resolvedCategoryName: String? = await Self.resolveCategoryName(
            merchant: mergedMerchant,
            fmSuggestion: smartResult?.category
        )

        let warning: String? = await {
            if isDirectImageMode,
               let gateResult,
               !gateResult.shouldCallAI,
               !forceCloudAI {
                return "\(gateResult.reason) Tap Try Again if this is a receipt."
            }
            if smartResult == nil {
                return await MainActor.run { CloudAIParser.lastParseError }
                    ?? "Could not read receipt. Check your connection or try again."
            }
            if isDirectImageMode { return nil }
            let fmHelped = smartResult?.amount != nil && smartResult?.merchant != nil
            if fmHelped { return nil }
            return regexResult?.confidenceReason
        }()

        let (categoryNames, accountEntries, matchedAccountName) = await Self.loadPickerData(
            paymentMode: smartResult?.paymentMode ?? regexResult?.paymentMode,
            cardLast4: smartResult?.cardLast4 ?? regexResult?.cardLast4
        )

        await MainActor.run { [weak self] in
            guard let self else { return }
            self.amount = mergedAmount
            self.merchant = mergedMerchant
            self.date = resolvedDate
            self.note = noteText
            self.items = extractedItems
            self.discount = smartResult?.discount ?? 0
            self.tax = smartResult?.tax ?? 0
            self.categoryName = resolvedCategoryName
            self.usedSmartParser = smartResult != nil
            self.parseWarning = warning
            self.canRetryAIGate = isDirectImageMode
                && (gateResult?.shouldCallAI == false)
                && !forceCloudAI
            self.parsingStatus = ""
            self.availableCategories = categoryNames
            self.availableAccounts = accountEntries
            self.selectedAccountName = matchedAccountName
            self.phase = .preview
        }
    }

    func retryAIGateBypass() {
        guard case .image(let image) = content else { return }
        parseWarning = nil
        canRetryAIGate = false
        runImagePipeline(image: image, forceCloudAI: true)
    }

    /// Text pipeline: smart parser only (no OCR needed). Used for SMS,
    /// chat snippets, copied text. Falls back to a minimal "use as note"
    /// outcome if FM can't structure the text.
    private func runTextPipeline(text: String) {
        phase = .parsing
        Task.detached(priority: .userInitiated) { [weak self] in
            // Load real categories from the shared store so the FM
            // prompt includes hint-augmented descriptions, same as
            // the image pipeline.
            let categoryEntries = await Self.loadCategoryEntries()

            let fmContext = await Self.loadFMContext()

            var parsedAmount: Double = 0
            var parsedMerchant: String = ""
            var fmCategory: String? = nil
            var smartSucceeded = false

            if #available(iOS 26.0, *), SmartExpenseParser.isAvailable {
                let smart = await SmartExpenseParser.parseVoice(
                    text,
                    categories: categoryEntries,
                    accountNames: [],
                    contextBlock: fmContext
                )
                if let smart {
                    parsedAmount = smart.amount
                    parsedMerchant = smart.merchant ?? ""
                    fmCategory = smart.category
                    smartSucceeded = true
                }
            }

            // Same precedence as the image pipeline: MerchantRule first
            // (deterministic, uses learned mappings), FM suggestion second.
            let resolvedCategoryName = await Self.resolveCategoryName(
                merchant: parsedMerchant,
                fmSuggestion: fmCategory
            )

            let (categoryNames, accountEntries, _) = await Self.loadPickerData(paymentMode: nil, cardLast4: nil)

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.amount = parsedAmount
                self.merchant = parsedMerchant
                self.note = parsedAmount > 0 ? "" : text
                self.categoryName = resolvedCategoryName
                self.usedSmartParser = smartSucceeded
                self.availableCategories = categoryNames
                self.availableAccounts = accountEntries
                self.phase = .preview
            }
        }
    }

    // MARK: - Save

    /// Commit the parsed expense to the shared SwiftData store. Posts a
    /// Darwin notification so the main app refreshes if it's running.
    /// Calls onComplete on success, leaves session in `.failed` on error.
    func save() {
        guard amount > 0 else {
            phase = .failed("Amount required")
            return
        }
        phase = .saving

        Task.detached { [weak self] in
            await self?.performSave()
        }
    }

    /// User dismissed without saving.
    func cancel() {
        onCancel()
    }

    @MainActor
    private func performSave() async {
        guard let container = SharedStorage.makeSharedContainer() else {
            phase = .failed("Couldn't open store")
            return
        }

        let context = ModelContext(container)

        // Find or pick a default account + category. The extension
        // doesn't have a UI to pick these, so we use heuristics:
        // - Account: first account by sortOrder (the user's primary)
        // - Category: try to match the FM-suggested name, else "Other"
        let accountFetch = FetchDescriptor<Account>(sortBy: [SortDescriptor(\.sortOrder)])
        let allAccounts = (try? context.fetch(accountFetch))?.filter { !$0.isArchived } ?? []
        let account: Account
        if let selected = selectedAccountName,
           let match = allAccounts.first(where: { $0.name == selected }) {
            account = match
        } else if let first = allAccounts.first {
            account = first
        } else {
            phase = .failed("No account set up")
            return
        }

        let categoryFetch = FetchDescriptor<Category>(sortBy: [SortDescriptor(\.sortOrder)])
        let allCategories = (try? context.fetch(categoryFetch)) ?? []
        let resolvedCategory: Category? = {
            // Exact match first
            if let name = categoryName,
               let exact = allCategories.first(where: { $0.name.lowercased() == name.lowercased() }) {
                return exact
            }
            // Substring overlap fallback
            if let name = categoryName?.lowercased() {
                if let overlap = allCategories.first(where: {
                    let cat = $0.name.lowercased()
                    return name.contains(cat) || cat.contains(name)
                }) {
                    return overlap
                }
            }
            return allCategories.first(where: { $0.name.lowercased() == "other" })
                ?? allCategories.first
        }()

        let expense = Expense(
            amount: amount,
            date: date,
            merchant: merchant.isEmpty ? nil : merchant,
            note: note.isEmpty ? nil : note,
            source: .manual,
            category: resolvedCategory,
            account: account
        )

        // If we have an image, compress it and attach.
        if case .image(let image) = content,
           let data = ReceiptStorage.compress(image) {
            expense.receiptImageData = data
        }

        context.insert(expense)

        do {
            try context.save()
            // Write a fresh widget snapshot and reload timelines immediately.
            // The upcomingRecurrings field is unchanged by adding a one-off
            // expense, so we reuse the existing value from the snapshot.
            let existingUpcoming = WidgetStorage.read().upcomingRecurrings
            WidgetRefresh.refresh(using: context, upcomingRecurrings: existingUpcoming)
            // Also ping the main app (if running) to refresh its @Query views.
            postDarwinNotification(SharedNotifications.didSaveExpense)
            phase = .saved
            // Brief delay so the user sees the "Saved" state before the
            // extension dismisses — feels less abrupt than instant close.
            try? await Task.sleep(for: .milliseconds(600))
            onComplete()
        } catch {
            phase = .failed("Couldn't save expense")
        }
    }

    // MARK: - Helpers

    private static func parseISODate(_ dateString: String?, time timeString: String? = nil) -> Date? {
        guard let dateString, !dateString.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let dateOnly = formatter.date(from: dateString) else { return nil }

        let cal = Calendar.current
        let dayComps = cal.dateComponents([.year, .month, .day], from: dateOnly)

        if let timeString, !timeString.isEmpty {
            let parts = timeString.split(separator: ":").compactMap { Int($0) }
            if parts.count >= 2 {
                var merged = dayComps
                merged.hour = parts[0]
                merged.minute = parts[1]
                return cal.date(from: merged)
            }
        }

        let nowTime = cal.dateComponents([.hour, .minute, .second], from: .now)
        var merged = dayComps
        merged.hour = nowTime.hour
        merged.minute = nowTime.minute
        merged.second = nowTime.second
        return cal.date(from: merged)
    }

    /// Load the user's actual non-archived categories from the shared
    /// SwiftData store. The extension uses these (name + icon key) to
    /// build hint-augmented FM prompts, so the model knows what each
    /// category is FOR — not just its label.
    ///
    /// **Fallback**: if the shared container can't be opened (missing
    /// App Group entitlement, first-launch edge case), returns a
    /// hardcoded set of common categories with sensible icon keys.
    /// The extension still works, just without the user's custom labels.
    private static func loadCategoryEntries() async -> [CategoryEntry] {
        // Default fallback set — used when the shared store isn't
        // accessible for any reason. Keys match the most common
        // SeedData defaults so users with stock categories see no
        // difference between this and the real load.
        let fallback: [CategoryEntry] = [
            CategoryEntry(name: "Food", iconKey: "fork.knife"),
            CategoryEntry(name: "Groceries", iconKey: "basket.fill"),
            CategoryEntry(name: "Transport", iconKey: "car.fill"),
            CategoryEntry(name: "Health", iconKey: "cross.case.fill"),
            CategoryEntry(name: "Shopping", iconKey: "bag.fill"),
            CategoryEntry(name: "Other", iconKey: "tag.fill")
        ]

        return await MainActor.run {
            guard let container = SharedStorage.makeSharedContainer() else {
                return fallback
            }
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<Category>(
                predicate: #Predicate { !$0.isArchived },
                sortBy: [SortDescriptor(\.sortOrder)]
            )
            guard let categories = try? context.fetch(descriptor), !categories.isEmpty else {
                return fallback
            }
            return categories.map {
                CategoryEntry(name: $0.name, iconKey: $0.iconKey)
            }
        }
    }

    private static func loadPickerData(paymentMode: String?, cardLast4: String?) async -> (
        categories: [String],
        accounts: [(name: String, id: UUID)],
        matchedAccount: String?
    ) {
        return await MainActor.run {
            guard let container = SharedStorage.makeSharedContainer() else {
                return ([], [], nil)
            }
            let context = ModelContext(container)

            let catDescriptor = FetchDescriptor<Category>(
                predicate: #Predicate { !$0.isArchived },
                sortBy: [SortDescriptor(\.sortOrder)]
            )
            let categories = (try? context.fetch(catDescriptor)) ?? []
            let catNames = categories.map(\.name)

            let accDescriptor = FetchDescriptor<Account>(sortBy: [SortDescriptor(\.sortOrder)])
            let accounts = (try? context.fetch(accDescriptor))?.filter { !$0.isArchived } ?? []
            let accEntries = accounts.map { (name: $0.name, id: $0.id) }

            // Strategy 1: card_last4 exact match (strongest signal).
            // Gemini extracted the last 4 digits directly from the receipt.
            if let digits = cardLast4, digits.count == 4 {
                if let match = accounts.first(where: {
                    guard let acctDigits = $0.last4Digits, acctDigits.count >= 2 else { return false }
                    return acctDigits.suffix(4) == digits
                }) {
                    return (catNames, accEntries, match.name)
                }
            }

            let generic: Set<String> = [
                "bank", "card", "credit", "debit", "cash", "wallet",
                "account", "savings", "current", "the", "my", "upi"
            ]

            // Strategy 2: partial digit suffix (2-3 digits) + name match.
            // When only 2-3 digits were extracted, combine with card-name
            // matching for a confident result.
            if let digits = cardLast4, digits.count >= 2, digits.count < 4,
               let mode = paymentMode?.lowercased(), !mode.isEmpty {
                for account in accounts {
                    guard let acctDigits = account.last4Digits, acctDigits.count >= 2 else { continue }
                    guard acctDigits.hasSuffix(digits) else { continue }
                    let words = account.name
                        .lowercased()
                        .components(separatedBy: .alphanumerics.inverted)
                        .filter { $0.count >= 3 && !generic.contains($0) }
                    if words.contains(where: { mode.contains($0) }) {
                        return (catNames, accEntries, account.name)
                    }
                }
            }

            // Strategy 3: name-word match against paymentMode.
            if let mode = paymentMode?.lowercased(), !mode.isEmpty {
                var bestAccount: Account?
                var bestScore = 0
                for account in accounts {
                    let words = account.name
                        .lowercased()
                        .components(separatedBy: .alphanumerics.inverted)
                        .filter { $0.count >= 3 && !generic.contains($0) }
                    var score = words.filter { mode.contains($0) }.count
                    // Boost accounts with partial digit match.
                    if let digits = cardLast4, digits.count >= 2,
                       let acctDigits = account.last4Digits,
                       acctDigits.hasSuffix(digits) {
                        score += 2
                    }
                    if score > bestScore {
                        bestScore = score
                        bestAccount = account
                    }
                }
                if let match = bestAccount {
                    return (catNames, accEntries, match.name)
                }
            }

            return (catNames, accEntries, nil)
        }
    }

    /// Build FM context including merchant history from the shared DB.
    /// Falls back to time-only context if the shared container can't be
    /// opened. Uses the same `FMContextBuilder.build(modelContext:)` as
    /// the main app so the Gemini prompt includes frequent merchants,
    /// category patterns, and recent activity.
    private static func loadFMContext() async -> String {
        return await MainActor.run {
            guard let container = SharedStorage.makeSharedContainer() else {
                return FMContextBuilder.buildTimeOnly()
            }
            let context = ModelContext(container)
            return FMContextBuilder.build(modelContext: context)
        }
    }

    /// Resolve a category name using the same priority chain as the main
    /// app's AddExpenseView:
    ///   1. MerchantRule lookup — deterministic, uses learned mappings
    ///      (e.g., "BPCL" → Transport from prior expenses)
    ///   2. FM's category suggestion — when no rule matched
    ///   3. nil — caller falls back to "Other" at save time
    ///
    /// Returns the resolved category NAME (string), not the SwiftData
    /// Category entity, because the UI only needs the name for preview
    /// rendering. The actual Category object gets re-resolved at save
    /// time in `performSave` via name lookup.
    private static func resolveCategoryName(merchant: String,
                                             fmSuggestion: String?) async -> String? {
        // MerchantRule lookup needs main-actor access to the ModelContext.
        let ruleName: String? = await MainActor.run {
            guard let container = SharedStorage.makeSharedContainer() else { return nil }
            let context = ModelContext(container)
            return MerchantRuleResolver.categoryName(for: merchant, in: context)
        }
        if let ruleName, !ruleName.isEmpty {
            return ruleName
        }
        // Fall back to FM's suggestion when no rule matched.
        return fmSuggestion
    }
}
