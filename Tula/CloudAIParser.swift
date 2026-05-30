//
//  CloudAIParser.swift
//  Tula
//
//  Cloud-based AI expense parser using an OpenAI-compatible chat
//  completions endpoint. Activated when the user selects "ChatGPT (Cloud)"
//  in Settings and configures their API key.
//
//  Supports: OpenAI, Azure OpenAI, Ollama, LM Studio, or any endpoint
//  that implements the /v1/chat/completions contract.
//

import Foundation

enum CloudAIParser {

    // MARK: - Text Parse (voice / NLP input)

    /// Parse a free-text expense input via the cloud AI endpoint.
    /// Same contract as SmartExpenseParser.parse — returns nil on failure.
    static func parse(_ input: String,
                      categories: [CategoryEntry],
                      accountNames: [String] = [],
                      isVoice: Bool = false,
                      config: CloudAIConfig? = nil) async -> SmartParseResult? {
        let cfg = config ?? CloudAIConfig.load()
        guard !cfg.apiKey.isEmpty else { return nil }

        let categoryList = categories.map { "- \($0.name)" }.joined(separator: "\n")
        let accountList = accountNames.isEmpty ? "(none)" : accountNames.joined(separator: ", ")

        let systemPrompt: String
        if isVoice {
            systemPrompt = """
            You parse expense entries from voice transcripts spoken by Indian users. \
            The transcript may contain speech-recognition errors. Extract expense data \
            and return ONLY valid JSON with these fields:
            {"amount":number,"merchant":"string or null","item":"string or null","category":"string or null","account":"string or null"}

            AMOUNT RULES for Indian English:
            - "two fifty" = 250, "three fifty" = 350, "four eighty" = 480
            - "one twenty" = 120, "five fifteen" = 515
            - Split digits: "1 20" = 120, "3 50" = 350

            Categories (pick ONE from this list):
            \(categoryList)

            Accounts (pick from this list or null):
            \(accountList)

            Rules:
            - Amount as integer in rupees. If unclear, return 0.
            - Merchant = the place/vendor/app. Never a dish or product.
            - Item = what was bought (dishes, products, services). Nil if not mentioned separately.
            - Category must match one from the list exactly.
            """
        } else {
            systemPrompt = """
            You parse expense log entries from Indian users. Inputs may mix Hindi/English. \
            Extract expense data and return ONLY valid JSON:
            {"amount":number,"merchant":"string or null","item":"string or null","category":"string or null","account":"string or null"}

            Categories (pick ONE):
            \(categoryList)

            Accounts (pick from this list or null):
            \(accountList)

            Rules:
            - Amount as integer in rupees. If unclear, return 0.
            - Merchant = where the money went (place, vendor, app name). Short.
            - Item = what was bought, if mentioned separately from merchant.
            - Category must match one from the list exactly.
            """
        }

        guard let json = await callChatCompletions(
            config: cfg,
            systemPrompt: systemPrompt,
            userMessage: input
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

    // MARK: - Receipt Parse

    /// Parse receipt OCR text via the cloud AI endpoint.
    /// Same contract as SmartExpenseParser.parseReceipt.
    static func parseReceipt(_ rawText: String,
                              categories: [CategoryEntry],
                              config: CloudAIConfig? = nil) async -> ReceiptSmartParseResult? {
        let cfg = config ?? CloudAIConfig.load()
        guard !cfg.apiKey.isEmpty else { return nil }

        let categoryList = categories.map { "- \($0.name)" }.joined(separator: "\n")

        let systemPrompt = """
        You extract structured expense data from receipt OCR text. Return ONLY valid JSON:
        {"amount":number,"merchant":"string or null","date":"YYYY-MM-DD or null","category":"string or null","items":[{"name":"string","price":number}]}

        Categories (pick ONE):
        \(categoryList)

        Rules:
        - amount = grand total / final amount paid (the LARGEST total on the receipt)
        - merchant = business name, usually at the top of the receipt
        - date = transaction date in YYYY-MM-DD format, null if not found
        - category = best match from the list
        - items = line items purchased (exclude tax, subtotals, discounts, total lines)
        """

        guard let json = await callChatCompletions(
            config: cfg,
            systemPrompt: systemPrompt,
            userMessage: rawText
        ) else { return nil }

        let amount = json["amount"] as? Double ?? 0
        let merchant = json["merchant"] as? String
        let date = json["date"] as? String
        let category = json["category"] as? String

        var items: [ReceiptLineItem] = []
        if let rawItems = json["items"] as? [[String: Any]] {
            items = rawItems.compactMap { item in
                guard let name = item["name"] as? String,
                      let price = item["price"] as? Double else { return nil }
                return ReceiptLineItem(name: name, price: price)
            }
        }

        return ReceiptSmartParseResult(
            amount: amount,
            merchant: merchant,
            date: date,
            category: category,
            items: items
        )
    }

    // MARK: - HTTP

    /// Call the OpenAI-compatible chat completions endpoint.
    /// Returns the parsed JSON object from the assistant's response, or nil.
    private static func callChatCompletions(
        config: CloudAIConfig,
        systemPrompt: String,
        userMessage: String
    ) async -> [String: Any]? {
        guard let url = URL(string: config.endpoint) else { return nil }

        let body: [String: Any] = [
            "model": config.model,
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

        // Support both OpenAI-style (Bearer token) and Azure-style (api-key header).
        // If the endpoint contains "openai.azure.com", use api-key; otherwise Bearer.
        if config.endpoint.contains("openai.azure.com") {
            request.setValue(config.apiKey, forHTTPHeaderField: "api-key")
        } else {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = jsonData

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            return nil
        }

        guard let responseJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = responseJSON["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return nil
        }

        // Parse the content string as JSON
        let cleaned = content
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let contentData = cleaned.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any] else {
            return nil
        }

        return parsed
    }
}
