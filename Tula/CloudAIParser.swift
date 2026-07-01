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

    @MainActor static var lastParseError: String?

    // MARK: - Text / Voice Parse

    static func parse(_ input: String,
                      categories: [CategoryEntry],
                      accounts: [AccountEntry] = [],
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
        let accountList = accounts.isEmpty
            ? "(no account list provided)"
            : accounts.map { entry in
                var s = entry.name + " [\(entry.kind)]"
                if let d = entry.last4Digits, !d.isEmpty { s += " (ending \(d))" }
                return s
            }.joined(separator: ", ")

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
            - account: best fit from this exact list. Match by name, type keywords \
              (credit card, bank, UPI, cash, wallet), or last-4 digits. Return ONLY \
              the account name (no brackets/digits), or null if none mentioned. List: \(accountList)

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
            - "150 chai from cash" → amount 150, merchant null, \
              item "Chai", category "Food", account "Cash"
            - "350 biryani at paradise" → amount 350, merchant "Paradise", \
              item "Biryani", category "Food"
            - "200 paneer butter masala from haldiram" → amount 200, \
              merchant "Haldiram", item "Paneer Butter Masala", category "Food"
            - "swiggy 450" → amount 450, merchant "Swiggy", item null, category "Food"
            - "petrol 500" → amount 500, merchant null, item "Petrol", category "Transport"
            - "two thousand rent" → amount 2000, merchant null, item "Rent", category "Bills"
            - "grocery 800 dmart" → amount 800, merchant "DMart", \
              item "Grocery", category "Groceries"
            - "recharge 299 airtel" → amount 299, merchant "Airtel", \
              item "Recharge", category "Bills"
            - "milk bread eggs 350" → amount 350, merchant null, \
              item "Milk, Bread, Eggs", category "Groceries"
            - "medicines 120 apollo pharmacy" → amount 120, \
              merchant "Apollo Pharmacy", item "Medicines", category "Health"

            **CRITICAL:** When no preposition (at/from) is present and the \
            input is just "MERCHANT AMOUNT" or "AMOUNT MERCHANT" (e.g. \
            "swiggy 450", "450 zomato"), set the known app/brand as \
            merchant and item as null. For generic items without a place \
            (e.g. "petrol 500", "grocery 800"), set merchant null and \
            the item to what was bought.

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
            - account: best fit from this exact list. Match by name, type \
              keywords, or last-4 digits. Return ONLY the account name \
              (no brackets/digits), or null. List: \(accountList)

            Rules:
            - If amount is unclear, return 0.
            - Keep merchant short — the business or place name only, no padding.
            - For meals/snacks/drinks, prefer "Food". For raw groceries, "Groceries".

            Whenever the input mentions both a thing-bought and a place \
            ("dinner at X", "tea at Y", "lunch from Z"), put the thing in \
            `item` — including meal types like dinner/lunch/breakfast/snacks/tea.

            Examples:
            - "spent 250 on biryani" → amount 250, merchant null, item "Biryani", category "Food"
            - "ola to airport 480" → amount 480, merchant "Ola", item null, category "Transport"
            - "150 for chai at chai point" → amount 150, merchant "Chai Point", item "Chai", category "Food"
            - "560 for dinner at ramachandra restaurant" → amount 560, merchant "Ramachandra Restaurant", item "Dinner", category "Food"
            - "subzi ke liye 200 diye" → amount 200, merchant null, item "Subzi", category "Groceries"
            - "swiggy 450" → amount 450, merchant "Swiggy", item null, category "Food"
            - "petrol 500" → amount 500, merchant null, item "Petrol", category "Transport"
            - "grocery 800 dmart" → amount 800, merchant "DMart", item "Grocery", category "Groceries"

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
        let date = json["date"] as? String

        return SmartParseResult(
            amount: amount,
            merchant: merchant,
            item: item,
            category: category,
            account: account,
            date: date
        )
    }

    // MARK: - Multi-Expense Voice Parse

    /// Parse a voice transcript that contains multiple expenses into an
    /// array of structured results. Uses the same voice prompt conventions
    /// but instructs the model to return `{"expenses": [...]}`.
    static func parseVoiceMulti(
        _ input: String,
        categories: [CategoryEntry],
        accounts: [AccountEntry] = [],
        contextBlock: String = "",
        config: CloudAIConfig? = nil
    ) async -> [SmartParseResult]? {
        let cfg = config ?? CloudAIConfig.load()
        guard !cfg.apiKey.isEmpty else { return nil }
        aiLog.info("parseVoiceMulti: starting, model=\(cfg.model), input=\(input.prefix(80))")

        let categoryList = CategoryHint.formatList(
            categories.map { (name: $0.name, iconKey: $0.iconKey) }
        )
        let accountList = accounts.isEmpty
            ? "(no account list provided)"
            : accounts.map { entry in
                var s = entry.name + " [\(entry.kind)]"
                if let d = entry.last4Digits, !d.isEmpty { s += " (ending \(d))" }
                return s
            }.joined(separator: ", ")
        let contextSection = contextBlock.isEmpty ? "" : "\n\n\(contextBlock)\n"

        let systemPrompt = """
        You are a JSON-only expense parser for MULTIPLE expenses in one voice transcript. \
        You MUST respond with ONLY a valid JSON object. No explanations, no markdown, no code fences.

        Schema: {"expenses":[{"amount":number,"merchant":string|null,"item":string|null,"category":string|null,"account":string|null}]}

        The user dictated MULTIPLE expenses in a single voice message. Extract EACH \
        expense separately. Common patterns:
        - "350 swiggy and 200 groceries" → 2 expenses
        - "coffee 80 lunch 250 auto 150" → 3 expenses
        - "spent 500 on dinner and 300 on fuel" → 2 expenses
        \(contextSection)
        Parse voice transcripts from Indian users. Speech recognition may have errors.

        Amount rules:
        - Indian shorthand: "two fifty" = 250, "three twenty" = 320, "four eighty" = 480
        - "to 80" / "too fifty" → "two eighty" = 280 / "two fifty" = 250
        - Plain numbers like "280", "350" → use AS IS
        - "lakh" = 100000, "crore" = 10000000

        Categories (pick ONE per expense from this list):
        \(categoryList)

        Accounts: \(accountList)
        If "from cash" / "using X" appears at the end, apply that account to ALL expenses.

        Merchant = place/vendor/app. Item = what was bought. Indian dishes are items, \
        not merchants (biryani, dosa, chai = items; Swiggy, Zomato, DMart = merchants).

        RESPOND WITH ONLY THE JSON OBJECT. NOTHING ELSE.
        """

        let normalizedInput = SmartExpenseParser.normalizeIndianNumbers(in: input)

        // Route: Gemini native API (with structured schema) or OpenAI-compat.
        let json: [String: Any]?
        if isGeminiConfig(cfg) {
            json = await callGeminiNativeText(
                config: cfg,
                systemPrompt: systemPrompt,
                userMessage: normalizedInput,
                schema: multiExpenseSchema
            )
        } else {
            // OpenAI-compatible endpoint — relies on prompt instructions for JSON.
            guard let url = URL(string: cfg.endpoint) else { return nil }
            let body: [String: Any] = [
                "model": cfg.model,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": normalizedInput]
                ],
                "temperature": 0.1,
                "max_tokens": 1000
            ]
            guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(cfg.apiKey)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 15
            request.httpBody = jsonData
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            json = parseOpenAIResponse(data)
        }

        guard let json,
              let expenses = json["expenses"] as? [[String: Any]],
              !expenses.isEmpty else { return nil }

        return expenses.compactMap { dict in
            let amount = (dict["amount"] as? Double)
                ?? (dict["amount"] as? Int).map(Double.init)
                ?? 0
            guard amount > 0 else { return nil as SmartParseResult? }
            return SmartParseResult(
                amount: amount,
                merchant: dict["merchant"] as? String,
                item: dict["item"] as? String,
                category: dict["category"] as? String,
                account: dict["account"] as? String,
                date: dict["date"] as? String
            )
        }
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
                                   config: CloudAIConfig? = nil,
                                   skipResize: Bool = false) async -> ReceiptSmartParseResult? {
        let parseStart = Date()
        let cfg = config ?? CloudAIConfig.load()
        guard !cfg.apiKey.isEmpty else {
            aiLog.error("parseReceiptImage: API key is empty")
            await MainActor.run { lastParseError = "AI provider not configured. Add your API key in Settings." }
            return nil
        }
        aiLog.info("parseReceiptImage: starting, model=\(cfg.model), imageSize=\(imageData.count / 1024)KB, contextLen=\(contextBlock.count)")

        // skipResize = true → caller already produced an optimised JPEG
        // (ShareSession.prepareImageForGemini). Skip the re-encode to prevent
        // JPEG generation loss on small receipt digits.
        // skipResize = false (default) keeps the existing main-app camera path.
        let prepStart = Date()
        let finalImageData: Data
        if skipResize {
            finalImageData = imageData
        } else {
            // Quality raised 0.65 → 0.82: the old value introduced blocking
            // artifacts on dense receipt text (7-digit amounts, item columns).
            let resizedData = Self.resizeImageData(imageData, maxDimension: 1280, quality: 0.82)
            finalImageData  = resizedData ?? imageData
        }
        let prepMs = Int(Date().timeIntervalSince(prepStart) * 1000)

        aiLog.info("parseReceiptImage: image \(imageData.count / 1024)KB → \(finalImageData.count / 1024)KB (skipResize=\(skipResize)), prep=\(prepMs)ms")

        let b64Start = Date()
        let base64Image = finalImageData.base64EncodedString()
        let mimeType = finalImageData.detectMimeType()
        let b64Ms = Int(Date().timeIntervalSince(b64Start) * 1000)
        aiLog.info("parseReceiptImage: base64 built, time=\(b64Ms)ms")

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

        await MainActor.run { lastParseError = nil }

        let requestStart = Date()
        guard let json = await callImageChatCompletions(
            config: cfg,
            systemPrompt: systemPrompt,
            imageBase64: base64Image,
            mimeType: mimeType
        ) else {
            let totalMs = Int(Date().timeIntervalSince(parseStart) * 1000)
            aiLog.error("parseReceiptImage: failed, total=\(totalMs)ms")
            if await MainActor.run(body: { lastParseError }) == nil {
                await MainActor.run { lastParseError = "Couldn't read the receipt. Try a clearer photo or enter details manually." }
            }
            return nil
        }
        let requestMs = Int(Date().timeIntervalSince(requestStart) * 1000)
        aiLog.info("parseReceiptImage: request+response=\(requestMs)ms")

        let decodeStart = Date()
        let result = validateReceiptResult(decodeReceiptJSON(json))
        let decodeMs = Int(Date().timeIntervalSince(decodeStart) * 1000)
        let totalMs = Int(Date().timeIntervalSince(parseStart) * 1000)
        aiLog.info("parseReceiptImage: decode+validate=\(decodeMs)ms, total=\(totalMs)ms, amount=\(result.amount, privacy: .public), merchantLen=\((result.merchant ?? "").count)")
        if result.amount <= 0 {
            await MainActor.run { lastParseError = "Couldn't find a total on this receipt. Please enter the amount manually." }
        }
        return result
    }

    private static func buildGeminiImagePrompt(categories: [CategoryEntry], contextBlock: String = "") -> String {
        let categoryList = CategoryHint.formatList(
            categories.map { (name: $0.name, iconKey: $0.iconKey) }
        )
        let contextSection = contextBlock.isEmpty ? "" : "\n\n\(contextBlock)\n"

        return """
        Extract receipt data into JSON with these fields:
        \(contextSection)
        "amount": GRAND TOTAL the customer paid (number). Look for "Total"/"Grand Total"/"Bill Total"/"Amount Paid" near the bottom.

        "merchant": The BUSINESS/SHOP name, title-cased (string). \
        **POS terminal receipts** (Pine Labs, Paytm, Worldline): the bank logo/name at the TOP \
        (HDFC Bank, ICICI, SBI, etc.) is the ACQUIRING BANK — NOT the merchant. The merchant \
        is printed BELOW it (e.g. "S N AUTO", "APOLLO PHARMACY"). Extract THAT name. \
        For delivery apps (Swiggy/Zomato/Blinkit), use the RESTAURANT name, not the app. \
        **INDIAN CONTEXT**: "Hotel" in India usually means RESTAURANT, not accommodation. \
        "Subbaiah Gari Hotel", "Udupi Hotel", "Sagar Hotel" are all restaurants.

        "items": Array of {"name","price","quantity"}. \
        name = item name ONLY (no prices, no amounts — strip "370" from "SPL VEG MEALS - 370"). \
        price = line total (qty × unit price). quantity = integer (default 1). \
        EXCLUDE: tax/GST/CGST/SGST/VAT/service charge/discount/subtotal/total/tip/round-off/packaging.

        "discount": Total discount as positive number. null if none.
        "tax": Combined tax (CGST+SGST / GST / VAT / service charge). null if none.

        "category": Pick ONE from this list. \
        Decide by WHAT WAS PURCHASED, not where. Meals/food/dishes/drinks → "Food". \
        Groceries/raw ingredients → "Groceries". Medicines → "Health". Fuel → "Transport". \
        **In India, "Hotel" on a receipt almost always means restaurant = "Food".** \
        \(categoryList)

        "date": YYYY-MM-DD. Indian dates are DD/MM/YYYY (day first). null if missing.
        "time": HH:MM (24h). null if missing.
        "payment_mode": Cash/Card/UPI/etc. null if not visible.
        "card_last4": last 4 digits of the card number if visible (e.g. "9068" from ************9068 or ****9068 or XXXX-5678). Also check CARD NO / A/C NO fields. ONLY the 4 digits. null if not visible.
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

        Schema: {"amount":number,"merchant":string|null,"date":"YYYY-MM-DD"|null,"time":"HH:MM"|null,"category":string|null,"payment_mode":string|null,"card_last4":string|null,"items":[{"name":string,"price":number}]}

        You are TULA's senior receipt parser. Your output goes DIRECTLY \
        into the user's expense database with no review. Wrong values \
        create rework. Aim to be RIGHT, not creative.

        \(sourceNote)
        \(contextSection)
        Parse this receipt into structured data. Fields:

        - **amount**: the GRAND TOTAL — the final amount billed. ONE \
          value, printed verbatim on the receipt. NEVER sum two values \
          to derive it.

        - **merchant**: the BUSINESS / SHOP where the purchase was made. Title-cased. \
          **CRITICAL for POS terminal receipts** (Pine Labs, Paytm POS, \
          Worldline, Ingenico, BharatPe): the bank name/logo at the TOP \
          (HDFC Bank, ICICI, SBI, Axis, IndusInd, etc.) is the ACQUIRING \
          BANK that processes the card transaction — it is NOT the merchant. \
          The actual merchant name is printed BELOW the bank name (e.g. \
          "S N AUTO GROUND FLOOR…" or "APOLLO PHARMACY…"). Extract THAT. \
          For delivery apps (Swiggy/Zomato/Blinkit), use the RESTAURANT name, \
          not the app. If NO clear business name appears, INFER a GENERIC \
          PLACE TYPE from the items: "Restaurant", "Pharmacy", "Grocery Store", etc.

        - **date**: transaction date in YYYY-MM-DD format. null if not present.

        - **time**: transaction time in HH:MM (24-hour) format. null if not present.

        - **items**: EVERY individual purchased item as {"name", "price", \
          "quantity"}. Read each line item — do NOT skip any, do NOT merge. \
          name = item name ONLY (no prices or amounts in the name — strip \
          "370" from "SPL VEG MEALS - 370"). \
          Price = line total (not unit price). Quantity = integer (default 1). \
          EXCLUDE tax, subtotal, total, discount, change, tip lines.

        - **discount**: total discount amount as a positive number. null \
          if no discount on the receipt.

        - **tax**: total tax (CGST+SGST, GST, VAT, service charge combined). \
          null if no tax visible.

        - **payment_mode**: how the customer paid — "Cash", "Card", "UPI", \
          etc. Include the bank/card brand name when visible (e.g. \
          "IndusInd Credit Card", "HDFC Debit Card", "Visa"). \
          null if not visible on the receipt.

        - **card_last4**: the last 4 digits of the card/account number \
          when visible on the receipt. Common masked formats: \
          ************9068, ****1234, XXXX-XXXX-XXXX-5678, \
          "ending 1234", "last 4: 5678". Also check near labels like \
          "CARD NO", "A/C NO", "PAN". Return ONLY the 4 digits as a \
          string (e.g. "9068"). null if no card number is visible.

        - **category**: pick ONE from the list below. Decide by WHAT WAS \
          PURCHASED, not the business type. Meals/food/dishes/drinks → "Food". \
          Groceries/raw ingredients → "Groceries". Medicines → "Health". \
          Fuel → "Transport". \
          **INDIAN CONTEXT**: "Hotel" in India usually means RESTAURANT, \
          not accommodation — e.g. "Subbaiah Gari Hotel", "Udupi Hotel" = Food. \
          NEVER invent a category not in this list. Prefer null over a bad guess.

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
        let time = json["time"] as? String
        let category = json["category"] as? String
        let paymentMode = json["payment_mode"] as? String
        let rawCardLast4 = (json["card_last4"] as? String)?
            .filter(\.isNumber)
        // Accept 2+ digits — a 2-digit suffix combined with card-name
        // matching is enough to identify the right account in most cases.
        let cardLast4 = rawCardLast4.flatMap { $0.count >= 2 ? String($0.suffix(min($0.count, 4))) : nil }

        let discount = flexDouble(json["discount"])
        let tax = flexDouble(json["tax"])

        var items: [ReceiptLineItem] = []
        if let rawItems = json["items"] as? [[String: Any]] {
            for (i, item) in rawItems.enumerated() {
                let name = item["name"] as? String
                let price = flexDouble(item["price"])
                let qty = (item["quantity"] as? Int) ?? (flexDouble(item["quantity"]).map { Int($0) }) ?? 1
                if let name, let price {
                    items.append(ReceiptLineItem(name: name, price: price, quantity: max(qty, 1)))
                } else {
                    aiLog.warning("Item[\(i)] dropped: name=\(name ?? "nil"), price=\(String(describing: item["price"]))")
                }
            }
        }

        aiLog.info("Decoded: amount=\(amount), merchant=\(merchant ?? "nil"), items=\(items.count)/\(json["items"].map { "\(($0 as? [Any])?.count ?? 0)" } ?? "0") raw, date=\(date ?? "nil"), time=\(time ?? "nil"), discount=\(discount ?? 0), tax=\(tax ?? 0)")

        return ReceiptSmartParseResult(
            amount: amount,
            merchant: merchant,
            date: date,
            time: time,
            category: category,
            paymentMode: paymentMode,
            cardLast4: cardLast4,
            items: items,
            discount: discount,
            tax: tax
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

        var time = result.time?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let t = time, t.isEmpty || t.lowercased() == "null" {
            time = nil
        }

        var category = result.category?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let c = category, c.isEmpty || c.lowercased() == "null" {
            category = nil
        }

        var paymentMode = result.paymentMode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let p = paymentMode, p.isEmpty || p.lowercased() == "null" {
            paymentMode = nil
        }

        // cardLast4 passes through from the initial decode
        let cardLast4 = result.cardLast4

        return ReceiptSmartParseResult(
            amount: amount,
            merchant: merchant,
            date: date,
            time: time,
            category: category,
            paymentMode: paymentMode,
            cardLast4: cardLast4,
            items: items,
            discount: result.discount,
            tax: result.tax
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
        if m.isEmpty || !(m.hasPrefix("gemini") || m.hasPrefix("gemma")) {
            aiLog.info("Gemini model: raw=\"\(raw)\" is invalid, using \(fallback)")
            return fallback
        }
        return m
    }

    // MARK: - Model Fallback

    private enum GeminiOutcome {
        case success([String: Any])
        case rateLimited
        case failed(String)
    }

    private static let geminiFallbackModels = [
        "gemini-2.5-flash",
        "gemini-3.5-flash",
        "gemini-2.5-flash-lite",
        "gemini-3.1-flash-lite",
    ]

    // Speed-first chain for receipt image parsing.
    private static let geminiImageSpeedModels = [
        "gemini-2.5-flash-lite",
        "gemini-2.5-flash",
        "gemini-3.1-flash-lite",
    ]

    private static let imageModelTryCap = 2

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

    private static let multiExpenseSchema: [String: Any] = [
        "type": "OBJECT",
        "properties": [
            "expenses": [
                "type": "ARRAY",
                "description": "Array of individual expenses extracted from the transcript",
                "items": expenseSchema
            ]
        ],
        "required": ["expenses"]
    ]

    private static let receiptSchema: [String: Any] = [
        "type": "OBJECT",
        "properties": [
            "amount": ["type": "NUMBER", "description": "Grand total amount paid"],
            "merchant": ["type": "STRING", "description": "Business or store name. For POS receipts: the shop name BELOW the bank logo, NOT the bank name itself."],
            "date": ["type": "STRING", "description": "Date in YYYY-MM-DD format", "nullable": true],
            "time": ["type": "STRING", "description": "Time in HH:MM (24h) format from the receipt", "nullable": true],
            "category": ["type": "STRING", "description": "Expense category from the provided list"],
            "payment_mode": ["type": "STRING", "description": "Payment method: Cash, Card, UPI, etc. On POS receipts include CARD TYPE (Visa/Master/RuPay) and APP label (e.g. 'Visa Credit').", "nullable": true],
            "card_last4": ["type": "STRING", "description": "Last 4 digits of the card number (e.g. '9068' from ************9068). Look for masked card numbers, CARD NO fields. Only the 4 digits.", "nullable": true],
            "discount": ["type": "NUMBER", "description": "Total discount amount (positive number)", "nullable": true],
            "tax": ["type": "NUMBER", "description": "Total tax amount (GST/CGST/SGST/VAT/service charge combined)", "nullable": true],
            "items": [
                "type": "ARRAY",
                "description": "Every individual purchased item from the receipt",
                "items": [
                    "type": "OBJECT",
                    "properties": [
                        "name": ["type": "STRING", "description": "Item name as printed on receipt"],
                        "price": ["type": "NUMBER", "description": "Line total price in rupees"],
                        "quantity": ["type": "INTEGER", "description": "Quantity purchased, default 1"]
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
        request.timeoutInterval = 60

        if config.endpoint.contains("openai.azure.com") {
            request.setValue(config.apiKey, forHTTPHeaderField: "api-key")
        } else {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = jsonData
        let requestStart = Date()

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                await MainActor.run { lastParseError = "No response from server. Check your internet connection." }
                return nil
            }
            let elapsedMs = Int(Date().timeIntervalSince(requestStart) * 1000)
            aiLog.info("[ImageChat/OpenAI] status=\(httpResponse.statusCode), elapsed=\(elapsedMs)ms, body=\(jsonData.count / 1024)KB")
            guard httpResponse.statusCode == 200 else {
                let errorBody = String(data: data, encoding: .utf8) ?? ""
                aiLog.error("[ImageChat] HTTP \(httpResponse.statusCode): \(errorBody.prefix(300))")
                if httpResponse.statusCode == 429 {
                    await MainActor.run { lastParseError = "AI service is busy. Please wait a moment and try again." }
                } else if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    await MainActor.run { lastParseError = "API key is invalid or expired. Check your key in Settings." }
                } else {
                    await MainActor.run { lastParseError = "Server error (\(httpResponse.statusCode)). Try again in a moment." }
                }
                return nil
            }
            return parseOpenAIResponse(data)
        } catch let error as URLError where error.code == .timedOut {
            aiLog.error("[ImageChat] Request timed out")
            await MainActor.run { lastParseError = "Request timed out. Try a simpler photo or check your connection." }
            return nil
        } catch {
            aiLog.error("[ImageChat] Network error: \(error.localizedDescription)")
            await MainActor.run { lastParseError = "Network error. Check your internet connection and try again." }
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

        return await executeWithModelFallback(config: config, body: body, label: "Text")
    }

    private static func callGeminiNativeImage(
        config: CloudAIConfig,
        systemPrompt: String,
        imageBase64: String,
        mimeType: String,
        schema: [String: Any]
    ) async -> [String: Any]? {
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

        return await executeWithModelFallback(config: config, body: body, label: "Image")
    }

    private static let imageUserMessage = """
    Read this receipt image carefully. Extract ALL fields: the grand total \
    (amount), the ACTUAL merchant/restaurant name (NOT the delivery app), \
    every individual line item with its price, the category, and the date. \
    Do not skip any items or leave any field empty.
    """

    // MARK: - Model Fallback Execution

    private static func executeWithModelFallback(
        config: CloudAIConfig,
        body: [String: Any],
        label: String
    ) async -> [String: Any]? {
        let primaryModel = sanitizedGeminiModel(config.model)
        let speedFirst = label == "Image"

        var modelsToTry: [String]
        if speedFirst {
            var ordered = geminiImageSpeedModels
            if !ordered.contains(primaryModel) {
                ordered.append(primaryModel)
            }
            modelsToTry = Array(ordered.prefix(imageModelTryCap))
        } else {
            var ordered = [primaryModel]
            for model in geminiFallbackModels where model != primaryModel {
                ordered.append(model)
            }
            modelsToTry = ordered
        }

        var lastErrorMessage = "Couldn't read the receipt. Try a clearer photo or enter details manually."
        aiLog.info("[\(label)] model order: \(modelsToTry.joined(separator: ", "))")
        for (index, model) in modelsToTry.enumerated() {
            let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(config.apiKey)"
            guard let url = URL(string: urlString) else { continue }

            let tag = "\(label)/\(model)"
            switch await executeGeminiRequest(url: url, body: body, label: tag) {
            case .success(let json):
                if index > 0 {
                    aiLog.info("[\(label)] Succeeded with fallback model \(model)")
                }
                return json
            case .rateLimited:
                aiLog.warning("[\(label)] \(model) rate-limited, trying next model")
                lastErrorMessage = "AI service is busy. Please wait a moment and try again."
                continue
            case .failed(let msg):
                await MainActor.run { lastParseError = msg }
                return nil
            }
        }
        aiLog.error("[\(label)] All \(modelsToTry.count) models rate-limited")
        await MainActor.run { lastParseError = lastErrorMessage }
        return nil
    }

    private static func executeGeminiRequest(
        url: URL,
        body: [String: Any],
        label: String,
        retryCount: Int = 0
    ) async -> GeminiOutcome {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            aiLog.error("[\(label)] Failed to serialize request body")
            return .failed("Something went wrong preparing the request. Try again.")
        }

        aiLog.info("[\(label)] Sending request, bodySize=\(jsonData.count / 1024)KB\(retryCount > 0 ? " (retry \(retryCount))" : "")")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = jsonData
        let requestStart = Date()

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                aiLog.error("[\(label)] Response is not HTTP")
                return .failed("No response from server. Check your internet connection.")
            }

            let elapsedMs = Int(Date().timeIntervalSince(requestStart) * 1000)
            aiLog.info("[\(label)] HTTP \(httpResponse.statusCode), responseSize=\(data.count), elapsed=\(elapsedMs)ms")

            if httpResponse.statusCode == 429 || httpResponse.statusCode == 503 {
                let errorBody = String(data: data, encoding: .utf8) ?? ""
                aiLog.warning("[\(label)] Rate limited (\(httpResponse.statusCode)): \(errorBody.prefix(200))")
                return .rateLimited
            }

            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                return .failed("API key is invalid or expired. Check your key in Settings.")
            }

            guard httpResponse.statusCode == 200 else {
                let errorBody = String(data: data, encoding: .utf8) ?? "(no body)"
                aiLog.error("[\(label)] HTTP \(httpResponse.statusCode): \(errorBody.prefix(500))")
                return .failed("Server error (\(httpResponse.statusCode)). Try again in a moment.")
            }

            if let parsed = parseGeminiResponse(data, label: label) {
                return .success(parsed)
            }
            return .failed("Couldn't understand the AI response. Try a clearer photo.")
        } catch let error as URLError where error.code == .timedOut && retryCount < 1 {
            aiLog.warning("[\(label)] Timed out, retrying once")
            return await executeGeminiRequest(url: url, body: body, label: label, retryCount: retryCount + 1)
        } catch let error as URLError where error.code == .networkConnectionLost && retryCount < 1 {
            aiLog.warning("[\(label)] Connection lost, retrying once")
            return await executeGeminiRequest(url: url, body: body, label: label, retryCount: retryCount + 1)
        } catch let error as URLError {
            aiLog.error("[\(label)] Network error: \(error.localizedDescription)")
            return .failed("Network error. Check your internet connection and try again.")
        } catch {
            aiLog.error("[\(label)] Unexpected error: \(error.localizedDescription)")
            return .failed("Something went wrong. Please try again.")
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

    // MARK: - Shared Image Preparation

    /// Single, source-aware JPEG optimisation before the Gemini API call.
    /// Shared by AddExpenseView (main app) and ShareSession (share extension)
    /// so both get identical quality tuning.
    ///
    /// - Screenshots (UPI, order confirmations, app grabs): 1024px, JPEG 0.88.
    ///   Detected by matching exact iOS rendered-pixel screen dimensions.
    ///   Digital text is already crisp — higher quality preserves it.
    /// - Narrow-portrait camera photos (thermal roll receipts): 1280px, JPEG
    ///   0.80, converted to grayscale (DeviceGray CGContext, no CIContext GPU
    ///   cost). Saves ~50% payload; thermal receipts carry no colour signal.
    /// - Other camera photos: 1280px, JPEG 0.80, colour retained.
    static func prepareImageForGemini(_ image: UIImage) -> Data? {
        let size        = image.size
        let longEdge    = max(size.width, size.height)
        let shortEdge   = min(size.width, size.height)
        let aspectRatio: CGFloat = longEdge > 0 ? shortEdge / longEdge : 1.0

        // Exact rendered-pixel widths/heights of current iOS devices.
        // Camera output is never exactly these values; screenshots always are.
        let screenshotEdges: Set<CGFloat> = [
            1290, 2796,   // iPhone 15 Pro Max / 14 Pro Max / 15 Plus
            1179, 2556,   // iPhone 15 Pro / 14 Pro / 15
            1170, 2532,   // iPhone 14 / 13 / 13 Pro / 12 Pro
            1284, 2778,   // iPhone 12 Pro Max / 13 Pro Max
            1080, 2340,   // iPhone SE 3 / 12 mini / 13 mini
             828, 1792,   // iPhone 11 / XR
        ]
        let isScreenshot = screenshotEdges.contains(size.width)
                        || screenshotEdges.contains(size.height)

        let maxDimension: CGFloat = isScreenshot ? 1024 : 1280
        let quality: CGFloat      = isScreenshot ? 0.88  : 0.80

        let prepared: UIImage = autoreleasepool {
            let resized = Self.resizeForGemini(image, maxDimension: maxDimension)
            // Grayscale only for narrow-portrait camera photos (thermal paper).
            // Never grayscale screenshots — app colour chrome (GPay, Swiggy, etc.)
            // gives Gemini useful document-type signals.
            if !isScreenshot && aspectRatio < 0.55 {
                return Self.grayscaleForGemini(resized) ?? resized
            }
            return resized
        }
        return prepared.jpegData(compressionQuality: quality)
    }

    private static func resizeForGemini(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size    = image.size
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return image }
        let scale   = maxDimension / longest
        let newSize = CGSize(width:  (size.width  * scale).rounded(),
                             height: (size.height * scale).rounded())
        let format  = UIGraphicsImageRendererFormat()
        format.scale  = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    /// Grayscale via CGContext DeviceGray — avoids CIContext GPU allocation,
    /// keeping memory pressure low inside the share extension.
    private static func grayscaleForGemini(_ image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let ctx = CGContext(
            data: nil,
            width:  cgImage.width,
            height: cgImage.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )
        ctx?.draw(cgImage, in: CGRect(x: 0, y: 0,
                                      width:  cgImage.width,
                                      height: cgImage.height))
        guard let grayCG = ctx?.makeImage() else { return nil }
        return UIImage(cgImage: grayCG, scale: image.scale,
                       orientation: image.imageOrientation)
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
