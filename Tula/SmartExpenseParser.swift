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
@available(iOS 26.0, *)
enum SmartExpenseParser {

    // MARK: - Availability

    /// Whether Foundation Models is currently usable on this device.
    ///
    /// Returns false on:
    /// - Devices without Apple Intelligence (iPhone 15 non-Pro and older)
    /// - Devices where the user has Apple Intelligence disabled
    /// - Devices where the model is still downloading
    ///
    /// Use this as the gate before doing any async work — if `isAvailable`
    /// is false, fall back to rules without ceremony.
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
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
    ///   - categoryNames: User's actual category names so the model
    ///     selects from them (and never returns something we'd then have
    ///     to map back to a real Category).
    /// - Returns: Parsed result or nil if unavailable / failed / timeout.
    ///
    /// **Failure is silent.** This method must never throw to its caller —
    /// the call site falls back to rules. If FM hiccups, the user still
    /// gets a working save flow.
    static func parse(_ input: String,
                      categoryNames: [String]) async -> SmartParseResult? {
        await parse(input, categoryNames: categoryNames, accountNames: [], isVoice: false)
    }

    /// Voice-specific parse. Identical schema, but the instructions tell
    /// the model to expect noisy speech-recognition output — homophones
    /// ("waffle" mistranscribed as "rahul"), split digits ("1 20" meant
    /// as "120"), and conversational phrasing. The model uses the
    /// category and account lists as anchors to correct context-sensitive
    /// errors. Use this instead of `parse(_:categoryNames:)` for
    /// voice-sourced input where text quality is lower.
    ///
    /// - Parameters:
    ///   - input: The raw speech transcript.
    ///   - categoryNames: User's actual category names.
    ///   - accountNames: User's actual account names (Bank, Cash, etc.) so
    ///     the model can correctly identify which account was charged when
    ///     mentioned in the transcript ("paid from HDFC", "in cash", etc.).
    static func parseVoice(_ input: String,
                            categoryNames: [String],
                            accountNames: [String]) async -> SmartParseResult? {
        await parse(input, categoryNames: categoryNames,
                    accountNames: accountNames, isVoice: true)
    }

    /// **Receipt parsing pass** — runs Foundation Models on the raw OCR'd
    /// text from a receipt photo. Different signature from `parseVoice`
    /// because receipts have richer structure (line items + a transaction
    /// date) that voice transcripts lack.
    ///
    /// **When to use this**: after `ReceiptStorage.parse` has done its
    /// regex pass. Pass the `rawText` from that result here. FM will
    /// produce a structured `ReceiptSmartParseResult` that the caller
    /// can merge with the regex result — preferring FM where it provides
    /// stronger signal (date, multi-item lists, ambiguous merchants),
    /// keeping regex where it's confident (clear totals, dishes called
    /// out individually).
    ///
    /// **Failure modes**: nil return covers FM unavailable, FM timeout,
    /// or empty input. Caller falls back to regex-only result.
    static func parseReceipt(_ rawText: String,
                              categoryNames: [String]) async -> ReceiptSmartParseResult? {
        #if canImport(FoundationModels)
        guard isAvailable else { return nil }
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !categoryNames.isEmpty else { return nil }

        let categoryList = categoryNames.joined(separator: ", ")
        let instructions = """
        You parse retail and restaurant receipts that have been read by \
        OCR. The input is the raw text output — line breaks may not align \
        with the original layout, characters may be misread, and totals \
        may appear multiple times. Be skeptical and use cross-checks.

        Extract:
        - amount: the GRAND TOTAL — the final amount the customer was \
          billed for. NOT the cash tendered, NOT the change given, NOT \
          a sum of subtotal + grand total. The grand total is ONE value \
          on the receipt, not multiple values to add together.
          Specifically:
            * If "Grand Total", "Net Amount", "Bill Amount", "Total \
              Amount", "Amount Payable", or "Payable" appears with a \
              value, USE THAT EXACT VALUE. Do not look further.
            * **The same total value often appears multiple times on \
              one receipt** — once as a subtotal and once as a grand \
              total. THIS IS THE SAME BILL. If you see "Subtotal 140" \
              and "Grand Total 140" both present, the amount is 140, \
              NOT 280. Never sum a subtotal with a grand total.
            * **Restaurant bills with Price/Total columns**: line items \
              have a per-unit price AND a line total (price × quantity). \
              These are NOT bill totals — they're column values for \
              individual rows. Only the bottommost summary value is \
              the grand total.
            * Lines labeled "Cash", "Tendered", "Paid", "Received", \
              "Change", "Balance Due", "Return" are NOT the grand total \
              — ignore them when picking amount.
            * Do NOT sum line items to derive the total. Do NOT sum \
              subtotal + tax to derive the total. Use the explicit \
              total line that appears on the receipt.
            * **Sanity check**: the amount you return should appear \
              somewhere as a single number on the receipt. If you're \
              about to return a number that isn't printed verbatim on \
              the receipt, you're doing arithmetic — STOP and pick the \
              largest value next to a "Grand Total" or "Total" marker \
              that IS printed.
          Return as a number, no currency symbol.
        - merchant: the business name. Usually at the top of the receipt, \
          in larger text. NEVER a dish, item, or category — always a \
          place name (restaurant, store, brand). Title-cased. NEVER \
          single common English words like "Return", "Command", "Option", \
          "Shift", "Cash Bill", "Tax Invoice" — those are not merchant \
          names, those are noise from the photo background or document \
          type labels.
        - date: the transaction date if present, in YYYY-MM-DD format. \
          Receipts often show "Date: 15/03/2025" or "15-Mar-2025" — \
          normalize all formats to YYYY-MM-DD. Leave nil if not present.
        - items: a list of purchased items with their prices. Each entry \
          is {name, price}. The price should be the LINE TOTAL (price × \
          quantity) when both appear, or just the per-unit price if no \
          quantity column. EXCLUDE tax lines, subtotals, totals, \
          discounts, change-due, and payment-method lines. Item names \
          should be title-cased and human-readable.
        - category: the single best-fitting category from this exact list: \
          \(categoryList). Pick based on the merchant type AND the items \
          purchased. Food places → Food. Pharmacies → Health. Grocery \
          stores → Groceries. Don't invent categories.

        WORKED EXAMPLE OF AMOUNT EXTRACTION:
        Given this OCR text:
            MASALA PURI
            40.00
            50.00
            PAPDI CHAT
            SAMOSA CHAT
            50.00
            40.00
            50.00
            50.00
            140.00
            140.00
            Subtotal :
            Grand Total:
            Payment: UPI
        The correct extracted amount is 140. NOT 280. The 140.00 appears \
        TWICE because the receipt prints subtotal AND grand total — \
        both equal 140 because there is no tax. The answer is 140, not \
        the sum. Items: Masala Puri 40, Papdi Chat 50, Samosa Chat 50. \
        These items sum to 140, confirming 140 is correct.

        OCR ERROR GUIDANCE:
        - "1" can be misread as "I", "l", or "|" — interpret these as 1 \
          in numeric contexts.
        - "0" can be misread as "O" or "D".
        - "5" can be misread as "S".
        - A leading "1" may be dropped (140 → 40). When the "Total" line \
          shows a small number that's roughly half of one of the other \
          candidates, the OCR likely dropped a digit — prefer the larger \
          candidate. BUT never go larger than the "Total"/"Payable" \
          marker if it's clearly present.

        DO NOT:
        - Confuse "Cash" / "Tendered" / "Change" with the grand total.
        - Sum subtotal + grand total (or any two totals) to derive an amount.
        - Sum tax + subtotal to derive a "total" — use the explicit total \
          line if present.
        - Return any number that isn't printed verbatim on the receipt as \
          the amount.
        - Invent items or merchant names not present in the text.
        - Return tax lines, subtotals, or total markers as items.
        - Change the order of items from how they appear on the receipt.
        - Return a date format other than YYYY-MM-DD.
        """

        do {
            let session = LanguageModelSession(model: SystemLanguageModel.default,
                                                instructions: instructions)
            let response = try await session.respond(to: trimmed,
                                                      generating: ReceiptSmartParseResult.self)
            return response.content
        } catch {
            return nil
        }
        #else
        return nil
        #endif
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
        guard isAvailable else { return nil }
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
                               categoryNames: [String],
                               accountNames: [String],
                               isVoice: Bool) async -> SmartParseResult? {
        #if canImport(FoundationModels)
        guard isAvailable else { return nil }
        guard !input.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard !categoryNames.isEmpty else { return nil }

        let categoryList = categoryNames.joined(separator: ", ")
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
            - category: best fit from this exact list (never invent): \(categoryList)
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
            - category: the single best-fitting category from this exact list \
              (never invent new ones): \(categoryList)
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
                generating: SmartParseResult.self
            )
            return response.content
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }
}

// MARK: - @Generable result type

/// Structured output schema for the smart parser. Matches the shape the
/// existing `ParsedExpense` carries (amount + merchant + item + category +
/// account) so it can drop into the save flow without lossy conversion.
///
/// `category` and `account` are Strings (not the SwiftData entities)
/// because the model returns text; the call site maps each back to a
/// real Category / Account by name lookup.
#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct SmartParseResult: Codable, Sendable {
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

/// Receipt-specific structured output. Distinct schema from
/// `SmartParseResult` because receipts have richer structure:
///
///   - `items`: line items as a typed array, not a single string
///   - `date`: the transaction date stamped on the receipt
///
/// Account is absent (receipts don't tell you which card was used —
/// the user picks that in the form). Item is absent (receipts have
/// MULTIPLE items, surfaced via the `items` array instead).
@available(iOS 26.0, *)
@Generable
struct ReceiptSmartParseResult: Codable, Sendable {
    @Guide(description: "Grand total / final amount paid, as a number with no currency symbol. Always the LARGEST total — if line-item subtotals and a grand total both appear, return the grand total. Cross-check by summing items: the sum should approximately equal this value. Watch for OCR errors where a leading '1' has been dropped (140 misread as 40).")
    let amount: Double

    @Guide(description: "Business name. Usually printed at the top of the receipt. Title-cased. Always a place name (restaurant, store, app, brand) — never a product or dish.")
    let merchant: String?

    @Guide(description: "Transaction date in YYYY-MM-DD format. Receipts may print dates as 15/03/2025, 15-Mar-2025, March 15 2025, etc — normalize all to YYYY-MM-DD. Nil when no date is present on the receipt.")
    let date: String?

    @Guide(description: "Best-fitting category name from the categories listed in the instructions. Choose based on merchant type and items.")
    let category: String?

    @Guide(description: "Line items purchased, in the order they appear on the receipt. EXCLUDE tax lines, subtotals, discounts, change due, and total/grand-total lines. Item names should be title-cased and human-readable.")
    let items: [ReceiptLineItem]
}

/// Single line item from a receipt — the thing bought and what it cost.
@available(iOS 26.0, *)
@Generable
struct ReceiptLineItem: Codable, Sendable {
    @Guide(description: "Item name, title-cased. E.g. 'Masala Dosa', 'Coca Cola 500ml', 'Paracetamol Tablet'.")
    let name: String

    @Guide(description: "Price for this item as a number with no currency symbol.")
    let price: Double
}
#else
// Stub so call sites compile on older SDKs where the framework isn't present.
struct SmartParseResult: Codable, Sendable {
    let amount: Double
    let merchant: String?
    let item: String?
    let category: String?
    let account: String?
}

struct CorrectedTranscript: Codable, Sendable {
    let text: String
}

struct ReceiptSmartParseResult: Codable, Sendable {
    let amount: Double
    let merchant: String?
    let date: String?
    let category: String?
    let items: [ReceiptLineItem]
}

struct ReceiptLineItem: Codable, Sendable {
    let name: String
    let price: Double
}
#endif
