//
//  ExpenseAIService.swift
//  Tula
//
//  Created by Lokesh Polina on 27/05/26.
//
import Foundation

/// Central orchestrator for AI-powered expense extraction.
///
/// **Fallback chain**: Foundation Models (iPhone 15 Pro+) → Azure AI Foundry
/// (cloud, requires API key) → nil (caller uses Vision regex).
///
/// Each layer is independent — a failure in one doesn't skip the next.
final class ExpenseAIService {

    static let shared = ExpenseAIService()

    private let appleExtractor = AppleFoundationExtractor()
    private let azureExtractor = AzureAIExtractor.shared

    // MARK: - Free-text extraction

    func extract(from text: String) async -> ExpenseExtraction? {

        if appleExtractor.isAvailable {
            do {
                return try await appleExtractor.extract(from: text)
            } catch {
                print("[ExpenseAIService] FM error: \(error)")
            }
        }

        // Fallback: Azure AI Foundry
        if azureExtractor.isAvailable {
            let result = await azureExtractor.extract(from: text, categoryNames: [])
            if result != nil { return result }
        }

        return nil
    }

    // MARK: - Receipt extraction

    /// Extract expense data from receipt OCR text.
    /// Priority: Foundation Models → Azure AI → nil (regex handles it).
    func extractFromReceipt(rawText: String, categoryNames: [String]) async -> ReceiptSmartParseResult? {

        // Try Apple Foundation Models first (fastest, best quality on 15 Pro+)
        if #available(iOS 26.0, *), SmartExpenseParser.isAvailable {
            if let result = await SmartExpenseParser.parseReceipt(rawText, categoryNames: categoryNames) {
                return result
            }
        }

        // Fallback: Azure AI Foundry (cloud)
        if azureExtractor.isAvailable {
            if let result = await azureExtractor.extractFromReceipt(rawText: rawText, categoryNames: categoryNames) {
                return result
            }
        }

        return nil
    }

    // MARK: - Availability

    /// Whether any AI extraction backend is available (FM or Azure).
    var isSmartExtractionAvailable: Bool {
        if #available(iOS 26.0, *), SmartExpenseParser.isAvailable {
            return true
        }
        return azureExtractor.isAvailable
    }

    /// Human-readable status of the extraction backends.
    var extractionBackendStatus: String {
        if #available(iOS 26.0, *), SmartExpenseParser.isAvailable {
            return "Apple Intelligence (on-device)"
        }
        if azureExtractor.isAvailable {
            return "Azure AI (cloud)"
        }
        return "Rule-based only"
    }
}
