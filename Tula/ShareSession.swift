import Foundation
import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import UIKit
import Combine
import os.log

private let shareLog = Logger(subsystem: "com.app.alpha.Tula.TulaShare", category: "ShareSession")

// MARK: - Crash Log Writer

/// Writes diagnostic info to a log file in the shared App Group container
/// so the user can find it in Files app. Each share attempt appends to the
/// same file with a timestamp separator.
private enum ShareCrashLog {
    static func write(_ message: String) {
        let groupID = "group.com.app.alpha.Tula"
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupID
        ) else {
            shareLog.error("Cannot write crash log — no App Group container")
            return
        }

        let logDir = containerURL.appendingPathComponent("ShareLogs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        let logFile = logDir.appendingPathComponent("share_debug.log")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = """
        
        ── [\(timestamp)] ──────────────────────────
        \(message)
        
        """

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
        shareLog.info("Wrote crash log entry to \(logFile.path)")
    }
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
    @Published var items: [ReceiptLineItem] = []
    @Published var parsingStatus: String = ""

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
        shareLog.info("start() called")
        ShareCrashLog.write("Share extension started")
        guard let items = extensionContext?.inputItems as? [NSExtensionItem],
              !items.isEmpty else {
            shareLog.error("No input items from extensionContext")
            phase = .failed("Nothing shared")
            return
        }

        // Find the first attachment that matches a type we handle.
        // Images take priority over text — if the user shared both
        // (rare, possible via custom share sources), we use the image
        // because it has richer parseable data via OCR.
        let providers = items.flatMap { $0.attachments ?? [] }
        shareLog.info("Found \(providers.count) provider(s)")
        for (i, p) in providers.enumerated() {
            shareLog.info("  Provider[\(i)] types: \(p.registeredTypeIdentifiers)")
        }

        if let imageProvider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }) {
            shareLog.info("Matched image provider, loading image...")
            loadImage(from: imageProvider)
        } else if let textProvider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.text.identifier) }) {
            shareLog.info("Matched text provider")
            loadText(from: textProvider)
        } else if let urlProvider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
            shareLog.info("Matched URL provider")
            loadText(from: urlProvider)
        } else {
            shareLog.error("No matching provider found for image/text/url")
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
        shareLog.info("loadImage: using typeID=\(typeID) from registered=\(provider.registeredTypeIdentifiers)")

        provider.loadItem(forTypeIdentifier: typeID, options: nil) { [weak self] item, error in
            if let error {
                shareLog.error("loadItem failed: \(error.localizedDescription)")
                ShareCrashLog.write("loadItem error: \(error.localizedDescription)\ntypeID: \(typeID)")
                Task { @MainActor in
                    self?.phase = .failed("Failed to load image: \(error.localizedDescription)")
                }
                return
            }
            shareLog.info("loadItem returned item type: \(String(describing: type(of: item)))")

            // `loadItem` returns various types — could be a URL to the
            // image file, the raw Data, or a UIImage. Handle all cases.
            let image: UIImage? = {
                if let img = item as? UIImage {
                    shareLog.info("Item is UIImage")
                    return img
                }
                if let url = item as? URL {
                    shareLog.info("Item is URL: \(url.path)")
                    if let data = try? Data(contentsOf: url) {
                        shareLog.info("Read \(data.count) bytes from URL")
                        return UIImage(data: data)
                    } else {
                        shareLog.error("Failed to read data from URL")
                    }
                }
                if let data = item as? Data {
                    shareLog.info("Item is Data: \(data.count) bytes")
                    return UIImage(data: data)
                }
                shareLog.error("Item is unrecognized type, returning nil")
                return nil
            }()

            let downscaled: UIImage? = autoreleasepool {
                guard let image else {
                    ShareCrashLog.write("UIImage decode returned nil.\nItem type: \(String(describing: type(of: item)))\ntypeID: \(typeID)")
                    return nil
                }
                let size = image.size
                shareLog.info("Raw image size: \(Int(size.width))x\(Int(size.height)), scale=\(image.scale)")
                let result = ReceiptStorage.downscaleForOCR(image)
                if result == nil {
                    ShareCrashLog.write("downscaleForOCR returned nil.\nOriginal size: \(Int(size.width))x\(Int(size.height))")
                }
                return result
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let downscaled else {
                    shareLog.error("UIImage creation/downscale failed")
                    ShareCrashLog.write("Final image nil — could not create UIImage from shared content.\ntypeID: \(typeID)")
                    self.phase = .failed("Couldn't read the photo — see share_debug.log")
                    return
                }
                shareLog.info("Image loaded: \(Int(downscaled.size.width))x\(Int(downscaled.size.height))")
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
    private func runImagePipeline(image: UIImage) {
        phase = .parsing
        shareLog.info("runImagePipeline started")
        let isDirectImageMode = SmartExpenseParser.hasCloudVision

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try await self?.runImagePipelineInner(image: image, isDirectImageMode: isDirectImageMode)
            } catch {
                let msg = "runImagePipeline crashed: \(error.localizedDescription)\n\(String(describing: error))"
                shareLog.error("\(msg)")
                ShareCrashLog.write(msg)
                await MainActor.run {
                    self?.phase = .failed("Parsing failed — check share_debug.log")
                }
            }
        }
    }

    private func runImagePipelineInner(image: UIImage, isDirectImageMode: Bool) async throws {
        await MainActor.run { [weak self] in self?.parsingStatus = "Preparing image…" }

        let categoryEntries = await Self.loadCategoryEntries()
        let fmContext = await Self.loadFMContext()

        let regexResult: ReceiptStorage.ParseResult?
        if isDirectImageMode {
            regexResult = nil
            shareLog.info("Skipping OCR — direct image mode active")
            await MainActor.run { [weak self] in self?.parsingStatus = "Analyzing receipt…" }
        } else {
            await MainActor.run { [weak self] in self?.parsingStatus = "Reading text from image…" }
            shareLog.info("Running OCR via ReceiptStorage.parse...")
            let result = await ReceiptStorage.parse(image)
            shareLog.info("OCR done. rawText length=\(result.rawText.count), amount=\(String(describing: result.amount)), merchant=\(String(describing: result.merchant))")
            regexResult = result
            await MainActor.run { [weak self] in self?.parsingStatus = "Extracting details…" }
        }

        let smartResult: ReceiptSmartParseResult? = await withTaskGroup(of: ReceiptSmartParseResult?.self) { group in
            group.addTask {
                guard SmartExpenseParser.isAvailable else { return nil }

                if isDirectImageMode,
                   let jpegData = image.jpegData(compressionQuality: 0.85) {
                    return await SmartExpenseParser.parseReceiptImage(jpegData, categories: categoryEntries, contextBlock: fmContext)
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

        if smartResult == nil {
            shareLog.error("smartResult is nil — Gemini call failed or timed out")
            ShareCrashLog.write("Smart parse returned nil.\nisAvailable=\(SmartExpenseParser.isAvailable)\nisDirectImage=\(isDirectImageMode)\nregexResult rawText length=\(regexResult?.rawText.count ?? -1)")
        } else {
            shareLog.info("smartResult: amount=\(smartResult!.amount), merchant=\(smartResult?.merchant ?? "nil"), items=\(smartResult!.items.count)")
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
            resolvedDate = Self.parseISODate(smartResult?.date) ?? .now
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
            resolvedDate = regexResult?.date ?? Self.parseISODate(smartResult?.date) ?? .now
        }

        if let smart = smartResult, !smart.items.isEmpty {
            extractedItems = smart.items
            let parts = smart.items.map { "\($0.name) ₹\(Int($0.price))" }
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

        let warning: String? = {
            if smartResult == nil {
                return "Could not read receipt — check your connection or try again."
            }
            if isDirectImageMode { return nil }
            let fmHelped = smartResult?.amount != nil && smartResult?.merchant != nil
            if fmHelped { return nil }
            return regexResult?.confidenceReason
        }()

        await MainActor.run { [weak self] in
            guard let self else { return }
            self.amount = mergedAmount
            self.merchant = mergedMerchant
            self.date = resolvedDate
            self.note = noteText
            self.items = extractedItems
            self.categoryName = resolvedCategoryName
            self.usedSmartParser = smartResult != nil
            self.parseWarning = warning
            self.parsingStatus = ""
            self.phase = .preview
        }
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

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.amount = parsedAmount
                self.merchant = parsedMerchant
                self.note = parsedAmount > 0 ? "" : text  // raw text as note if we couldn't parse
                self.categoryName = resolvedCategoryName
                self.usedSmartParser = smartSucceeded
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
        guard let account = try? context.fetch(accountFetch).first(where: { !$0.isArchived }) else {
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
            // Ping the main app to refresh @Query views if it's running.
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

    /// Parse YYYY-MM-DD from FM into a Date. Returns nil for nil/invalid.
    private static func parseISODate(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)
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
