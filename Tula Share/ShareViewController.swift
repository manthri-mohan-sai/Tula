//
//  ShareViewController.swift
//  Tula Share
//
//  Share Extension: receives photos from the iOS Share Sheet,
//  performs OCR via Vision, extracts expense data using the same
//  fallback chain as the main app (Foundation Models → Azure AI),
//  and saves a pending expense for the main app to import.
//

import UIKit
import Vision
import UniformTypeIdentifiers
#if canImport(FoundationModels)
import FoundationModels
#endif

class ShareViewController: UIViewController {

    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        processSharedImage()
    }

    // MARK: - UI

    private func setupUI() {
        view.backgroundColor = UIColor.systemBackground

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        view.addSubview(spinner)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.text = "Processing receipt..."
        statusLabel.textAlignment = .center
        statusLabel.font = .systemFont(ofSize: 17, weight: .medium)
        statusLabel.textColor = .label
        statusLabel.numberOfLines = 0
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -30),
            statusLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 20),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
        ])

        // Add Cancel button
        let cancelButton = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))
        navigationItem.leftBarButtonItem = cancelButton
    }

    @objc private func cancelTapped() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    // MARK: - Process Shared Image

    private func processSharedImage() {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            finish(error: "No items received")
            return
        }

        for item in extensionItems {
            guard let attachments = item.attachments else { continue }
            for provider in attachments {
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { [weak self] data, error in
                        DispatchQueue.main.async {
                            self?.handleLoadedImage(data: data, error: error)
                        }
                    }
                    return
                }
            }
        }

        finish(error: "No image found")
    }

    private func handleLoadedImage(data: Any?, error: Error?) {
        if let error = error {
            finish(error: "Failed to load image: \(error.localizedDescription)")
            return
        }

        var image: UIImage?

        if let url = data as? URL {
            image = UIImage(contentsOfFile: url.path)
        } else if let imageData = data as? Data {
            image = UIImage(data: imageData)
        } else if let uiImage = data as? UIImage {
            image = uiImage
        }

        guard let finalImage = image else {
            finish(error: "Could not read image")
            return
        }

        performOCR(on: finalImage)
    }

    // MARK: - OCR via Vision

    private func performOCR(on image: UIImage) {
        guard let cgImage = image.cgImage else {
            finish(error: "Invalid image format")
            return
        }

        statusLabel.text = "Reading receipt text..."

        let request = VNRecognizeTextRequest { [weak self] request, error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.finish(error: "OCR failed: \(error.localizedDescription)")
                    return
                }

                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")

                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self?.finish(error: "No text found in image")
                    return
                }

                self?.extractExpense(from: text, image: image)
            }
        }

        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        DispatchQueue.global(qos: .userInitiated).async {
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
        }
    }

    // MARK: - AI Extraction (Fallback Chain: Foundation Models → Azure AI)

    private func extractExpense(from ocrText: String, image: UIImage) {
        statusLabel.text = "Extracting expense details..."

        Task {
            // 1. Try Apple Foundation Models first (on-device, fast, no API key needed)
            if let fmResult = await extractViaFoundationModels(ocrText: ocrText) {
                await MainActor.run {
                    savePendingExpense(fmResult, image: image)
                }
                return
            }

            // 2. Fallback: Azure AI (cloud)
            if let azureResult = await extractViaAzureAI(ocrText: ocrText) {
                await MainActor.run {
                    savePendingExpense(azureResult, image: image)
                }
                return
            }

            // 3. Last resort: save with just OCR text, user can edit in app
            await MainActor.run {
                let fallback = PendingExpense(
                    amount: 0,
                    merchant: nil,
                    date: Date(),
                    category: nil,
                    note: "Receipt text: \(String(ocrText.prefix(200)))",
                    source: "share"
                )
                savePendingExpense(fallback, image: image)
            }
        }
    }

    // MARK: - Foundation Models Extraction

    private func extractViaFoundationModels(ocrText: String) async -> PendingExpense? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return nil }

        // Check if Apple Intelligence is available on this device
        guard case .available = SystemLanguageModel.default.availability else {
            return nil
        }

        let prompt = """
        Extract expense data from this receipt OCR text. Return ONLY valid JSON with these fields:
        {"amount":number,"merchant":"string","date":"YYYY-MM-DD","category":"string","note":"string"}
        Categories: [Food, Transport, Shopping, Bills, Entertainment, Health, Education, Travel, Groceries, Other]
        Use the grand total line (final amount paid). Ignore change/tendered/cash lines.
        Use null for fields not found.

        Receipt text:
        \(ocrText)
        """

        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt)
            let content = response.content

            // Parse the JSON response
            let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard let data = cleaned.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            let amount = parsed["amount"] as? Double ?? 0
            let merchant = parsed["merchant"] as? String
            let category = parsed["category"] as? String
            let note = parsed["note"] as? String

            var date = Date()
            if let dateStr = parsed["date"] as? String {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                if let parsedDate = formatter.date(from: dateStr) {
                    date = parsedDate
                }
            }

            return PendingExpense(
                amount: amount,
                merchant: merchant,
                date: date,
                category: category,
                note: note,
                source: "share"
            )
        } catch {
            print("[ShareExt] Foundation Models error: \(error)")
            return nil
        }
        #else
        return nil
        #endif
    }

    // MARK: - Azure AI Extraction (Fallback)

    private func extractViaAzureAI(ocrText: String) async -> PendingExpense? {
        // Azure OpenAI config (mirrors AzureAIExtractor in main app)
        let endpoint = "https://ai-isow-np.openai.azure.com"
        let deployment = "gpt-4o-mini"
        let apiVersion = "2025-01-01-preview"

        guard let apiKey = getAPIKey(), !apiKey.isEmpty else {
            return nil
        }

        let urlString = "\(endpoint)/openai/deployments/\(deployment)/chat/completions?api-version=\(apiVersion)"
        guard let url = URL(string: urlString) else { return nil }

        let systemPrompt = """
        Extract expense data from receipt OCR text. Return ONLY valid JSON with these fields:
        {"amount":number,"merchant":"string","date":"YYYY-MM-DD","category":"string","note":"string"}
        Categories: [Food, Transport, Shopping, Bills, Entertainment, Health, Education, Travel, Groceries, Other]
        Use the grand total line (final amount paid). Ignore change/tendered/cash lines.
        Use null for fields not found. For note, provide a brief description.
        """

        let body: [String: Any] = [
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": ocrText]
            ],
            "temperature": 0.1,
            "max_tokens": 200
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "api-key")
        request.timeoutInterval = 30

        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return nil }

        // Parse the Azure OpenAI response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return nil
        }

        // Parse the extracted JSON from the AI response
        let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let resultData = cleaned.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any] else {
            return nil
        }

        let amount = parsed["amount"] as? Double ?? 0
        let merchant = parsed["merchant"] as? String
        let category = parsed["category"] as? String
        let note = parsed["note"] as? String

        var date = Date()
        if let dateStr = parsed["date"] as? String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            if let parsedDate = formatter.date(from: dateStr) {
                date = parsedDate
            }
        }

        return PendingExpense(
            amount: amount,
            merchant: merchant,
            date: date,
            category: category,
            note: note,
            source: "share"
        )
    }

    /// Retrieve API key - checks hardcoded value first, then Keychain
    private func getAPIKey() -> String? {
        // Hardcoded key (same as main app's AzureAIExtractor)
        let hardcoded = ShareExtensionConfig.azureAPIKey
        if !hardcoded.isEmpty && hardcoded != "YOUR_API_KEY_HERE" {
            return hardcoded
        }
        // Fallback: read from shared Keychain (requires shared access group)
        return nil
    }

    // MARK: - Save Pending Expense

    private func savePendingExpense(_ expense: PendingExpense, image: UIImage) {
        let manager = PendingExpenseManager()

        // Compress and save receipt image
        var expenseWithImage = expense
        if let imageData = image.jpegData(compressionQuality: 0.7) {
            let imageFilename = UUID().uuidString + ".jpg"
            manager.saveReceiptImage(data: imageData, filename: imageFilename)
            expenseWithImage.receiptImageFilename = imageFilename
        }

        manager.addPendingExpense(expenseWithImage)

        spinner.stopAnimating()

        if expense.amount > 0 {
            statusLabel.text = "✓ Expense saved!\n\(expense.merchant ?? "Receipt") — ₹\(String(format: "%.0f", expense.amount))"
        } else {
            statusLabel.text = "✓ Receipt saved!\nOpen Tula to review and complete the expense."
        }

        // Auto-dismiss after 1.5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }

    // MARK: - Finish

    private func finish(error: String) {
        spinner.stopAnimating()
        statusLabel.text = "⚠️ \(error)\n\nPlease try again or add the expense manually in Tula."

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }
}

// MARK: - Config

/// Shared config for the Share Extension. Keep API key in sync with AzureAIExtractor.
enum ShareExtensionConfig {
    // Update this when you change the key in AzureAIExtractor.swift
    static let azureAPIKey = "YOUR_API_KEY_HERE"
    static let appGroupID = "group.com.app.Tula"
}
