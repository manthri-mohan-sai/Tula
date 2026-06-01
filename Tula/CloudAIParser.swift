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
import UIKit

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
            You are a JSON-only expense parser. You MUST respond with ONLY a single valid JSON object. \
            No explanations, no markdown, no code fences, no extra text before or after the JSON.

            Schema: {"amount":number,"merchant":string|null,"item":string|null,"category":string|null,"account":string|null}

            You parse expense entries from voice transcripts spoken by Indian users. \
            The transcript may contain speech-recognition errors.

            AMOUNT RULES for Indian English:
            - "two fifty" = 250, "three fifty" = 350, "four eighty" = 480
            - "one twenty" = 120, "five fifteen" = 515
            - Split digits: "1 20" = 120, "3 50" = 350

            Categories (pick ONE exactly as written):
            \(categoryList)

            Accounts (pick from this list or null):
            \(accountList)

            Rules:
            - amount: integer in rupees. If unclear, return 0.
            - merchant: the place/vendor/app. Never a dish or product.
            - item: what was bought (dishes, products, services). null if not mentioned.
            - category: must match one from the list exactly.
            - account: must match one from the list exactly, or null.

            RESPOND WITH ONLY THE JSON OBJECT. NOTHING ELSE.
            """
        } else {
            systemPrompt = """
            You are a JSON-only expense parser. You MUST respond with ONLY a single valid JSON object. \
            No explanations, no markdown, no code fences, no extra text before or after the JSON.

            Schema: {"amount":number,"merchant":string|null,"item":string|null,"category":string|null,"account":string|null}

            You parse expense log entries from Indian users. Inputs may mix Hindi/English.

            Categories (pick ONE exactly as written):
            \(categoryList)

            Accounts (pick from this list or null):
            \(accountList)

            Rules:
            - amount: integer in rupees. If unclear, return 0.
            - merchant: where the money went (place, vendor, app name). Keep short.
            - item: what was bought, if mentioned separately from merchant. null otherwise.
            - category: must match one from the list exactly.
            - account: must match one from the list exactly, or null.

            RESPOND WITH ONLY THE JSON OBJECT. NOTHING ELSE.
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
        You are a JSON-only receipt parser. You MUST respond with ONLY a single valid JSON object. \
        No explanations, no markdown, no code fences, no extra text before or after the JSON.

        Schema: {"amount":number,"merchant":string|null,"date":"YYYY-MM-DD"|null,"category":string|null,"items":[{"name":string,"price":number}]}

        You extract structured expense data from receipt OCR text.

        Categories (pick ONE exactly as written):
        \(categoryList)

        Rules:
        - amount: grand total / final amount paid (the LARGEST total on the receipt). Integer in rupees.
        - merchant: business name, usually at the top of the receipt.
        - date: transaction date in YYYY-MM-DD format, null if not found.
        - category: must match one from the list exactly.
        - items: line items purchased (exclude tax, subtotals, discounts, total lines).

        RESPOND WITH ONLY THE JSON OBJECT. NOTHING ELSE.
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

    // MARK: - Image-Based Receipt Parse

    /// Parse a receipt by sending the image directly to the cloud AI model.
    /// The model performs OCR + structured extraction in a single pass.
    /// Typically more accurate than on-device OCR → text → AI pipeline.
    static func parseReceiptImage(_ imageData: Data,
                                   categories: [CategoryEntry],
                                   config: CloudAIConfig? = nil) async -> ReceiptSmartParseResult? {
        let cfg = config ?? CloudAIConfig.load()
        guard !cfg.apiKey.isEmpty else { return nil }

        // Resize image to max 1024px on longest side to keep payload small.
        // Receipts are mostly text — 1024px is plenty for readability.
        let resizedData = Self.resizeImageData(imageData, maxDimension: 1024, quality: 0.7)
        guard let finalImageData = resizedData ?? imageData as Data? else { return nil }

        print("🖼️ [CloudAI] Original: \(imageData.count / 1024)KB → Resized: \(finalImageData.count / 1024)KB")

        let categoryList = categories.map { "- \($0.name)" }.joined(separator: "\n")

        let systemPrompt = """
        You are a JSON-only receipt parser. You MUST respond with ONLY a single valid JSON object. \
        No explanations, no markdown, no code fences, no extra text before or after the JSON.

        Schema: {"amount":number,"merchant":string|null,"date":"YYYY-MM-DD"|null,"category":string|null,"items":[{"name":string,"price":number}]}

        You extract structured expense data from receipt images.

        Categories (pick ONE exactly as written):
        \(categoryList)

        Rules:
        - amount: grand total / final amount paid (the LARGEST total on the receipt). Integer in rupees.
        - merchant: business name, usually at the top of the receipt.
        - date: transaction date in YYYY-MM-DD format, null if not found.
        - category: must match one from the list exactly.
        - items: line items purchased (exclude tax, subtotals, discounts, total lines).

        RESPOND WITH ONLY THE JSON OBJECT. NOTHING ELSE.
        """

        let base64Image = finalImageData.base64EncodedString()
        let mimeType = finalImageData.detectMimeType()

        guard let json = await callImageChatCompletions(
            config: cfg,
            systemPrompt: systemPrompt,
            imageBase64: base64Image,
            mimeType: mimeType
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

        // Log the input text being sent
        print("☁️ [CloudAI] Input text:\n\(userMessage)")

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
              let httpResponse = response as? HTTPURLResponse else {
            print("☁️ [CloudAI] Request failed — no response")
            return nil
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "(no body)"
            print("☁️ [CloudAI] HTTP \(httpResponse.statusCode): \(errorBody)")
            return nil
        }

        guard let responseJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = responseJSON["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            print("☁️ [CloudAI] Failed to parse response structure")
            return nil
        }

        // Log raw model response
        print("☁️ [CloudAI] Raw response:\n\(content)")

        // Parse the content string as JSON
        let cleaned = content
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let contentData = cleaned.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any] else {
            print("☁️ [CloudAI] Failed to parse JSON from content: \(cleaned)")
            return nil
        }

        print("☁️ [CloudAI] Parsed JSON: \(parsed)")

        return parsed
    }

    /// Call the chat completions endpoint with an image payload.
    /// Uses the multimodal content format supported by OpenAI and Gemini.
    private static func callImageChatCompletions(
        config: CloudAIConfig,
        systemPrompt: String,
        imageBase64: String,
        mimeType: String
    ) async -> [String: Any]? {
        guard let url = URL(string: config.endpoint) else {
            print("🖼️ [CloudAI] Invalid endpoint URL: \(config.endpoint)")
            return nil
        }

        print("🖼️ [CloudAI] Sending image (\(mimeType), \(imageBase64.count / 1024)KB base64) to \(config.model)")

        let userContent: [[String: Any]] = [
            ["type": "text", "text": "Parse this receipt image."],
            ["type": "image_url", "image_url": ["url": "data:\(mimeType);base64,\(imageBase64)"]]
        ]

        let body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent]
            ],
            "temperature": 0.1,
            "max_tokens": 1000
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            print("🖼️ [CloudAI] Failed to serialize request body")
            return nil
        }

        print("🖼️ [CloudAI] Request body size: \(jsonData.count / 1024)KB")

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
            guard let httpResponse = response as? HTTPURLResponse else {
                print("🖼️ [CloudAI] Response is not HTTP")
                return nil
            }

            guard httpResponse.statusCode == 200 else {
                let errorBody = String(data: data, encoding: .utf8) ?? "(no body)"
                print("🖼️ [CloudAI] HTTP \(httpResponse.statusCode): \(errorBody)")
                return nil
            }

            guard let responseJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = responseJSON["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let message = firstChoice["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                print("🖼️ [CloudAI] Failed to parse image response structure")
                if let raw = String(data: data, encoding: .utf8) {
                    print("🖼️ [CloudAI] Raw response body: \(raw.prefix(2000))")
                }
                return nil
            }

            print("🖼️ [CloudAI] Raw image response:\n\(content)")

            let cleaned = content
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard let contentData = cleaned.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any] else {
                print("🖼️ [CloudAI] Failed to parse JSON from image response: \(cleaned)")
                return nil
            }

            print("🖼️ [CloudAI] Parsed image JSON: \(parsed)")
            return parsed

        } catch let error as URLError {
            print("🖼️ [CloudAI] URLError: \(error.code.rawValue) — \(error.localizedDescription)")
            return nil
        } catch {
            print("🖼️ [CloudAI] Error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Image Resizing

    /// Resize image data to fit within maxDimension while maintaining aspect ratio.
    /// Returns nil if resizing fails (caller should use original).
    private static func resizeImageData(_ data: Data, maxDimension: CGFloat, quality: CGFloat) -> Data? {
        guard let image = UIImage(data: data) else { return nil }

        let size = image.size
        let longestSide = max(size.width, size.height)

        // Already small enough
        if longestSide <= maxDimension {
            // Still re-compress at the target quality to reduce payload
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
    /// Detect image MIME type from file header bytes.
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
        return "image/jpeg" // default fallback
    }
}
