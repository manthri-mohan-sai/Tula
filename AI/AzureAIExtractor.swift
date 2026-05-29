//
//  AzureAIExtractor.swift
//  Tula
//
//  Azure OpenAI (AI Foundry) extractor for receipt expense parsing.
//  Uses GPT-4o-mini via the Azure OpenAI chat completions API.
// BCBJp3zt
// 0twA9NZ2
// JH4OEBaANet
//  Fallback chain: Apple Foundation Models → Azure AI → Vision regex.
//

import Foundation
import Security

/// Extracts expense data from receipt OCR text using Azure OpenAI.
final class AzureAIExtractor {

    static let shared = AzureAIExtractor()

    // MARK: - Configuration

    private static let defaultEndpoint = "https://ai-isow-np.openai.azure.com"
    private static let defaultDeployment = "gpt-4o-mini"
    private static let apiVersion = "2025-01-01-preview"
    private static let timeoutSeconds: TimeInterval = 30

    // Keychain keys
    private static let keychainService = "com.tula.azureai"
    private static let keychainKeyAccount = "api-key"

    // Hardcoded API key (dev/testing) — replace with your key
    private static let hardcodedAPIKey: String? = "YOUR_API_KEY_HERE"

    private init() {}

    // MARK: - Availability

    /// Whether an API key is configured.
    var isAvailable: Bool {
        apiKey != nil
    }

    /// Status text for display in Settings.
    var statusText: String {
        if apiKey != nil {
            return "Azure AI (cloud)"
        }
        return "Not configured"
    }

    // MARK: - API Key Management (Keychain)

    /// Retrieve the stored API key (hardcoded fallback → Keychain).
    var apiKey: String? {
        // Use hardcoded key if set
        if let key = Self.hardcodedAPIKey, key != "YOUR_API_KEY_HERE", !key.isEmpty {
            return key
        }
        // Otherwise check Keychain
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainKeyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Save API key to Keychain.
    // gaFoIHn22BTCWE8Pk
// XRBqNFlZJQQJ99CEAC5
// RqLJXJ3w3AA
// ABACOGjTG9
    func saveAPIKey(_ key: String) {
        deleteAPIKey()
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainKeyAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    /// Delete API key from Keychain.
    func deleteAPIKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainKeyAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Receipt Extraction

    /// Extract expense data from receipt OCR text via Azure OpenAI.
    func extractFromReceipt(rawText: String, categoryNames: [String]) async -> ReceiptSmartParseResult? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let key = apiKey else { return nil }

        let categoryList = categoryNames.joined(separator: ", ")
        let systemPrompt = """
        Extract expense data from receipt OCR text. Return ONLY valid JSON with these fields:
        {"amount":number,"merchant":"string","date":"YYYY-MM-DD","category":"string"}
        Categories: [\(categoryList)]
        Use the grand total line (final amount paid). Ignore change/tendered/cash lines.
        """

        guard let response = await callAzureOpenAI(
            systemPrompt: systemPrompt,
            userMessage: trimmed,
            apiKey: key
        ) else { return nil }

        return parseReceiptResponse(response)
    }

    /// Extract basic expense info from free text.
    func extract(from text: String, categoryNames: [String]) async -> ExpenseExtraction? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let key = apiKey else { return nil }

        let categoryList = categoryNames.joined(separator: ", ")
        let systemPrompt = """
        Extract expense info from text. Return ONLY valid JSON:
        {"amount":number,"merchant":"string","category":"string","date":"YYYY-MM-DD","note":"string"}
        Categories: [\(categoryList)]
        Use null for fields not found.
        """

        guard let response = await callAzureOpenAI(
            systemPrompt: systemPrompt,
            userMessage: trimmed,
            apiKey: key
        ) else { return nil }

        guard let data = response.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ExpenseExtraction.self, from: data)
    }

    // MARK: - Azure OpenAI API

    private func callAzureOpenAI(systemPrompt: String, userMessage: String, apiKey: String) async -> String? {
        let endpoint = Self.defaultEndpoint
        let deployment = Self.defaultDeployment
        let urlString = "\(endpoint)/openai/deployments/\(deployment)/chat/completions?api-version=\(Self.apiVersion)"

        guard let url = URL(string: urlString) else {
            print("[AzureAI] Invalid URL")
            return nil
        }

        let body: [String: Any] = [
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage]
            ],
            "temperature": 0.1,
            "max_tokens": 150
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            print("[AzureAI] JSON serialization failed")
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "api-key")
        request.timeoutInterval = Self.timeoutSeconds
        request.httpBody = jsonData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                print("[AzureAI] Non-HTTP response")
                return nil
            }

            guard httpResponse.statusCode == 200 else {
                let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
                print("[AzureAI] HTTP \(httpResponse.statusCode): \(errorBody.prefix(200))")
                return nil
            }

            // Parse the Azure OpenAI response
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let message = firstChoice["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                print("[AzureAI] Failed to parse response")
                return nil
            }

            print("[AzureAI] Response: \(content.prefix(200))")
            return extractJSON(from: content)

        } catch {
            print("[AzureAI] Request error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Response Parsing

    private func parseReceiptResponse(_ json: String) -> ReceiptSmartParseResult? {
        guard let data = json.data(using: .utf8) else { return nil }

        struct AzureReceiptResult: Decodable {
            let amount: Double?
            let merchant: String?
            let date: String?
            let category: String?
        }

        guard let decoded = try? JSONDecoder().decode(AzureReceiptResult.self, from: data),
              let amount = decoded.amount, amount > 0 else { return nil }

        return ReceiptSmartParseResult(
            amount: amount,
            merchant: decoded.merchant,
            date: decoded.date,
            category: decoded.category,
            items: []
        )
    }

    /// Extract JSON from model response (may have markdown fences or preamble).
    private func extractJSON(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("{"), let end = findClosingBrace(in: trimmed) {
            return String(trimmed[...end])
        }

        if let range = trimmed.range(of: "```json") ?? trimmed.range(of: "```") {
            let afterFence = trimmed[range.upperBound...]
            if let endFence = afterFence.range(of: "```") {
                return afterFence[..<endFence.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if let start = trimmed.firstIndex(of: "{"),
           let end = trimmed.lastIndex(of: "}") {
            return String(trimmed[start...end])
        }

        return nil
    }

    private func findClosingBrace(in text: String) -> String.Index? {
        var depth = 0
        for (index, char) in text.enumerated() {
            if char == "{" { depth += 1 }
            else if char == "}" {
                depth -= 1
                if depth == 0 { return text.index(text.startIndex, offsetBy: index) }
            }
        }
        return nil
    }
}
