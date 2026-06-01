//
//  CloudAIParser.swift
//  Tula
//
//  Cloud-based AI expense parser using an OpenAI-compatible chat
//  completions endpoint. Activated when the user selects "ChatGPT (Cloud)"
//  or "Google Gemini (Cloud)" in Settings and configures their API key.
//
//  Supports: OpenAI, Azure OpenAI, Google Gemini (via OpenAI-compat),
//  Ollama, LM Studio, or any endpoint that implements the
//  /v1/chat/completions contract.
//

import Foundation
import UIKit
import CoreImage
import os.log

private let aiLog = Logger(subsystem: "com.app.Tula", category: "CloudAI")

enum CloudAIParser {

    // MARK: - Text / Voice Parse

    static func parse(_ input: String,
                      categories: [CategoryEntry],
                      accountNames: [String] = [],
                      isVoice: Bool = false,
                      contextBlock: String = "",
                      config: CloudAIConfig? = nil) async -> SmartParseResult? {
        let cfg = config ?? CloudAIConfig.load()
        guard !cfg.apiKey.isEmpty else {
            aiLog.error("parse: API key is empty, model=\(cfg.model)")
            return nil
        }
        aiLog.info("parse: starting, voice=\(isVoice), model=\(cfg.model), input=\(input.prefix(80))")

        let categoryList = CategoryHint.formatList(
            categories.map { (name: $0.name, iconKey: $0.iconKey) }
        )
        let accountList = accountNames.isEmpty
            ? "(no account list provided)"
            : accountNames.joined(separator: ", ")

        let contextSection = contextBlock.isEmpty ? "" : "\n\n\(contextBlock)\n"

        let systemPrompt: String
        if isVoice {
            systemPrompt = """
            You are a JSON-only expense parser. You MUST respond with ONLY a single valid JSON object. \
            No explanations, no markdown, no code fences, no extra text before or after the JSON.

            Schema: {"amount":number,"merchant":string|null,"item":string|null,"category":string|null,"account":string|null}

            You are TULA's senior expense parser. You have ONE job: extract \
            precise, structured expense data from the user's voice transcript. \
            You are careful, deterministic, and willing to return null rather \
            than guess wrong.

            Your output goes DIRECTLY into the user's expense database with \
            no human review. A wrong amount, merchant, or category creates \
            rework. Aim to be RIGHT, not creative.
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
            - category: pick ONE from this list — use the parenthesized hint \
              keywords to decide which category fits the merchant/item:
            \(categoryList)
            - account: best fit from this exact list, or null if none mentioned: \(accountList)

            **AMOUNT RULES — read these first and apply STRICTLY.**

            Indian English shorthand combines a small digit (one through \
            nine) with a tens word (twenty, thirty, forty, fifty, sixty, \
            seventy, eighty, ninety, or teens like fifteen) into a \
            three-digit number: ONES × 100 + TENS. NEVER add them.

            REQUIRED:
            - "two fifty" = 250   (NOT 52, NOT 50)
            - "three fifty" = 350 (NOT 53, NOT 50)
            - "two eighty" = 280  (NOT 82, NOT 80)
            - "three twenty" = 320
            - "four eighty" = 480
            - "five fifteen" = 515
            - "nine ninety" = 990
            - "one twenty" = 120
            - "one fifty" = 150

            Also combine "X hundred Y" naturally: \
            "two hundred fifty" = 250, "two hundred eighty" = 280, \
            "three hundred" = 300, "five hundred twenty" = 520.

            And combine split digits from voice transcription gaps: \
            "1 20" = 120, "3 50" = 350, "2 75" = 275, "2 80" = 280.

            **CRITICAL: If the transcript contains a plain number like \
            "280", "350", "1500" — use it AS IS. Do NOT split or \
            re-interpret digits. "280" = 280, period.**

            Indian magnitudes: "lakh" = 100000, "crore" = 10000000.

            **CRITICAL SPEECH-RECOGNITION FIX:** iOS often transcribes \
            "two" as "to" or "too". In an expense context, these are \
            ALWAYS the number two:
            - "to 80" or "to eighty" = 280 (NOT 80)
            - "to 50" or "to fifty" = 250 (NOT 50)
            - "to hundred" = 200
            - "too 80" = 280
            Apply the same ONES × 100 + TENS rule after correcting.

            **Never drop the hundreds component.** "Two eighty" is 280, \
            not 80. "Three fifty" is 350, not 50. If you only hear \
            "fifty" alone in the transcript, that's 50 — but as soon as \
            a small digit precedes the tens word, multiply.

            Common Indian-English speech-recognition mistakes — CORRECT \
            them based on context:
            - "rahul", "flat", "raffle", "waffel" near a food context → \
              likely "waffle"
            - "pune", "panner" near food → likely "paneer"
            - "berani", "biriyani" → "biryani"
            - "old uh" near transport → "ola"
            - "swiggy" might be heard as "swigy", "swiggi" — fix

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

            **Item extraction guidance.** Whenever the input mentions BOTH \
            a thing-bought and a place ("dinner at restaurant", "tea at \
            cafe", "coffee from chai point", "subzi from market"), put \
            the thing-bought in `item` — even when it's a meal type or \
            generic word like "dinner", "lunch", "snacks", "drinks". \
            Item is null only when no separate thing-bought is mentioned \
            (e.g. "ola 480" — Ola is the merchant, no item).

            Examples:
            - "spent 350 for dinner at ramachandra restaurant" → \
              amount 350, merchant "Ramachandra Restaurant", item "Dinner", category "Food"
            - "three fifty for dinner at ramachandra" → \
              amount 350, merchant "Ramachandra", item "Dinner", category "Food"
            - "spent 250 rupees on waffle at waffle hub" → amount 250, \
              merchant "Waffle Hub", item "Waffle", category "Food"
            - "300 for lunch at sagar ratna" → amount 300, \
              merchant "Sagar Ratna", item "Lunch", category "Food"
            - "80 for tea at irani cafe" → amount 80, \
              merchant "Irani Cafe", item "Tea", category "Food"
            - "four eighty ola to airport" → amount 480, merchant "Ola", \
              item null, category "Transport"
            - "150 chai from cash" → amount 150, merchant "Chai", \
              item null, category "Food", account "Cash"
            - "350 biryani at paradise" → merchant "Paradise", item "Biryani"
            - "200 paneer butter masala from haldiram" → merchant "Haldiram", \
              item "Paneer Butter Masala"

            RESPOND WITH ONLY THE JSON OBJECT. NOTHING ELSE.
            """
        } else {
            systemPrompt = """
            You are a JSON-only expense parser. You MUST respond with ONLY a single valid JSON object. \
            No explanations, no markdown, no code fences, no extra text before or after the JSON.

            Schema: {"amount":number,"merchant":string|null,"item":string|null,"category":string|null,"account":string|null}

            You are TULA's senior expense parser. Your output goes DIRECTLY \
            into the user's expense database with no human review.
            \(contextSection)
            You parse expense log entries from Indian users. Inputs are typically \
            short, casual, and may mix Hindi/English. Extract:
            - amount: total spent in rupees, as a number.
            - merchant: where the money went (the place, vendor, or app).
            - item: what was bought, if mentioned separately from the merchant.
            - category: pick ONE — match the merchant/item to the parenthesized \
              keywords (e.g. petrol/fuel → Transport, restaurants → Food):
            \(categoryList)
            - account: best fit from this exact list, or null if none mentioned: \
              \(accountList)

            Rules:
            - If amount is unclear, return 0.
            - Keep merchant short — the business or place name only, no padding.
            - For meals/snacks/drinks, prefer "Food". For raw groceries, "Groceries".

            Whenever the input mentions both a thing-bought and a place \
            ("dinner at X", "tea at Y", "lunch from Z"), put the thing in \
            `item` — including meal types like dinner/lunch/breakfast/snacks/tea.

            Examples:
            - "spent 250 on biryani" → amount 250, merchant "Biryani", item null, category "Food"
            - "ola to airport 480" → amount 480, merchant "Ola", item null, category "Transport"
            - "150 for chai at chai point" → amount 150, merchant "Chai Point", item "Chai", category "Food"
            - "560 for dinner at ramachandra restaurant" → amount 560, merchant "Ramachandra Restaurant", item "Dinner", category "Food"
            - "subzi ke liye 200 diye" → amount 200, merchant "Subzi", item null, category "Groceries"

            RESPOND WITH ONLY THE JSON OBJECT. NOTHING ELSE.
            """
        }

        let normalizedInput = SmartExpenseParser.normalizeIndianNumbers(in: input)

        guard let json = await callChatCompletions(
            config: cfg,
            systemPrompt: systemPrompt,
            userMessage: normalizedInput
        ) else { return nil }

        let amount = json["amount"] as? Double ?? 0
        let merchant = json["merchant"] as? String
        let item = json["item"] as? String
        let category = json["category"] as? String
        let account = json["account"] as? String

        return SmartParseResult(
            amount: amount,
            merchant: merchant,
            item: item,
            category: category,
            account: account
        )
    }

    // MARK: - Receipt Text Parse

    static func parseReceipt(_ rawText: String,
                              categories: [CategoryEntry],
                              documentType: ReceiptStorage.DocumentType = .generic,
                              contextBlock: String = "",
                              config: CloudAIConfig? = nil) async -> ReceiptSmartParseResult? {
        let cfg = config ?? CloudAIConfig.load()
        guard !cfg.apiKey.isEmpty else { return nil }

        let systemPrompt = buildReceiptSystemPrompt(
            categories: categories,
            documentType: documentType,
            contextBlock: contextBlock
        )

        let json: [String: Any]?
        if isGeminiConfig(cfg) {
            json = await callGeminiNativeText(
                config: cfg,
                systemPrompt: systemPrompt,
                userMessage: rawText,
                schema: receiptSchema
            )
        } else {
            json = await callChatCompletions(
                config: cfg,
                systemPrompt: systemPrompt,
                userMessage: rawText
            )
        }

        guard let json else { return nil }
        return validateReceiptResult(decodeReceiptJSON(json))
    }

    // MARK: - Image-Based Receipt Parse

    static func parseReceiptImage(_ imageData: Data,
                                   categories: [CategoryEntry],
                                   contextBlock: String = "",
                                   config: CloudAIConfig? = nil) async -> ReceiptSmartParseResult? {
        let cfg = config ?? CloudAIConfig.load()
        guard !cfg.apiKey.isEmpty else {
            aiLog.error("parseReceiptImage: API key is empty")
            return nil
        }
        aiLog.info("parseReceiptImage: starting, model=\(cfg.model), imageSize=\(imageData.count / 1024)KB, contextLen=\(contextBlock.count)")

        let resizedData = Self.resizeImageData(imageData, maxDimension: 2048, quality: 0.85)
        let finalImageData = resizedData ?? imageData

        aiLog.info("parseReceiptImage: image \(imageData.count / 1024)KB → \(finalImageData.count / 1024)KB")

        let base64Image = finalImageData.base64EncodedString()
        let mimeType = finalImageData.detectMimeType()

        let systemPrompt: String
        if isGeminiConfig(cfg) {
            systemPrompt = buildGeminiImagePrompt(categories: categories, contextBlock: contextBlock)
        } else {
            systemPrompt = buildReceiptSystemPrompt(
                categories: categories,
                documentType: .generic,
                contextBlock: contextBlock,
                isImage: true
            )
        }

        guard let json = await callImageChatCompletions(
            config: cfg,
            systemPrompt: systemPrompt,
            imageBase64: base64Image,
            mimeType: mimeType
        ) else { return nil }

        return validateReceiptResult(decodeReceiptJSON(json))
    }

    private static func buildGeminiImagePrompt(categories: [CategoryEntry], contextBlock: String = "") -> String {
        let categoryList = CategoryHint.formatList(
            categories.map { (name: $0.name, iconKey: $0.iconKey) }
        )
        let contextSection = contextBlock.isEmpty ? "" : "\n\n\(contextBlock)\n"

        return """
        You are a receipt parser. Read this receipt image and extract ALL of \
        the following fields. Every field matters — do NOT skip any.
        \(contextSection)
        FIELD: "amount" (number, REQUIRED)
        The GRAND TOTAL — the final amount the customer paid. Look for the \
        largest bold number near the bottom, labeled "Total" / "Grand Total" / \
        "Net Amount" / "Bill Total" / "Amount Paid". Read every digit exactly \
        as printed. Never round or estimate. Indian number format: "1,250" = \
        1250. If the same number appears as both "Subtotal" and "Total", the \
        amount is that number ONCE.

        FIELD: "merchant" (string, REQUIRED)
        The business name — the restaurant, shop, or store name. Title-case it.
        **DELIVERY APP SCREENSHOTS (Swiggy, Zomato, Blinkit, Zepto, Instamart):**
        The app name (Swiggy, Zomato, etc.) is NEVER the merchant. Look for \
        the RESTAURANT or STORE name — it appears below the app header, often \
        with a cuisine type, rating, or location subtitle next to it. Examples: \
        "Meghana Foods", "Paradise Biryani", "Burger King", "DMart". The app \
        brand is just the platform — the merchant is who prepared/sold the food.
        **PRINTED RECEIPTS:** The merchant is usually at the top in larger text.
        If a merchant in the FREQUENT MERCHANTS list (above) visually matches \
        what's printed — even partially or with OCR errors — use the canonical \
        spelling from the list.

        FIELD: "items" (array, REQUIRED — must not be empty for receipts)
        List EVERY purchased product, dish, or service as a separate object \
        with "name" (string) and "price" (number). Read each line item from \
        the receipt — do NOT skip any, do NOT merge items. If a line shows \
        quantity and total (e.g. "Naan x2 = 80"), use the line total (80). \
        EXCLUDE: tax, CGST, SGST, GST, VAT, service charge, delivery fee, \
        discount, subtotal, total, tip, round-off, packaging, container charge.

        FIELD: "category" (string, REQUIRED)
        Pick exactly ONE from this list based on the merchant and items:
        \(categoryList)

        FIELD: "date" (string)
        Transaction date in YYYY-MM-DD format. Indian dates are DD/MM/YYYY \
        (day first). Return null only if no date is visible on the receipt.

        BEFORE YOU RESPOND — verify your answer:
        1. Add up all item prices. Does the sum roughly equal the amount \
        (within ±25% for tax/service charge)? If not, re-read the receipt.
        2. Did you list EVERY visible line item? Count them on the receipt \
        and count them in your items array — they must match.
        3. Is the amount the GRAND TOTAL printed on the receipt, not a \
        subtotal or a single item's price?
        4. Is the merchant the actual business name from the receipt header?
        Take your time. One correct answer is worth more than a fast wrong one.
        """
    }

    // MARK: - Receipt Prompt Builder

    private static func buildReceiptSystemPrompt(
        categories: [CategoryEntry],
        documentType: ReceiptStorage.DocumentType,
        contextBlock: String,
        isImage: Bool = false
    ) -> String {
        let categoryList = CategoryHint.formatList(
            categories.map { (name: $0.name, iconKey: $0.iconKey) }
        )
        let contextSection = contextBlock.isEmpty ? "" : "\n\n\(contextBlock)\n"
        let sourceNote = isImage
            ? """
            You extract structured expense data from receipt/bill IMAGES. \
            Read the image carefully and thoroughly — you are the OCR AND \
            the parser in one step. Read EVERY digit exactly as printed. \
            \
            **READING NUMBERS — CRITICAL RULES:** \
            - Read each digit individually from the image. Do NOT estimate or round. \
            - If a number looks like "₹ 1 4 0", that's 140 — not 14, not 1400. \
            - Watch for OCR-like confusion: 1/l/I, 0/O, 5/S, 8/B — always pick \
              the digit that makes arithmetic sense. \
            - Commas in Indian notation: "1,250" = 1250, "12,500" = 12500. \
            - NEVER invent a number. Every price and total must be visible in the image. \
            \
            **ITEM EXTRACTION IS CRITICAL.** Read EVERY individual line \
            item printed on the receipt — dish names, product names, \
            service names. Return each as a separate {"name":"...","price":...} \
            entry in the items array. Do NOT skip items. Do NOT merge items. \
            \
            **QUANTITY × PRICE lines:** If a line shows "Qty 2 × ₹120 = ₹240", \
            return ONE item with name and price = 240 (the line total the customer paid). \
            If quantities are not shown, the printed price IS the price. \
            \
            **EXCLUDE these from items array:** CGST, SGST, GST, VAT, service charge, \
            delivery fee, platform fee, packaging charge, container charge, subtotal, \
            total, grand total, discount, round-off, tip, cash/change lines. \
            \
            **DELIVERY APP SCREENSHOTS (Swiggy / Zomato / Blinkit / Zepto):** \
            The app name is NEVER the merchant. The merchant is the \
            RESTAURANT or STORE name shown below the app header, often \
            with a cuisine type, rating, or location next to it. \
            Extract every ordered item with its individual price. \
            \
            For UPI payment screenshots, items will be empty ([]) — \
            focus on amount, merchant (payee), and date instead.
            """
            : "You extract structured expense data from OCR'd receipt text. OCR is imperfect — characters may be garbled. Read carefully; the actual receipt was clear, only the recognition is noisy."

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
                  - Merchant name patterns:
                    * "stores", "kirana", "supermarket" → Groceries
                    * "petrol", "fuel", "HP", "BPCL", "IOC" → Transport
                    * "restaurant", "cafe", "kitchen", "biryani", \
                      "dosa", food chain name → Food
                    * "pharmacy", "medical", "hospital", "clinic" → Health
                    * "electricity", "BSES", "TSSPDCL" → Bills
                    * Individual person's name (no business indicator) → \
                      leave category null if no clear context
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
                the services / procedures / medicines listed.
                """
            case .utilityBill:
                return """

                LAYOUT: This is a utility bill (electricity, water, gas, \
                broadband, mobile). One main amount labeled "Amount Due" / \
                "Total Payable" / "Bill Amount", accompanied by a due \
                date. Merchant = utility provider name. items: []. \
                Category should be "Bills" / "Utilities" / similar.
                """
            case .generic:
                return ""
            }
        }()

        return """
        You are a JSON-only receipt parser. You MUST respond with ONLY a single valid JSON object. \
        No explanations, no markdown, no code fences, no extra text before or after the JSON.

        Schema: {"amount":number,"merchant":string|null,"date":"YYYY-MM-DD"|null,"category":string|null,"items":[{"name":string,"price":number}]}

        You are TULA's senior receipt parser. Your output goes DIRECTLY \
        into the user's expense database with no review. Wrong values \
        create rework. Aim to be RIGHT, not creative.

        \(sourceNote)
        \(contextSection)
        Parse this receipt into structured data. Fields:

        - **amount**: the GRAND TOTAL — the final amount billed. ONE \
          value, printed verbatim on the receipt. NEVER sum two values \
          to derive it.

        - **merchant**: business / place name. Title-cased. If NO clear \
          business name appears, INFER a GENERIC PLACE TYPE from the \
          items: "Restaurant", "Pharmacy", "Grocery Store", etc.

        - **date**: transaction date in YYYY-MM-DD format. null if not present.

        - **items**: EVERY individual purchased item as {"name", "price"}. \
          Read each line item from the receipt — do NOT skip any, do NOT \
          merge multiple items into one. Each dish, product, or service \
          gets its own entry. EXCLUDE tax, subtotal, total, discount, \
          change, tip, and payment-method lines.

        - **category**: pick ONE from the list below. Decision priority:
            1. MERCHANT matches a category's keywords → use that.
            2. ITEMS suggest a category → use that.
            3. Other signals in the text.
            4. NEVER invent a category not in this list.
            5. **Prefer null over a bad guess.**

        Available categories (parenthesized keywords describe what fits):
        \(categoryList)
        \(layoutHint)

        KEY RULES:
        1. **Same value appearing twice = one bill, not double.** If "140" \
           appears as both subtotal and grand total, the amount is 140.
        2. **Amount must be a value printed on the receipt.** NEVER compute \
           it by summing items yourself. Find the number next to "Total" / \
           "Grand Total" / "Net Amount" / "Bill Total" / "Amount Paid".
        3. **For multi-section bills** (hospital, utility), the FINAL net \
           payable is at the BOTTOM.
        4. **CROSS-CHECK:** After extracting items and the total, verify: \
           does the sum of item prices roughly equal the total (±25% for \
           tax/service charge)? If they're wildly different, re-read the \
           image — you likely misread a digit in the total or missed items.
        5. **When in doubt about a number, prefer the reading that makes \
           the total consistent with the items.**

        RESPOND WITH ONLY THE JSON OBJECT. NOTHING ELSE.
        """
    }

    // MARK: - Response Decoding

    private static func decodeReceiptJSON(_ json: [String: Any]) -> ReceiptSmartParseResult {
        let amount = flexDouble(json["amount"]) ?? 0
        let merchant = json["merchant"] as? String
        let date = json["date"] as? String
        let category = json["category"] as? String

        var items: [ReceiptLineItem] = []
        if let rawItems = json["items"] as? [[String: Any]] {
            for (i, item) in rawItems.enumerated() {
                let name = item["name"] as? String
                let price = flexDouble(item["price"])
                if let name, let price {
                    items.append(ReceiptLineItem(name: name, price: price))
                } else {
                    aiLog.warning("Item[\(i)] dropped: name=\(name ?? "nil"), price=\(String(describing: item["price"]))")
                }
            }
        }

        aiLog.info("Decoded: amount=\(amount), merchant=\(merchant ?? "nil"), items=\(items.count)/\(json["items"].map { "\(($0 as? [Any])?.count ?? 0)" } ?? "0") raw, date=\(date ?? "nil")")

        return ReceiptSmartParseResult(
            amount: amount,
            merchant: merchant,
            date: date,
            category: category,
            items: items
        )
    }

    private static func flexDouble(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    // MARK: - Post-Parse Validation

    private static func validateReceiptResult(_ result: ReceiptSmartParseResult) -> ReceiptSmartParseResult {
        var amount = result.amount
        let items = result.items.filter { !$0.name.isEmpty }
        let itemsSum = items.reduce(0.0) { $0 + $1.price }

        if amount <= 0 && itemsSum > 0 {
            amount = itemsSum
            print("☁️ [Validate] amount was 0, inferred from items sum: \(itemsSum)")
        }

        if !items.isEmpty && amount > 0 && itemsSum > 0 {
            let ratio = itemsSum / amount
            if ratio < 0.3 || ratio > 3.0 {
                print("☁️ [Validate] ⚠️ Items sum (\(itemsSum)) vs amount (\(amount)) ratio \(String(format: "%.2f", ratio)) — likely misread")
            }
        }

        var merchant = result.merchant?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let m = merchant, m.isEmpty || m.lowercased() == "null" || m.lowercased() == "n/a" {
            merchant = nil
        }

        var date = result.date
        if let d = date, d.isEmpty || d.lowercased() == "null" {
            date = nil
        }

        var category = result.category?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let c = category, c.isEmpty || c.lowercased() == "null" {
            category = nil
        }

        return ReceiptSmartParseResult(
            amount: amount,
            merchant: merchant,
            date: date,
            category: category,
            items: items
        )
    }

    // MARK: - Gemini Detection

    private static func isGeminiConfig(_ config: CloudAIConfig) -> Bool {
        config.endpoint.contains("generativelanguage.googleapis.com")
    }

    private static func sanitizedGeminiModel(_ raw: String) -> String {
        let m = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "models/", with: "")
        let fallback = "gemini-2.5-flash"
        if m.isEmpty || !m.hasPrefix("gemini") {
            aiLog.info("Gemini model: raw=\"\(raw)\" is invalid, using \(fallback)")
            return fallback
        }
        return m
    }

    // MARK: - JSON Schemas for Gemini Native API

    private static let expenseSchema: [String: Any] = [
        "type": "OBJECT",
        "properties": [
            "amount": ["type": "NUMBER", "description": "Total amount spent"],
            "merchant": ["type": "STRING", "description": "Place or vendor name", "nullable": true],
            "item": ["type": "STRING", "description": "What was bought", "nullable": true],
            "category": ["type": "STRING", "description": "Category name from provided list", "nullable": true],
            "account": ["type": "STRING", "description": "Payment account", "nullable": true]
        ],
        "required": ["amount"]
    ]

    private static let receiptSchema: [String: Any] = [
        "type": "OBJECT",
        "properties": [
            "amount": ["type": "NUMBER", "description": "Grand total amount paid"],
            "merchant": ["type": "STRING", "description": "Business or store name from the receipt"],
            "date": ["type": "STRING", "description": "Date in YYYY-MM-DD format", "nullable": true],
            "category": ["type": "STRING", "description": "Expense category from the provided list"],
            "items": [
                "type": "ARRAY",
                "description": "Every individual purchased item from the receipt",
                "items": [
                    "type": "OBJECT",
                    "properties": [
                        "name": ["type": "STRING", "description": "Item name as printed on receipt"],
                        "price": ["type": "NUMBER", "description": "Item price in rupees"]
                    ],
                    "required": ["name", "price"]
                ]
            ]
        ],
        "required": ["amount", "merchant", "category", "items"]
    ]

    // MARK: - HTTP (OpenAI-compatible — used for OpenAI/Azure/Ollama)

    private static func callChatCompletions(
        config: CloudAIConfig,
        systemPrompt: String,
        userMessage: String
    ) async -> [String: Any]? {
        if isGeminiConfig(config) {
            if let result = await callGeminiNativeText(
                config: config,
                systemPrompt: systemPrompt,
                userMessage: userMessage,
                schema: expenseSchema
            ) {
                return result
            }
            aiLog.info("Native Gemini text failed, falling back to OpenAI-compat endpoint")
        }

        guard let url = URL(string: config.endpoint) else { return nil }

        let modelName = isGeminiConfig(config) ? sanitizedGeminiModel(config.model) : config.model
        let body: [String: Any] = [
            "model": modelName,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage]
            ],
            "temperature": 0.1,
            "max_tokens": 500
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        if config.endpoint.contains("openai.azure.com") {
            request.setValue(config.apiKey, forHTTPHeaderField: "api-key")
        } else {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = jsonData

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse else {
            print("☁️ [CloudAI] Request failed — no response")
            return nil
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "(no body)"
            print("☁️ [CloudAI] HTTP \(httpResponse.statusCode): \(errorBody)")
            return nil
        }

        return parseOpenAIResponse(data)
    }

    private static func callImageChatCompletions(
        config: CloudAIConfig,
        systemPrompt: String,
        imageBase64: String,
        mimeType: String
    ) async -> [String: Any]? {
        if isGeminiConfig(config) {
            if let result = await callGeminiNativeImage(
                config: config,
                systemPrompt: systemPrompt,
                imageBase64: imageBase64,
                mimeType: mimeType,
                schema: receiptSchema
            ) {
                return result
            }
            aiLog.info("Native Gemini image failed, falling back to OpenAI-compat endpoint")
        }

        guard let url = URL(string: config.endpoint) else {
            print("🖼️ [CloudAI] Invalid endpoint URL: \(config.endpoint)")
            return nil
        }

        let userContent: [[String: Any]] = [
            ["type": "text", "text": Self.imageUserMessage],
            ["type": "image_url", "image_url": ["url": "data:\(mimeType);base64,\(imageBase64)"]]
        ]

        let modelName = isGeminiConfig(config) ? sanitizedGeminiModel(config.model) : config.model
        let body: [String: Any] = [
            "model": modelName,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent]
            ],
            "temperature": 0.05,
            "max_tokens": 2000
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 90

        if config.endpoint.contains("openai.azure.com") {
            request.setValue(config.apiKey, forHTTPHeaderField: "api-key")
        } else {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = jsonData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                if let data = try? await URLSession.shared.data(for: request).0 {
                    print("🖼️ [CloudAI] Error: \(String(data: data, encoding: .utf8) ?? "")")
                }
                return nil
            }
            return parseOpenAIResponse(data)
        } catch {
            print("🖼️ [CloudAI] Error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Gemini Native API

    private static func callGeminiNativeText(
        config: CloudAIConfig,
        systemPrompt: String,
        userMessage: String,
        schema: [String: Any]
    ) async -> [String: Any]? {
        guard let url = geminiNativeURL(config: config) else { return nil }

        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": systemPrompt]]],
            "contents": [[
                "role": "user",
                "parts": [["text": userMessage]]
            ]],
            "generationConfig": [
                "temperature": 0.1,
                "responseMimeType": "application/json",
                "responseSchema": schema
            ]
        ]

        return await executeGeminiRequest(url: url, body: body, label: "Text")
    }

    private static func callGeminiNativeImage(
        config: CloudAIConfig,
        systemPrompt: String,
        imageBase64: String,
        mimeType: String,
        schema: [String: Any]
    ) async -> [String: Any]? {
        guard let url = geminiNativeURL(config: config) else { return nil }

        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": systemPrompt]]],
            "contents": [[
                "role": "user",
                "parts": [
                    ["text": Self.imageUserMessage],
                    ["inlineData": ["mimeType": mimeType, "data": imageBase64]]
                ]
            ]],
            "generationConfig": [
                "temperature": 0.0,
                "responseMimeType": "application/json",
                "responseSchema": schema
            ]
        ]

        return await executeGeminiRequest(url: url, body: body, label: "Image")
    }

    private static let imageUserMessage = """
    Read this receipt image carefully. Extract ALL fields: the grand total \
    (amount), the ACTUAL merchant/restaurant name (NOT the delivery app), \
    every individual line item with its price, the category, and the date. \
    Do not skip any items or leave any field empty.
    """

    private static func geminiNativeURL(config: CloudAIConfig) -> URL? {
        let model = sanitizedGeminiModel(config.model)
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(config.apiKey)"
        guard let url = URL(string: urlString) else {
            aiLog.error("Invalid native URL for model: \(model)")
            return nil
        }
        return url
    }

    private static func executeGeminiRequest(
        url: URL,
        body: [String: Any],
        label: String
    ) async -> [String: Any]? {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            aiLog.error("[\(label)] Failed to serialize request body")
            return nil
        }

        aiLog.info("[\(label)] Sending request, bodySize=\(jsonData.count / 1024)KB")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 90
        request.httpBody = jsonData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                aiLog.error("[\(label)] Response is not HTTP")
                return nil
            }

            aiLog.info("[\(label)] HTTP \(httpResponse.statusCode), responseSize=\(data.count)")

            guard httpResponse.statusCode == 200 else {
                let errorBody = String(data: data, encoding: .utf8) ?? "(no body)"
                aiLog.error("[\(label)] HTTP \(httpResponse.statusCode): \(errorBody.prefix(500))")
                return nil
            }

            return parseGeminiResponse(data, label: label)
        } catch {
            aiLog.error("[\(label)] Network error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Response Parsing

    private static func parseGeminiResponse(_ data: Data, label: String) -> [String: Any]? {
        guard let responseJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = responseJSON["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let textPart = parts.first,
              let text = textPart["text"] as? String else {
            print("☁️ [Gemini \(label)] Failed to parse response structure")
            if let raw = String(data: data, encoding: .utf8) {
                print("☁️ [Gemini \(label)] Raw: \(raw.prefix(1000))")
            }
            return nil
        }

        let cleaned = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let contentData = cleaned.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any] else {
            print("☁️ [Gemini \(label)] Failed to parse JSON: \(cleaned.prefix(500))")
            return nil
        }

        print("☁️ [Gemini \(label)] Parsed result: \(cleaned.prefix(1000))")
        return parsed
    }

    private static func parseOpenAIResponse(_ data: Data) -> [String: Any]? {
        guard let responseJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = responseJSON["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            print("☁️ [CloudAI] Failed to parse response structure")
            return nil
        }

        let cleaned = content
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let contentData = cleaned.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any] else {
            print("☁️ [CloudAI] Failed to parse JSON: \(cleaned.prefix(500))")
            return nil
        }

        return parsed
    }

    // MARK: - Image Preprocessing

    private static func preprocessReceiptImage(_ data: Data, maxDimension: CGFloat, quality: CGFloat) -> Data? {
        guard let uiImage = UIImage(data: data),
              let ciInput = CIImage(image: uiImage) else {
            return resizeImageData(data, maxDimension: maxDimension, quality: quality)
        }

        var enhanced = ciInput

        // Modest contrast boost — helps faded thermal receipts and
        // low-light restaurant bills without blowing out well-lit ones.
        if let contrast = CIFilter(name: "CIColorControls") {
            contrast.setValue(enhanced, forKey: kCIInputImageKey)
            contrast.setValue(1.12, forKey: kCIInputContrastKey)
            contrast.setValue(0.02, forKey: kCIInputBrightnessKey)
            contrast.setValue(1.0, forKey: kCIInputSaturationKey)
            if let output = contrast.outputImage { enhanced = output }
        }

        // Light sharpen — phone-camera blur on small receipt text.
        if let sharpen = CIFilter(name: "CISharpenLuminance") {
            sharpen.setValue(enhanced, forKey: kCIInputImageKey)
            sharpen.setValue(0.4, forKey: kCIInputSharpnessKey)
            if let output = sharpen.outputImage { enhanced = output }
        }

        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = ctx.createCGImage(enhanced, from: enhanced.extent) else {
            return resizeImageData(data, maxDimension: maxDimension, quality: quality)
        }

        let processed = UIImage(cgImage: cgImage, scale: uiImage.scale, orientation: uiImage.imageOrientation)
        let size = processed.size
        let longestSide = max(size.width, size.height)

        if longestSide <= maxDimension {
            return processed.jpegData(compressionQuality: quality)
        }

        let scale = maxDimension / longestSide
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in
            processed.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return resized.jpegData(compressionQuality: quality)
    }

    private static func resizeImageData(_ data: Data, maxDimension: CGFloat, quality: CGFloat) -> Data? {
        guard let image = UIImage(data: data) else { return nil }

        let size = image.size
        let longestSide = max(size.width, size.height)

        if longestSide <= maxDimension {
            return image.jpegData(compressionQuality: quality)
        }

        let scale = maxDimension / longestSide
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }

        return resized.jpegData(compressionQuality: quality)
    }
}

// MARK: - Data MIME Type Detection

extension Data {
    func detectMimeType() -> String {
        var header = [UInt8](repeating: 0, count: Swift.min(count, 12))
        copyBytes(to: &header, count: header.count)

        if header.starts(with: [0xFF, 0xD8, 0xFF]) {
            return "image/jpeg"
        } else if header.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return "image/png"
        } else if header.starts(with: [0x47, 0x49, 0x46]) {
            return "image/gif"
        } else if header.count >= 12 && header[8...11] == [0x57, 0x45, 0x42, 0x50] {
            return "image/webp"
        }
        return "image/jpeg"
    }
}
