import Foundation
import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import UIKit
import Combine

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

        // Find the first attachment that matches a type we handle.
        // Images take priority over text — if the user shared both
        // (rare, possible via custom share sources), we use the image
        // because it has richer parseable data via OCR.
        let providers = items.flatMap { $0.attachments ?? [] }

        if let imageProvider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }) {
            loadImage(from: imageProvider)
        } else if let textProvider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.text.identifier) }) {
            loadText(from: textProvider)
        } else if let urlProvider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
            // URLs are converted to text — the URL string is what the
            // user is sharing, often a confirmation page or similar.
            loadText(from: urlProvider)
        } else {
            phase = .failed("Couldn't read what you shared")
        }
    }

    /// Load image bytes from the item provider, decode to UIImage,
    /// then run the OCR + smart parser pipeline.
    private func loadImage(from provider: NSItemProvider) {
        provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { [weak self] item, error in
            // `loadItem` returns various types — could be a URL to the
            // image file, the raw Data, or a UIImage. Handle all cases.
            let image: UIImage? = {
                if let img = item as? UIImage { return img }
                if let url = item as? URL, let data = try? Data(contentsOf: url) {
                    return UIImage(data: data)
                }
                if let data = item as? Data { return UIImage(data: data) }
                return nil
            }()

            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let image else {
                    self.phase = .failed("Couldn't read the photo")
                    return
                }
                self.content = .image(image)
                self.runImagePipeline(image: image)
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
    private func runImagePipeline(image: UIImage) {
        phase = .parsing
        Task.detached(priority: .userInitiated) { [weak self] in
            let regexResult = await ReceiptStorage.parse(image)

            // Load the user's actual categories from the shared store
            // so the FM prompt gets icon-derived hints. Falls back to
            // a hardcoded set if the container can't be opened (rare,
            // but the extension must keep working).
            let categoryEntries = await Self.loadCategoryEntries()

            // FM is optional. Race against a 4s timeout so the extension
            // doesn't sit indefinitely waiting for Apple Intelligence.
            // Shorter than the main app's 6s because we have less runway.
            let smartResult: ReceiptSmartParseResult? = await withTaskGroup(of: ReceiptSmartParseResult?.self) { group in
                group.addTask {
                    guard #available(iOS 26.0, *), SmartExpenseParser.isAvailable else { return nil }
                    return await SmartExpenseParser.parseReceipt(
                        regexResult.rawText,
                        categories: categoryEntries,
                        documentType: regexResult.documentType
                    )
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(4))
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }

            // Doubling guard (same as main app) — if FM returned 2× regex,
            // trust regex.
            let mergedAmount: Double
            if let smart = smartResult?.amount, let rgx = regexResult.amount,
               smart > 0, rgx > 0, abs(smart - 2 * rgx) < 2 {
                mergedAmount = rgx
            } else {
                mergedAmount = smartResult?.amount ?? regexResult.amount ?? 0
            }

            let mergedMerchant = smartResult?.merchant ?? regexResult.merchant ?? ""
            let resolvedDate = regexResult.date ?? Self.parseISODate(smartResult?.date) ?? .now

            // Build note text from items if available. Long lists
            // get truncated to "first 5 · and N more" to keep the note
            // readable — full inventory is still in the attached receipt
            // photo for the user to review.
            let noteText: String
            if let smart = smartResult, !smart.items.isEmpty {
                let parts = smart.items.map { "\($0.name) ₹\(Int($0.price))" }
                let maxInline = 5
                if parts.count > maxInline {
                    let visible = parts.prefix(maxInline).joined(separator: " · ")
                    let remaining = parts.count - maxInline
                    noteText = "\(visible) · and \(remaining) more item\(remaining == 1 ? "" : "s")"
                } else {
                    noteText = parts.joined(separator: " · ")
                }
            } else {
                noteText = regexResult.formattedNote(currencyCode: "INR") ?? ""
            }

            // Resolve category with same precedence as the main app:
            // 1. MerchantRule pre-check (deterministic, uses learned mappings)
            // 2. FM suggestion (when no rule matched)
            // The MainActor hop is necessary because MerchantRuleResolver
            // requires a ModelContext.
            let resolvedCategoryName: String? = await Self.resolveCategoryName(
                merchant: mergedMerchant,
                fmSuggestion: smartResult?.category
            )

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.amount = mergedAmount
                self.merchant = mergedMerchant
                self.date = resolvedDate
                self.note = noteText
                self.categoryName = resolvedCategoryName
                self.usedSmartParser = smartResult != nil
                self.phase = .preview
            }
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

            var parsedAmount: Double = 0
            var parsedMerchant: String = ""
            var fmCategory: String? = nil
            var smartSucceeded = false

            if #available(iOS 26.0, *), SmartExpenseParser.isAvailable {
                let smart = await SmartExpenseParser.parseVoice(
                    text,
                    categories: categoryEntries,
                    accountNames: []
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
