import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple Foundation Models integration for natural-language expense parsing.
///
/// **Layered design.** This is a *layer on top of* the rule-based
/// `ExpenseParser`, not a replacement. Rules handle 90%+ of common cases
/// instantly (<1ms). Foundation Models gets invoked only when:
///   - The device has Apple Intelligence available, AND
///   - Apple Intelligence is enabled in Settings, AND
///   - The user has the "Smart parsing" toggle on (default: on), AND
///   - The rule-based parser couldn't confidently categorize the input.
///
/// On older devices (iPhone 12, 13, 14, 15 non-Pro, etc.) the entire layer
/// short-circuits via `isAvailable == false` — the app falls back to
/// rule-based parsing only. No errors, no banner, no degradation. Apple's
/// own design philosophy: Apple Intelligence is additive, never required.
///
/// **Latency note.** A single FM parse is ~100-500ms on supported devices.
/// We never invoke it on the main thread, never block the save flow on it,
/// and never call it for inputs the rules already handled.
///
/// **Availability**: the enum itself has no `@available` annotation so
/// its public functions (`parseVoice`, `parseReceipt`, `isAvailable`)
/// can be called from any iOS 17+ deployment target. Each function is
/// internally gated with `#if canImport(FoundationModels)` and
/// `#available(iOS 26.0, *)` checks, returning nil on systems that
/// don't have FM. Callers can invoke these unconditionally.
enum SmartExpenseParser {

    // MARK: - Availability

    /// Whether smart parsing is currently usable — either via FM or cloud.
    ///
    /// Returns true when:
    /// - Foundation Models is available on this device, OR
    /// - The user has a cloud AI provider configured with a valid API key
    static var isAvailable: Bool {
        if hasCloudVision { return true }
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return false }
        if case .available = SystemLanguageModel.default.availability {
            return true
        }
        return false
        #else
        return false
        #endif
    }

    /// Best provider — prefers Gemini when configured, falls through to
    /// on-device FM when no cloud key is present. Without this fallback,
    /// the default `AIProviderStorage.selected` (.gemini) would silently
    /// fail on devices that have FM but no API key, causing the caller
    /// to fall back to rules and skip FM entirely.
    private static var bestProvider: AIProvider {
        let selected = AIProviderStorage.selected
        if selected.isReady { return selected }
        // Fallback chain
        if !CloudAIConfig.loadGemini().apiKey.isEmpty { return .gemini }
        if !CloudAIConfig.load().apiKey.isEmpty { return .openAI }
        if isFMAvailable { return .appleFM }
        return selected
    }

    /// Whether any cloud vision-capable provider is configured.
    static var hasCloudVision: Bool {
        !CloudAIConfig.loadGemini().apiKey.isEmpty
        || !CloudAIConfig.load().apiKey.isEmpty
    }

    /// Whether Foundation Models specifically is available on-device.
    static var isFMAvailable: Bool {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return false }
        if case .available = SystemLanguageModel.default.availability {
            return true
        }
        return false
        #else
        return false
        #endif
    }

    /// Human-readable description of why the model is unavailable.
    /// Nil when available. Surfaced in Settings so users on supported
    /// devices know what to enable.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else {
            return "Apple Intelligence requires iOS 26 or later."
        }
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is off. Enable it in Settings → Apple Intelligence & Siri."
        case .unavailable(.deviceNotEligible):
            return "This device doesn't support Apple Intelligence. Tula falls back to its built-in parser."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is downloading. Smart parsing will turn on automatically when it's ready."
        case .unavailable(_):
            return "Apple Intelligence is unavailable."
        @unknown default:
            return "Apple Intelligence is unavailable."
        }
        #else
        return "Apple Intelligence is unavailable on this build."
        #endif
    }

    // MARK: - Parsing

    /// Parse a free-text expense input via Foundation Models, constrained
    /// to the user's category list so the model can't invent categories.
    ///
    /// - Parameters:
    ///   - input: Raw user input — e.g. "spent 350 on lunch with team at sagar ratna".
    ///   - categories: User's actual categories (name + icon key). The
    ///     icon key drives hint-augmented prompt construction so the
    ///     model knows what each category is FOR. Model selects from
    ///     these by name (never invents new categories).
    /// - Returns: Parsed result or nil if unavailable / failed / timeout.
    ///
    /// **Failure is silent.** This method must never throw to its caller —
    /// the call site falls back to rules. If FM hiccups, the user still
    /// gets a working save flow.
    static func parse(_ input: String,
                      categories: [CategoryEntry],
                      contextBlock: String = "") async -> SmartParseResult? {
        switch bestProvider {
        case .gemini:
            return await CloudAIParser.parse(input, categories: categories, accountNames: [], isVoice: false, contextBlock: contextBlock, config: .loadGemini())
        case .openAI:
            return await CloudAIParser.parse(input, categories: categories, accountNames: [], isVoice: false, contextBlock: contextBlock)
        case .appleFM:
            return await parse(input, categories: categories, accountNames: [], contextBlock: contextBlock, isVoice: false)
        }
    }

    /// Voice-specific parse. Identical schema, but the instructions tell
    /// the model to expect noisy speech-recognition output — homophones
    /// ("waffle" mistranscribed as "rahul"), split digits ("1 20" meant
    /// as "120"), and conversational phrasing. The model uses the
    /// category and account lists as anchors to correct context-sensitive
    /// errors. Use this instead of `parse(_:categories:)` for
    /// voice-sourced input where text quality is lower.
    ///
    /// - Parameters:
    ///   - input: The raw speech transcript.
    ///   - categories: User's actual categories (name + icon key for
    ///     hint-augmented prompts).
    ///   - accountNames: User's actual account names (Bank, Cash, etc.) so
    ///     the model can correctly identify which account was charged when
    ///     mentioned in the transcript ("paid from HDFC", "in cash", etc.).
    static func parseVoice(_ input: String,
                            categories: [CategoryEntry],
                            accountNames: [String],
                            contextBlock: String = "") async -> SmartParseResult? {
        switch bestProvider {
        case .gemini:
            return await CloudAIParser.parse(input, categories: categories, accountNames: accountNames, isVoice: true, contextBlock: contextBlock, config: .loadGemini())
        case .openAI:
            return await CloudAIParser.parse(input, categories: categories, accountNames: accountNames, isVoice: true, contextBlock: contextBlock)
        case .appleFM:
            return await parse(input, categories: categories,
                        accountNames: accountNames, contextBlock: contextBlock, isVoice: true)
        }
    }

    /// Multi-expense voice parse. Extracts TWO or more expenses from a
    /// single voice transcript that contains conjunctions ("350 food and
    /// 400 groceries"). Uses a single FM call so the model can apply
    /// cross-expense context (e.g. "from cash" at the end applies to all).
    ///
    /// Falls back to nil on older devices or when FM is unavailable.
    /// Callers should fall back to rule-parsed results on nil.
    static func parseVoiceMulti(
        _ input: String,
        categories: [CategoryEntry],
        accountNames: [String],
        contextBlock: String = ""
    ) async -> [SmartParseResult]? {
        switch bestProvider {
        case .gemini:
            return await CloudAIParser.parseVoiceMulti(
                input, categories: categories, accountNames: accountNames,
                contextBlock: contextBlock, config: .loadGemini()
            )
        case .openAI:
            return await CloudAIParser.parseVoiceMulti(
                input, categories: categories, accountNames: accountNames,
                contextBlock: contextBlock
            )
        case .appleFM:
            return await parseMulti(input, categories: categories,
                                    accountNames: accountNames,
                                    contextBlock: contextBlock)
        }
    }

    /// **Receipt parsing pass** — runs Foundation Models on the raw OCR'd
    /// text from a receipt photo. Different signature from `parseVoice`
    /// because receipts have richer structure (line items + a transaction
    /// date) that voice transcripts lack.
    ///
    /// **When to use this**: after `ReceiptStorage.parse` has done its
    /// regex pass. Pass the `rawText` from that result here. FM will
    /// produce a structured result that the caller can merge with the
    /// regex result.
    ///
    /// **Returns** a `ReceiptSmartParseResult` DTO (plain Swift, no FM
    /// dependencies). This means callers can be deployment-target ≥ iOS
    /// 17 even though the underlying FM model requires iOS 26 — the
    /// availability gating lives entirely inside this function.
    ///
    /// **Failure modes**: nil return covers FM unavailable, FM timeout,
    /// or empty input. Caller falls back to regex-only result.
    static func parseReceipt(_ rawText: String,
                              categories: [CategoryEntry],
                              documentType: ReceiptStorage.DocumentType = .generic,
                              contextBlock: String = "") async -> ReceiptSmartParseResult? {
        switch bestProvider {
        case .gemini:
            let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !categories.isEmpty else { return nil }
            return await CloudAIParser.parseReceipt(trimmed, categories: categories, documentType: documentType, contextBlock: contextBlock, config: .loadGemini())
        case .openAI:
            let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !categories.isEmpty else { return nil }
            return await CloudAIParser.parseReceipt(trimmed, categories: categories, documentType: documentType, contextBlock: contextBlock)
        case .appleFM:
            break
        }

        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *), isAvailable else { return nil }
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !categories.isEmpty else { return nil }

        // Build the rich category list with icon-derived hints. Each
        // category appears as "- Name (hint keywords)" so the model
        // knows what each category is FOR, not just its name. This
        // turns "Transport" from an opaque label into a meaningful
        // bucket the model can confidently route petrol/fuel/cab
        // expenses into.
        let categoryList = CategoryHint.formatList(
            categories.map { (name: $0.name, iconKey: $0.iconKey) }
        )

        // **Known-merchant detection**: if the receipt text contains a
        // brand name we recognize from `ReceiptMeta.knownMerchantCategories`,
        // surface that as a strong hint to the FM. Even if the merchant
        // extractor misses the brand (because it's mid-document, not in
        // the header), the FM can use this signal to set the right
        // category. Multiple matches → take the first (most specific
        // brand wins because dictionary iteration order is unstable;
        // good enough for hinting).
        let lowerText = trimmed.lowercased()
        let detectedBrandHint: String = {
            for (brand, category) in ReceiptMeta.knownMerchantCategories {
                if lowerText.contains(brand) {
                    return "\n\nDETECTED BRAND: The text contains \"\(brand)\" — a known brand typically in category \"\(category)\". Use this as a STRONG hint when picking the category and merchant. If a more specific merchant name is also present, prefer that for the merchant field, but the category hint stands."
                }
            }
            return ""
        }()

        // Per-document-type hint added to the prompt. Tells the model
        // what layout to expect, which improves accuracy especially on
        // UPI screenshots and order summaries (where the "receipt"
        // mental model would be misleading). Generic docs get no hint.
        let layoutHint: String = {
            switch documentType {
            case .upi:
                return """
                LAYOUT: This is a UPI payment confirmation screenshot \
                (PhonePe / GPay / Paytm / bank app). The amount is the \
                prominent number near the top (often after "₹"). The \
                merchant is the value after "Paid to" / "To" / \
                "Transferred to". There are no line items — return \
                items: []. Date is the transaction timestamp.

                CATEGORY GUIDANCE FOR UPI: items will be empty, so use \
                EVERYTHING ELSE in the text to decide the category:
                  - Transaction notes / payment messages ("for petrol", \
                    "lunch", "auto fare") — these are STRONG signals
                  - UPI handle / VPA domain (e.g., @paytm, @oksbi, \
                    @ybl) — usually neutral, ignore
                  - Merchant name patterns:
                    * "stores", "kirana", "supermarket" → Groceries
                    * "petrol", "fuel", "HP", "BPCL", "IOC" → Transport
                    * "restaurant", "cafe", "kitchen", "biryani", \
                      "dosa", food chain name → Food & Drinks
                    * "pharmacy", "medical", "hospital", "clinic" → Health
                    * "electricity", "BSES", "TSSPDCL" → Bills
                    * Individual person's name (no business indicator) → \
                      leave category nil/empty if no clear context
                  - When the merchant is an individual's name with no \
                    other context, it's BETTER to return no category \
                    than guess wrong. The user can categorize it.
                """
            case .orderSummary:
                return """
                LAYOUT: This is a food / grocery delivery order summary \
                (Swiggy / Zomato / Blinkit / Zepto / Instamart). The \
                grand total is at the BOTTOM, labeled "Bill Total" / \
                "Total Paid" / "Amount Paid". The merchant is the \
                restaurant/store name (NOT the delivery app brand). \
                Items are listed mid-page.
                """
            case .restaurantBill:
                return """
                LAYOUT: This is a printed restaurant or kirana bill. \
                Merchant is at the top in larger text. Line items \
                appear with prices in a column layout. The grand total \
                is at the bottom, often labeled "Grand Total" / \
                "Bill Amount" / "Net Total".
                """
            case .hospitalBill:
                return """
                LAYOUT: This is a hospital / clinic / diagnostics bill. \
                Multiple sub-sections (consultation, lab tests, pharmacy, \
                room charges, taxes, discounts, advance paid). The \
                FINAL payable is at the BOTTOM, labeled "Net Payable" / \
                "Amount Payable" / "Final Amount" / "Balance Due". \
                Merchant = the hospital name (top header). Items = \
                the services / procedures / medicines listed. SKIP \
                patient details (name, ID, ward) — those are not items.
                """
            case .utilityBill:
                return """
                LAYOUT: This is a utility bill (electricity, water, gas, \
                broadband, mobile). One main amount labeled "Amount Due" / \
                "Total Payable" / "Bill Amount", accompanied by a due \
                date. Merchant = utility provider name. items: [] (no \
                line items in the typical sense). Category should be \
                "Bills" / "Utilities" / similar.
                """
            case .generic:
                return ""
            }
        }()

        // Role preamble + context for the receipt path (same pattern
        // as the voice path, but tuned for OCR'd receipt text).
        let rolePreamble = """
        You are TULA's senior receipt parser. You have ONE job: extract \
        precise, structured data from OCR'd receipt text. You are careful, \
        deterministic, and willing to return nil rather than guess wrong.

        Your output goes DIRECTLY into the user's expense database with \
        no review. Wrong values create rework — the user must fix them \
        manually. Aim to be RIGHT, not creative.

        OCR is imperfect — characters may be garbled. Read the text \
        carefully; the actual receipt was clear, only the recognition \
        is noisy.
        """
        let contextSection = ""

        let instructions = """
        \(rolePreamble)
        \(contextSection)
        Parse this OCR'd receipt text into structured data. Fields:

        - **amount**: the GRAND TOTAL — the final amount billed. ONE \
          value, printed verbatim on the receipt. NEVER sum two values \
          to derive it. Cross-check by summing items: the total should \
          approximately equal the items sum (allow ±25% for tax).

        - **merchant**: business / place name. Title-cased. Rules:
            * PRIMARY: use the actual business name if present on the \
              receipt (usually top header or "Paid to" label).
            * If NO clear business name appears, INFER a GENERIC PLACE \
              TYPE from the items: "Restaurant", "Pharmacy", "Grocery \
              Store", "Hospital", "Petrol Pump", etc. A guess is more \
              useful than nil — the user can correct it.
            * If a merchant in the FREQUENT MERCHANTS list (above) \
              appears in the OCR text — even mangled — use the canonical \
              spelling.
            * NEVER use a dish, product, or document-type label \
              ("Cash Bill", "Tax Invoice") as the merchant.

        - **date**: transaction date in YYYY-MM-DD format. Nil if not present.

        - **items**: purchased items as {name, price}.
            * EXCLUDE tax, subtotal, total, discount, change, and \
              payment-method lines.
            * For LONG item lists (groceries, hospital bills with many \
              line items), return ALL items — don't truncate. The \
              caller will display them appropriately.
            * For complex bills (hospital, utility), only include \
              actual services/products purchased. Skip header rows, \
              metadata, patient info, etc.

        - **category**: pick ONE from the list below. Decision priority:
            1. If MERCHANT is clear and matches a category's keywords \
               (e.g., "Apollo Pharmacy" → Health), use that.
            2. If MERCHANT is unclear or generic, use the ITEMS to \
               decide. Items like "MRI / consultation / medicine" → \
               Health. Items like "fuel / diesel / petrol" → Transport. \
               Items like "tomato / onion / dal" → Groceries.
            3. If ITEMS are unclear too, use ANY other signal in the \
               text (document headers, footer markers, payment app).
            4. NEVER invent a category not in this list.
            5. **Prefer nil over a bad guess.** If after applying steps \
               1-3 you're STILL guessing without solid evidence, return \
               nil for category. A wrong category costs the user a \
               correction; nil costs them a one-tap selection. Wrong \
               is worse. Only commit to a category when at least one \
               signal in the text clearly aligns with that category's \
               hint keywords.

        Available categories (parenthesized keywords describe what fits):
        \(categoryList)

        \(layoutHint)\(detectedBrandHint)

        KEY RULES:
        1. **Same value appearing twice = one bill, not double.** If "140" \
           appears as both subtotal and grand total, the amount is 140. \
           Returning 280 (the sum) is wrong.
        2. **Amount must be printed verbatim** somewhere in the OCR text. \
           If you're tempted to do arithmetic, stop — pick the value next \
           to "Total" / "Grand Total" / "Net Payable" / "Amount Due".
        3. **OCR digit errors**: "1" may appear as "I" / "l" / "|", "0" as \
           "O", "5" as "S", "8" as "B". Recover these in numeric contexts.
        4. **Leading "1" sometimes dropped** (140 → 40). If the total looks \
           too small to match the items sum, prefer the larger candidate \
           near the total marker.
        5. **For complex multi-section bills** (hospital, utility), the \
           FINAL net payable is at the BOTTOM. Earlier sub-totals \
           (consultation total, lab total, etc.) are NOT the amount. \
           Look for the BOTTOMMOST line with a final-payable label.

        EXAMPLE (the receipt format that trips most parsers):
        Input contains: "40 50 50 140 140 Subtotal: Grand Total: UPI"
        Items: Masala Puri 40, Papdi Chat 50, Samosa Chat 50 (sum=140).
        Subtotal 140 and Grand Total 140 are the SAME value printed twice.
        amount = 140, NOT 280.
        """

        do {
            let session = LanguageModelSession(model: SystemLanguageModel.default,
                                                instructions: instructions)
            let response = try await session.respond(to: trimmed,
                                                      generating: _FMReceiptResult.self)
            let fm = response.content
            // Convert FM-specific result into the plain DTO so the
            // caller doesn't have to deal with @Generable types or
            // iOS 26 availability gating.
            return ReceiptSmartParseResult(
                amount: fm.amount ?? 0,
                merchant: fm.merchant,
                date: fm.date,
                time: nil,
                category: fm.category,
                paymentMode: nil,
                cardLast4: nil,
                items: fm.items.map { ReceiptLineItem(name: $0.name, price: $0.price) },
                discount: nil,
                tax: nil
            )
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    // MARK: - Image-Based Receipt Parsing

    /// Parse a receipt by sending the image directly to the cloud AI model.
    /// Only used when `ReceiptParsingModeStorage.selected == .directImage`
    /// and a cloud provider is active. Apple FM always uses OCR text.
    /// - Parameter skipResize: Pass `true` when the image has already been
    ///   optimised by `CloudAIParser.prepareImageForGemini`. CloudAIParser will
    ///   skip its internal resizeImageData pass, eliminating a second lossy
    ///   JPEG encode. Default `false` preserves the existing main-app behaviour.
    static func parseReceiptImage(_ imageData: Data,
                                   categories: [CategoryEntry],
                                   contextBlock: String = "",
                                   skipResize: Bool = false) async -> ReceiptSmartParseResult? {
        guard !categories.isEmpty, !imageData.isEmpty else { return nil }

        switch bestProvider {
        case .gemini:
            return await CloudAIParser.parseReceiptImage(imageData, categories: categories, contextBlock: contextBlock, config: .loadGemini(), skipResize: skipResize)
        case .openAI:
            return await CloudAIParser.parseReceiptImage(imageData, categories: categories, contextBlock: contextBlock, skipResize: skipResize)
        case .appleFM:
            return nil
        }
    }

    /// **Lightweight transcript-cleanup pass** for parallel correction
    /// during dictation pauses. Unlike `parseVoice` (which returns a full
    /// structured ParsedExpense), this just returns the corrected string —
    /// the audio recognizer feeds segments here one at a time and the
    /// result replaces the segment in place. Cheap, focused, and bounded
    /// in scope so it can run multiple times during a single voice session
    /// without significantly impacting battery.
    ///
    /// **Conservative by design**: the prompt instructs the model NOT to
    /// add words, change meaning, or rewrite phrases. Only fix obvious
    /// speech-recognition errors. When the input is already clean, the
    /// model is asked to return it unchanged — the caller checks for an
    /// exact match before applying any update (which suppresses no-op
    /// updates and avoids visual flicker).
    static func correctTranscript(_ raw: String) async -> String? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *), isAvailable else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else  { return nil }

        let instructions = """
        You correct speech-recognition errors in voice transcripts from \
        Indian English speakers. Return the corrected version of the input.

        Correct ONLY these issues:
        - Homophones common in Indian English speech: "rahul" → "waffle" \
          (food context), "pune" → "paneer", "berani" → "biryani", \
          "old uh" → "ola", "swigy" → "swiggy"
        - Indian English number compounds — ones word followed by tens \
          word means ones×100+tens. Apply these EVERY time you see them:
            - "two fifty" → "250"
            - "three fifty" → "350"
            - "two eighty" → "280"
            - "three twenty" → "320"
            - "four eighty" → "480"
            - "five fifteen" → "515"
            - "one twenty" → "120"
            - "one fifty" → "150"
            - "nine ninety" → "990"
          Same applies if the digit is already numeric: "3 50" → "350", \
          "2 75" → "275", "2 80" → "280", "1 20" → "120".
        - "Two hundred fifty" → "250", "two hundred eighty" → "280", \
          "three hundred" → "300", etc.
        - Obvious word doubling artifacts from speech recognition

        DO NOT:
        - Add words that weren't in the input.
        - Rewrite sentence structure.
        - Change names that are plausibly real (e.g. don't change "Rahul" \
          to "Waffle" unless context strongly suggests it's a food item).
        - "Improve" grammar or punctuation.
        - Add currency symbols, units, or commentary.
        - **NEVER split or reinterpret plain numbers.** If the transcript \
          says "280", leave it as "280" — do NOT change it to "80" or \
          anything else.
        - **Drop the hundreds component of a number.** "Two eighty" \
          becomes "280", never "eighty" or "80". "Three fifty" \
          becomes "350", never "fifty" or "50".

        If you're unsure whether something is an error, leave it. \
        If the input is already correct, return it exactly as is.

        Examples:
        - "spent two fifty on flat at flat hub" → "spent 250 on waffle at waffle hub"
        - "spent three fifty for dinner at ramachandra" → "spent 350 for dinner at ramachandra"
        - "1 20 rupees for chai" → "120 rupees for chai"
        - "3 50 for lunch" → "350 for lunch"
        - "spent 500 on groceries" → "spent 500 on groceries"  (unchanged)
        - "paid rahul back 200" → "paid rahul back 200"  (Rahul is a name, no food context)
        """

        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(
                to: trimmed,
                generating: CorrectedTranscript.self
            )
            let text = response.content.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    /// Unified implementation used by both `parse` and `parseVoice`.
    /// `isVoice` tunes the instructions toward speech-recognition quirks.
    private static func parse(_ input: String,
                               categories: [CategoryEntry],
                               accountNames: [String],
                               contextBlock: String = "",
                               isVoice: Bool) async -> SmartParseResult? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *), isAvailable else { return nil }
        let normalizedInput = Self.normalizeIndianNumbers(in: input)
        guard !normalizedInput.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard !categories.isEmpty else { return nil }

        // Rich category list with icon-derived hints — same as parseReceipt.
        // Lets the model route "petrol" → Transport, "pharmacy" → Health
        // without needing to guess what the user means by each label.
        let categoryList = CategoryHint.formatList(
            categories.map { (name: $0.name, iconKey: $0.iconKey) }
        )
        let accountList = accountNames.isEmpty
            ? "(no account list provided)"
            : accountNames.joined(separator: ", ")

        // **Role preamble** — pasted at the top of every prompt.
        // Establishes the FM's identity and the bar for output quality.
        // Modeled on how senior systems-engineering models behave when
        // given a strong role: precise, careful, willing to return
        // structured nil rather than guess. The user mentioned wanting
        // "Claude-level precision" — this preamble is the closest
        // levers we have inside the on-device FM.
        let rolePreamble = """
        You are TULA's senior expense parser. You have ONE job and one \
        job only: extract precise, structured expense data from the \
        user's input. You are careful, deterministic, and willing to \
        return nil rather than guess wrong.

        Your output goes DIRECTLY into the user's expense database with \
        no human review. A wrong amount, merchant, or category creates \
        rework — the user has to manually fix it. Aim to be RIGHT, not \
        creative.

        Treat the user's input as authoritative when it's clear, and \
        use the context blocks below when it's ambiguous. Never invent \
        information that isn't in the input or context.
        """

        // Context block from the caller (situational + DB). Empty
        // when the caller didn't build one (e.g. tests). The FM is
        // told to use it as supporting information — not to invent
        // facts not present in the input.
        let contextSection = contextBlock.isEmpty ? "" : "\n\n\(contextBlock)\n"

        // Two prompt variants. The voice variant adds explicit guidance
        // about speech-recognition errors common in Indian English —
        // homophones (waffle/rahul, paneer/pune, hari/curry), split
        // digits (one twenty → 120, not 1 and 20), and conversational
        // padding ("spent X on Y at Z" structure).
        let instructions: String
        if isVoice {
            instructions = """
            \(rolePreamble)
            \(contextSection)
            You parse expense entries from VOICE transcripts spoken by \
            Indian users. The transcript may contain speech-recognition \
            errors. Use the category and account lists as anchors to \
            correct context errors. When a merchant in the user's \
            FREQUENT MERCHANTS list (above) phonetically matches what \
            was transcribed, ALWAYS prefer the canonical spelling.

            Extract:
            - amount: the total spent, as a single integer in rupees. \
              See the AMOUNT RULES section below — read it carefully.
            - merchant: the place or vendor where money was spent.
            - item: what was bought, if mentioned separately from the merchant.
            - category: pick ONE — use the parenthesized hint keywords to \
              decide which category fits the merchant/item:
            \(categoryList)
            - account: best fit from this exact list, or empty if none mentioned: \(accountList)

            **AMOUNT RULES — read these first and apply STRICTLY.**

            Indian English shorthand combines a small digit (one through \
            nine) with a tens word (twenty, thirty, forty, fifty, sixty, \
            seventy, eighty, ninety, or teens like fifteen) into a \
            three-digit number: ONES × 100 + TENS. NEVER add them.

            REQUIRED:
            - "two fifty" = 250   (NOT 52, NOT 50)
            - "three fifty" = 350 (NOT 53, NOT 50)
            - "three twenty" = 320
            - "four eighty" = 480
            - "five fifteen" = 515
            - "nine ninety" = 990
            - "one twenty" = 120
            - "one fifty" = 150

            Also combine "X hundred Y" naturally: \
            "two hundred fifty" = 250, "three hundred" = 300, \
            "five hundred twenty" = 520.

            And combine split digits from voice transcription gaps: \
            "1 20" = 120, "3 50" = 350, "2 75" = 275.

            Indian magnitudes: "lakh" = 100000, "crore" = 10000000.

            **Never drop the hundreds component.** "Three fifty" is 350, \
            not 50. If you only hear "fifty" alone in the transcript, \
            that's 50 — but as soon as a small digit precedes the tens \
            word, multiply.

            Common Indian-English speech-recognition mistakes — CORRECT \
            them based on context:
            - "rahul", "flat", "raffle", "waffel" near a food context → \
              likely "waffle"
            - "pune", "panner" near food → likely "paneer"
            - "berani", "biriyani" → "biryani"
            - "old uh" near transport → "ola"
            - "swiggy" might be heard as "swigy", "swiggi" — fix
            - "two flat hub", "rahul hub" → "Waffle Hub"

            When the transcript names a generic word as a merchant ("flat", \
            "rahul", "raffle") AND the same word appears as the item \
            ("on flat at flat hub" pattern), the speaker almost certainly \
            said the same real word twice (waffle/waffle hub, biryani/biryani \
            house, etc.) and the transcription mangled it. Pick the most \
            plausible real food/place name that matches the category.

            Examples:
            - "spent 350 for dinner at ramachandra restaurant" → \
              amount 350, merchant "Ramachandra Restaurant", item "Dinner", \
              category "Food"
            - "three fifty for dinner at ramachandra" → \
              amount 350, merchant "Ramachandra", item "Dinner", category "Food"
            - "spent three hundred fifty at swiggy" → \
              amount 350, merchant "Swiggy", item nil, category "Food"
            - "spent 250 rupees on waffle at waffle hub" → amount 250, \
              merchant "Waffle Hub", item "Waffle", category "Food"
            - "300 for lunch at sagar ratna" → amount 300, \
              merchant "Sagar Ratna", item "Lunch", category "Food"
            - "150 for breakfast at saravana bhavan" → amount 150, \
              merchant "Saravana Bhavan", item "Breakfast", category "Food"
            - "80 for tea at irani cafe" → amount 80, \
              merchant "Irani Cafe", item "Tea", category "Food"
            - "four eighty ola to airport" → amount 480, merchant "Ola", \
              item nil, category "Transport"
            - "spent two fifty on flat at flat hub" (mis-transcribed) → \
              amount 250, merchant "Waffle Hub", item "Waffle", category "Food"
            - "spent 2 50 on rahul at rahul hub" (mis-transcribed) → \
              amount 250, merchant "Waffle Hub", item "Waffle", category "Food"
            - "ola to airport four eighty" → amount 480, merchant "Ola", \
              item nil, category "Transport"
            - "150 chai from cash" → amount 150, merchant "Chai", \
              item nil, category "Food", account "Cash"

            **Item extraction guidance.** Whenever the input mentions BOTH \
            a thing-bought and a place ("dinner at restaurant", "tea at \
            cafe", "coffee from chai point", "subzi from market"), put \
            the thing-bought in `item` — even when it's a meal type or \
            generic word like "dinner", "lunch", "snacks", "drinks". \
            Item is nil only when no separate thing-bought is mentioned \
            (e.g. "ola 480" — Ola is the merchant, no item).

            **Merchant vs item disambiguation — CRITICAL.** The `at` \
            preposition marks the merchant (where), `on`/`for` marks \
            the item (what). The MERCHANT is a place name (restaurant, \
            shop, store, app, brand). The ITEM is a dish, product, \
            service, or category of consumption.

            Indian dishes are ITEMS, not merchants — these never go in \
            the merchant field: masala dosa, biryani, paneer butter \
            masala, vada pav, idli, samosa, chai, lassi, gulab jamun, \
            butter chicken, dal makhani, chole bhature, pav bhaji, \
            momos, pani puri, rajma chawal, paratha, kebab.

            Indian restaurant/shop names are MERCHANTS — these never go \
            in the item field: Sagar Ratna, Saravana Bhavan, Haldiram, \
            Bikanervala, MTR, Anand Bhavan, A2B, Paradise, Bawarchi, \
            Karim's, Indian Coffee House, Cafe Coffee Day, Chai Point, \
            Barista, and anything containing the words "restaurant", \
            "hotel", "cafe", "bhavan", "ratna", "darbar", "house", \
            "kitchen", "biryani house", "tiffin centre".

            **DATE RULES.** Resolve relative time references using \
            the SITUATIONAL CONTEXT above (which tells you today's date \
            and day of week). Return date in YYYY-MM-DD format.
            - "yesterday" / "kal" → yesterday's date
            - "day before yesterday" / "parso" → 2 days ago
            - "last Friday" / "pichle Friday" → most recent past Friday
            - "morning coffee" / "today morning" → today's date
            - No date/time mentioned → nil (means right now)

            More examples:
            - "spent 280 for masala dosa at ramachandra restaurant" → \
              merchant "Ramachandra Restaurant", item "Masala Dosa"
            - "350 biryani at paradise" → merchant "Paradise", item "Biryani"
            - "200 paneer butter masala from haldiram" → merchant "Haldiram", \
              item "Paneer Butter Masala"
            - "100 for vada pav at the corner stall" → merchant "Corner Stall", \
              item "Vada Pav"
            - "150 chai at chai point" → merchant "Chai Point", item "Chai"
            - "yesterday 500 at swiggy" → date "2026-06-22", amount 500, \
              merchant "Swiggy"
            """
        } else {
            instructions = """
            \(rolePreamble)
            \(contextSection)
            You parse expense log entries from Indian users. Inputs are typically \
            short, casual, and may mix Hindi/English. Extract:
            - amount: total spent in rupees, as a number.
            - merchant: where the money went (the place, item, or vendor).
            - item: what was bought, if mentioned separately from the merchant.
            - category: pick ONE — match the merchant/item to the parenthesized \
              keywords (e.g. petrol/fuel → Transport, restaurants → Food):
            \(categoryList)
            - account: best fit from this exact list, or empty if none mentioned: \
              \(accountList)

            Rules:
            - If amount is unclear, return 0.
            - Keep merchant short — the item or place name only, no padding.
            - For meals/snacks/drinks, prefer "Food". For raw groceries, "Groceries".

            Examples:
            - "spent 250 on biryani" → amount 250, merchant "Biryani", item nil, category "Food"
            - "ola to airport 480" → amount 480, merchant "Ola", item nil, category "Transport"
            - "150 for chai at chai point" → amount 150, merchant "Chai Point", item "Chai", category "Food"
            - "560 for dinner at ramachandra restaurant" → amount 560, merchant "Ramachandra Restaurant", item "Dinner", category "Food"
            - "300 for lunch at sagar ratna" → amount 300, merchant "Sagar Ratna", item "Lunch", category "Food"
            - "subzi ke liye 200 diye" → amount 200, merchant "Subzi", item nil, category "Groceries"

            Whenever the input mentions both a thing-bought and a place \
            ("dinner at X", "tea at Y", "lunch from Z"), put the thing in \
            `item` — including meal types like dinner/lunch/breakfast/snacks/tea.
            """
        }

        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(
                to: normalizedInput,
                generating: _FMSmartParseResult.self
            )
            let fm = response.content
            return SmartParseResult(
                amount: fm.amount,
                merchant: fm.merchant,
                item: fm.item,
                category: fm.category,
                account: fm.account,
                date: fm.date
            )
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    // MARK: - Multi-Expense Voice Parse (FM)

    /// On-device FM implementation for multi-expense voice transcripts.
    /// Reuses the same voice-specific prompt (homophones, split digits,
    /// Indian English numbers) but with added multi-expense splitting
    /// guidance. Returns an array of SmartParseResult — one per expense.
    private static func parseMulti(
        _ input: String,
        categories: [CategoryEntry],
        accountNames: [String],
        contextBlock: String = ""
    ) async -> [SmartParseResult]? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *), isAvailable else { return nil }
        let normalizedInput = Self.normalizeIndianNumbers(in: input)
        guard !normalizedInput.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard !categories.isEmpty else { return nil }

        let categoryList = CategoryHint.formatList(
            categories.map { (name: $0.name, iconKey: $0.iconKey) }
        )
        let accountList = accountNames.isEmpty
            ? "(no account list provided)"
            : accountNames.joined(separator: ", ")

        let contextSection = contextBlock.isEmpty ? "" : "\n\n\(contextBlock)\n"

        let instructions = """
        You are TULA's senior expense parser. You have ONE job: extract \
        precise, structured expense data from the user's voice transcript. \
        The input contains MULTIPLE expenses separated by conjunctions \
        (and, then, also, plus), commas, or semicolons.
        \(contextSection)
        You parse expense entries from VOICE transcripts spoken by \
        Indian users. The transcript may contain speech-recognition \
        errors. Use the category and account lists as anchors.

        For EACH expense in the input, extract:
        - amount: total spent in rupees (see AMOUNT RULES below)
        - merchant: place or vendor name
        - item: what was bought (if separate from merchant)
        - category: pick ONE from the list below
        - account: from the account list, or empty

        **SPLITTING RULES:**
        - Split on "and", "then", "also", "plus", commas, semicolons
        - Each expense must have its own amount
        - If an account is mentioned once at the end (e.g. "from cash"), \
          it applies to ALL expenses
        - If a category applies globally, repeat it in each entry

        **AMOUNT RULES — Indian English shorthand:**
        ONES × 100 + TENS: "two fifty" = 250, "three fifty" = 350, \
        "four eighty" = 480, "one twenty" = 120.
        Split digits: "1 20" = 120, "3 50" = 350.
        "X hundred Y": "two hundred fifty" = 250.
        Indian magnitudes: "lakh" = 100000, "crore" = 10000000.

        Available categories:
        \(categoryList)

        Accounts: \(accountList)

        Examples:
        - "350 food and 400 groceries" → [{350, nil, nil, "Food"}, \
          {400, nil, nil, "Groceries"}]
        - "ola 480 and swiggy 350 and chai 80 from cash" → \
          [{480, "Ola", nil, "Transport", "Cash"}, \
          {350, "Swiggy", nil, "Food", "Cash"}, \
          {80, "Chai", nil, "Food", "Cash"}]
        - "spent 250 on lunch at sagar ratna and 150 for chai at \
          chai point" → [{250, "Sagar Ratna", "Lunch", "Food"}, \
          {150, "Chai Point", "Chai", "Food"}]
        """

        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(
                to: normalizedInput,
                generating: _FMMultiExpenseResult.self
            )
            let results = response.content.expenses.map { fm in
                SmartParseResult(
                    amount: fm.amount,
                    merchant: fm.merchant,
                    item: fm.item,
                    category: fm.category,
                    account: fm.account,
                    date: fm.date
                )
            }
            return results.isEmpty ? nil : results
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    // MARK: - Indian English Number Normalizer

    static func normalizeIndianNumbers(in text: String) -> String {
        let onesWords: [String: Int] = [
            "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
            "six": 6, "seven": 7, "eight": 8, "nine": 9,
            "to": 2, "too": 2
        ]
        let tensWords: [String: Int] = [
            "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
            "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
            "eighteen": 18, "nineteen": 19,
            "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
            "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90
        ]
        let tensDigits: Set<String> = [
            "10", "11", "12", "13", "14", "15", "16", "17", "18", "19",
            "20", "30", "40", "50", "60", "70", "80", "90"
        ]

        var tokens = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }

        // Pass 1: "X hundred Y" → combined number (e.g. "two hundred fifty" → "250")
        var i = 0
        while i < tokens.count - 1 {
            let current = tokens[i].lowercased().trimmingCharacters(in: .punctuationCharacters)
            let next = tokens[i + 1].lowercased().trimmingCharacters(in: .punctuationCharacters)

            if next == "hundred" {
                var hundreds = 0
                if let o = onesWords[current] { hundreds = o * 100 }
                else if let d = Int(current), d >= 1, d <= 9 { hundreds = d * 100 }

                if hundreds > 0 {
                    // Check for a trailing tens/ones word: "two hundred fifty"
                    if i + 2 < tokens.count {
                        let third = tokens[i + 2].lowercased().trimmingCharacters(in: .punctuationCharacters)
                        if let t = tensWords[third] {
                            tokens[i] = String(hundreds + t)
                            tokens.remove(at: i + 2)
                            tokens.remove(at: i + 1)
                            continue
                        }
                    }
                    tokens[i] = String(hundreds)
                    tokens.remove(at: i + 1)
                    continue
                }
            }
            i += 1
        }

        // Pass 2: Indian compound "ones tens" → ones×100+tens
        i = 0
        while i < tokens.count - 1 {
            let current = tokens[i].lowercased().trimmingCharacters(in: .punctuationCharacters)
            let next = tokens[i + 1].lowercased().trimmingCharacters(in: .punctuationCharacters)

            var ones: Int?
            var tens: Int?

            if let o = onesWords[current] { ones = o }
            else if let d = Int(current), d >= 1, d <= 9 { ones = d }

            if let t = tensWords[next] { tens = t }
            else if tensDigits.contains(next), let d = Int(next) { tens = d }

            if let o = ones, let t = tens {
                tokens[i] = String(o * 100 + t)
                tokens.remove(at: i + 1)
            } else {
                i += 1
            }
        }

        // Pass 3: "X thousand" → X*1000 (e.g. "two thousand" → "2000")
        i = 0
        while i < tokens.count - 1 {
            let current = tokens[i].lowercased().trimmingCharacters(in: .punctuationCharacters)
            let next = tokens[i + 1].lowercased().trimmingCharacters(in: .punctuationCharacters)

            if next == "thousand" || next == "k" {
                var value = 0
                if let o = onesWords[current] { value = o }
                else if let d = Int(current), d >= 1, d <= 99 { value = d }
                if value > 0 {
                    tokens[i] = String(value * 1000)
                    tokens.remove(at: i + 1)
                    continue
                }
            }
            i += 1
        }

        return tokens.joined(separator: " ")
    }
}

// MARK: - @Generable result type

/// FM-facing smart-parser schema. Has `@Generable` macro + `@Guide`
/// descriptions for Foundation Models. Renamed with `_FM` prefix to
/// distinguish from the public DTO `SmartParseResult` (defined below
/// outside the `#if`). Parser converts FM result → DTO before returning,
/// keeping iOS 26 availability gating internal to this file.
///
/// `category` and `account` are Strings (not the SwiftData entities)
/// because the model returns text; the call site maps each back to a
/// real Category / Account by name lookup.
#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct _FMSmartParseResult: Codable, Sendable {
    @Guide(description: "Total amount spent, in rupees, as a single integer. Indian English compounds: ONES word followed by TENS word means ones×100+tens. 'two fifty' = 250, 'three fifty' = 350, 'four eighty' = 480 — NEVER just the tens portion alone. 'one twenty' = 120. Split-digit transcriptions: '1 20' = 120, '3 50' = 350. Do not drop the hundreds part.")
    let amount: Double

    @Guide(description: "The place, vendor, or shop where money was spent. Always a place name (restaurant, store, app, brand), NEVER a dish or product. \"Masala Dosa\" is NOT a merchant — \"Sagar Ratna\" is. Title-cased. Words like restaurant, hotel, cafe, bhavan, ratna, house, kitchen indicate a merchant.")
    let merchant: String?

    @Guide(description: "The thing that was bought, if mentioned separately from the merchant. Include meal types (dinner, lunch, breakfast, snacks, tea, coffee), specific dishes (masala dosa, biryani, paneer butter masala, vada pav, idli), and any item word. For \"560 for dinner at ramachandra restaurant\", item=\"Dinner\". For \"280 for masala dosa at ramachandra\", item=\"Masala Dosa\", merchant=\"Ramachandra\". Nil ONLY when the input doesn't mention anything separate from the place name (e.g. \"ola 480\" — no item).")
    let item: String?

    @Guide(description: "Best-fitting category name. Must match one of the categories listed in the instructions exactly.")
    let category: String?

    @Guide(description: "Account or payment method, matching the user's account list. Empty when the input doesn't mention which account was used.")
    let account: String?

    @Guide(description: "Date of the expense in YYYY-MM-DD format if mentioned in the input. Resolve relative references using SITUATIONAL CONTEXT: 'yesterday'/'kal' = yesterday's date, 'last Friday' = most recent past Friday, 'day before yesterday'/'parso' = 2 days ago. Nil when the expense happened now/today or no date is mentioned.")
    let date: String?
}

/// FM-facing multi-expense result for voice inputs that contain two or
/// more expenses separated by conjunctions ("and", "then", commas).
/// A single FM call extracts all expenses, letting the model use cross-
/// expense context (e.g. "from cash" applies to both expenses in
/// "350 food and 400 groceries from cash").
@available(iOS 26.0, *)
@Generable
struct _FMMultiExpenseResult: Codable, Sendable {
    @Guide(description: "Array of expenses extracted from the input. Split on conjunctions like 'and', 'then', 'also', 'plus', commas, and semicolons. Each entry has its own amount, merchant, item, category, and account. If an account or category is mentioned once and applies to all expenses, repeat it in each entry.")
    let expenses: [_FMSmartParseResult]
}

/// Lightweight schema for the parallel transcript-cleanup pass. A single
/// string carrying the corrected version of the input. Wrapped in a struct
/// because Foundation Models' `@Generable` requires a typed container.
@available(iOS 26.0, *)
@Generable
struct CorrectedTranscript: Codable, Sendable {
    @Guide(description: "The corrected transcript text. Plain prose, no quotes, no commentary. If the input is already correct, return it unchanged.")
    let text: String
}

/// FM-facing receipt schema. Has the `@Generable` macro + `@Guide`
/// descriptions that Foundation Models reads to shape its output. This
/// type is iOS 26+ only because `@Generable` is iOS 26+. The public-
/// facing `ReceiptSmartParseResult` (defined outside the `#if`) is a
/// plain DTO mirror that the parser converts to before returning, so
/// callers don't inherit iOS 26 availability.
@available(iOS 26.0, *)
@Generable
struct _FMReceiptResult: Codable, Sendable {
    @Guide(description: "Grand total only — ONE number printed verbatim on the receipt near a 'Grand Total' / 'Net Payable' / 'Amount Due' / 'Bill Amount' label. NEVER add two values together. If the same number appears twice (e.g. subtotal and grand total both say 140), the amount is 140 NOT 280. Nil when no clear total is found. OCR digit errors: I/l/|→1, O→0, S→5, B→8 — recover these in numeric contexts.")
    let amount: Double?

    @Guide(description: "Business or place name from the receipt header or 'Paid to' label. Title-cased. Always a place name (restaurant, store, app, hospital, petrol pump) — NEVER a product, dish, or document label like 'Cash Bill' or 'Tax Invoice'. If no business name is visible but items make the place type obvious, infer a generic: 'Restaurant', 'Pharmacy', 'Grocery Store', 'Petrol Pump', 'Hospital'. Prefer a real name over a generic whenever possible.")
    let merchant: String?

    @Guide(description: "Transaction date in YYYY-MM-DD format. Indian receipts use DD/MM/YYYY — convert to YYYY-MM-DD. Normalize '15/03/2025', '15-Mar-2025', 'March 15 2025' etc. Nil when no date is present.")
    let date: String?

    @Guide(description: "Best-fitting category name from the categories listed in the instructions. Decide by merchant type first, then by items if merchant is ambiguous.")
    let category: String?

    @Guide(description: "Line items purchased in order. ONLY actual products/services/dishes. NEVER include: CGST, SGST, GST, service charge, delivery fee, platform fee, packaging charge, subtotal, total, grand total, discount, cash, change, tip, round-off, or any tax line.")
    let items: [_FMReceiptLineItem]
}

/// FM-facing line item. Plain mirror is `ReceiptLineItem` outside `#if`.
@available(iOS 26.0, *)
@Generable
struct _FMReceiptLineItem: Codable, Sendable {
    @Guide(description: "Item name, title-cased and human-readable. E.g. 'Masala Dosa', 'Coca Cola 500ml', 'Paracetamol Tablet'. Never a tax line (CGST/SGST/GST), service charge, delivery fee, discount, subtotal, or total.")
    let name: String

    @Guide(description: "Price for this single item as a number with no currency symbol. Must be a value printed on the receipt, not computed.")
    let price: Double
}
#else
// Stub for non-FM SDKs.
struct CorrectedTranscript: Codable, Sendable {
    let text: String
}
#endif

// MARK: - Plain DTOs (always available)
//
// These types are the PUBLIC interface for the parser. They have no
// Foundation Models dependencies, no availability annotations, and no
// `@Generable` macros. The parser internally uses iOS 26-only `_FM*`
// types for FM communication and converts to these DTOs before
// returning. Result: callers compile and run on iOS 17+ even when the
// parser's actual implementation needs iOS 26.

/// Lightweight DTO passed to the parser describing one of the user's
/// categories. Carries the name (which the FM model will return as its
/// category choice) and the icon key (which we use to look up a hint
/// phrase that helps the model understand what the category is FOR).
///
/// **Why a struct and not just `[String]`**: passing icon keys alongside
/// names lets the parser build richer prompts ("Transport (petrol, cabs,
/// transit)") without callers having to construct the hint string. It
/// also future-proofs the API for when Category gets user-authored
/// descriptions — we'd add a `description` field here without breaking
/// existing callers.
struct CategoryEntry: Sendable {
    let name: String
    let iconKey: String

    init(name: String, iconKey: String) {
        self.name = name
        self.iconKey = iconKey
    }
}

/// Public smart-parse result returned by `parseVoice` / `parse`.
struct SmartParseResult: Codable, Sendable {
    let amount: Double
    let merchant: String?
    let item: String?
    let category: String?
    let account: String?
    /// Resolved date in YYYY-MM-DD format from relative expressions
    /// ("yesterday", "last Friday"). Nil when the expense is for today.
    let date: String?
}

/// Public receipt parse result returned by `SmartExpenseParser.parseReceipt`.
/// Fields are nil/empty when FM was unavailable or didn't provide them.
struct ReceiptSmartParseResult: Codable, Sendable {
    let amount: Double
    let merchant: String?
    let date: String?
    let time: String?
    let category: String?
    let paymentMode: String?
    let cardLast4: String?
    let items: [ReceiptLineItem]
    let discount: Double?
    let tax: Double?
}

/// Public line item type — one row in a receipt's purchased-items list.
struct ReceiptLineItem: Codable, Sendable {
    let name: String
    let price: Double
    let quantity: Int

    init(name: String, price: Double, quantity: Int = 1) {
        self.name = name
        self.price = price
        self.quantity = quantity
    }
}
