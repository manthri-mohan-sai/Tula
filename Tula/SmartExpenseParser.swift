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
        switch AIProviderStorage.selected {
        case .openAI:
            return !CloudAIConfig.load().apiKey.isEmpty
        case .gemini:
            return !CloudAIConfig.loadGemini().apiKey.isEmpty
        case .appleFM:
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
                      categories: [CategoryEntry]) async -> SmartParseResult? {
        // Route to cloud if user selected a cloud provider
        switch AIProviderStorage.selected {
        case .openAI:
            return await CloudAIParser.parse(input, categories: categories, accountNames: [], isVoice: false)
        case .gemini:
            return await CloudAIParser.parse(input, categories: categories, accountNames: [], isVoice: false, config: .loadGemini())
        case .appleFM:
            return await parse(input, categories: categories, accountNames: [], isVoice: false)
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
                            accountNames: [String]) async -> SmartParseResult? {
        switch AIProviderStorage.selected {
        case .openAI:
            return await CloudAIParser.parse(input, categories: categories, accountNames: accountNames, isVoice: true)
        case .gemini:
            return await CloudAIParser.parse(input, categories: categories, accountNames: accountNames, isVoice: true, config: .loadGemini())
        case .appleFM:
            return await parse(input, categories: categories,
                        accountNames: accountNames, isVoice: true)
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
                              documentType: ReceiptStorage.DocumentType = .generic) async -> ReceiptSmartParseResult? {
        // Route to cloud AI if selected
        switch AIProviderStorage.selected {
        case .openAI:
            let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !categories.isEmpty else { return nil }
            return await CloudAIParser.parseReceipt(trimmed, categories: categories)
        case .gemini:
            let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !categories.isEmpty else { return nil }
            return await CloudAIParser.parseReceipt(trimmed, categories: categories, config: .loadGemini())
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

        // Per-document-type hint added to the prompt. Tells the model
        // what layout to expect, which improves accuracy especially on
        // UPI screenshots and order summaries (where the "receipt"
        // mental model would be misleading). Generic docs get no hint.
        let layoutHint: String = {
            switch documentType {
            case .upi:
                return """
                LAYOUT: This is a UPI payment confirmation screenshot. \
                The amount is the prominent number near the top \
                (often after "₹"). The merchant is the value after \
                "Paid to" / "To" / "Transferred to". There are no \
                line items — return items: []. Date is the transaction \
                timestamp.
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

        let instructions = """
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

        Available categories (parenthesized keywords describe what fits):
        \(categoryList)

        \(layoutHint)

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
                amount: fm.amount,
                merchant: fm.merchant,
                date: fm.date,
                category: fm.category,
                items: fm.items.map { ReceiptLineItem(name: $0.name, price: $0.price) }
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
    static func parseReceiptImage(_ imageData: Data,
                                   categories: [CategoryEntry]) async -> ReceiptSmartParseResult? {
        guard !categories.isEmpty, !imageData.isEmpty else { return nil }

        switch AIProviderStorage.selected {
        case .openAI:
            return await CloudAIParser.parseReceiptImage(imageData, categories: categories)
        case .gemini:
            return await CloudAIParser.parseReceiptImage(imageData, categories: categories, config: .loadGemini())
        case .appleFM:
            // Apple FM doesn't support image input — caller should use parseReceipt with OCR text
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
        guard !trimmed.isEmpty else { return nil }

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
            - "three twenty" → "320"
            - "four eighty" → "480"
            - "five fifteen" → "515"
            - "one twenty" → "120"
            - "one fifty" → "150"
            - "nine ninety" → "990"
          Same applies if the digit is already numeric: "3 50" → "350", \
          "2 75" → "275", "1 20" → "120".
        - "Two hundred fifty" → "250", "three hundred" → "300", etc.
        - Obvious word doubling artifacts from speech recognition

        DO NOT:
        - Add words that weren't in the input.
        - Rewrite sentence structure.
        - Change names that are plausibly real (e.g. don't change "Rahul" \
          to "Waffle" unless context strongly suggests it's a food item).
        - "Improve" grammar or punctuation.
        - Add currency symbols, units, or commentary.
        - **Drop the hundreds component of a number.** "Three fifty" \
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
                               isVoice: Bool) async -> SmartParseResult? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *), isAvailable else { return nil }
        guard !input.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
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

        // Two prompt variants. The voice variant adds explicit guidance
        // about speech-recognition errors common in Indian English —
        // homophones (waffle/rahul, paneer/pune, hari/curry), split
        // digits (one twenty → 120, not 1 and 20), and conversational
        // padding ("spent X on Y at Z" structure).
        let instructions: String
        if isVoice {
            instructions = """
            You parse expense entries from VOICE transcripts spoken by \
            Indian users. The transcript may contain speech-recognition \
            errors. Use the category and account lists as anchors to \
            correct context errors.

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

            More examples:
            - "spent 280 for masala dosa at ramachandra restaurant" → \
              merchant "Ramachandra Restaurant", item "Masala Dosa"
            - "350 biryani at paradise" → merchant "Paradise", item "Biryani"
            - "200 paneer butter masala from haldiram" → merchant "Haldiram", \
              item "Paneer Butter Masala"
            - "100 for vada pav at the corner stall" → merchant "Corner Stall", \
              item "Vada Pav"
            - "150 chai at chai point" → merchant "Chai Point", item "Chai"
            """
        } else {
            instructions = """
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
                to: input,
                generating: _FMSmartParseResult.self
            )
            let fm = response.content
            return SmartParseResult(
                amount: fm.amount,
                merchant: fm.merchant,
                item: fm.item,
                category: fm.category,
                account: fm.account
            )
        } catch {
            return nil
        }
        #else
        return nil
        #endif
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
    @Guide(description: "Grand total / final amount paid, as a number with no currency symbol. Always the LARGEST total — if line-item subtotals and a grand total both appear, return the grand total. Cross-check by summing items: the sum should approximately equal this value. Watch for OCR errors where a leading '1' has been dropped (140 misread as 40).")
    let amount: Double

    @Guide(description: "Business name. Usually printed at the top of the receipt. Title-cased. Always a place name (restaurant, store, app, brand) — never a product or dish.")
    let merchant: String?

    @Guide(description: "Transaction date in YYYY-MM-DD format. Receipts may print dates as 15/03/2025, 15-Mar-2025, March 15 2025, etc — normalize all to YYYY-MM-DD. Nil when no date is present on the receipt.")
    let date: String?

    @Guide(description: "Best-fitting category name from the categories listed in the instructions. Choose based on merchant type and items.")
    let category: String?

    @Guide(description: "Line items purchased, in the order they appear on the receipt. EXCLUDE tax lines, subtotals, discounts, change due, and total/grand-total lines. Item names should be title-cased and human-readable.")
    let items: [_FMReceiptLineItem]
}

/// FM-facing line item. Plain mirror is `ReceiptLineItem` outside `#if`.
@available(iOS 26.0, *)
@Generable
struct _FMReceiptLineItem: Codable, Sendable {
    @Guide(description: "Item name, title-cased. E.g. 'Masala Dosa', 'Coca Cola 500ml', 'Paracetamol Tablet'.")
    let name: String

    @Guide(description: "Price for this item as a number with no currency symbol.")
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
}

/// Public receipt parse result returned by `SmartExpenseParser.parseReceipt`.
/// Fields are nil/empty when FM was unavailable or didn't provide them.
struct ReceiptSmartParseResult: Codable, Sendable {
    let amount: Double
    let merchant: String?
    let date: String?
    let category: String?
    let items: [ReceiptLineItem]
}

/// Public line item type — one row in a receipt's purchased-items list.
struct ReceiptLineItem: Codable, Sendable {
    let name: String
    let price: Double
}
