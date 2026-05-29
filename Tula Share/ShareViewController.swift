//
//  ShareViewController.swift
//  Tula Share
//
//  Share Extension: receives a photo from the iOS Share Sheet,
//  runs OCR + AI extraction, auto-saves the expense to the
//  App Group, and dismisses.
//

import UIKit
import Vision
import UniformTypeIdentifiers
#if canImport(FoundationModels)
import FoundationModels
#endif

class ShareViewController: UIViewController {

    // UI
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let checkmark = UIImageView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupUI()
        loadSharedImage()
    }

    // MARK: - UI

    private func setupUI() {
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        view.addSubview(spinner)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 15, weight: .medium)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        statusLabel.text = "Reading receipt..."
        view.addSubview(statusLabel)

        checkmark.translatesAutoresizingMaskIntoConstraints = false
        checkmark.image = UIImage(systemName: "checkmark.circle.fill")
        checkmark.tintColor = .systemGreen
        checkmark.contentMode = .scaleAspectFit
        checkmark.isHidden = true
        view.addSubview(checkmark)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -20),
            checkmark.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            checkmark.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -20),
            checkmark.widthAnchor.constraint(equalToConstant: 50),
            checkmark.heightAnchor.constraint(equalToConstant: 50),
            statusLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 16),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
        ])
    }

    private func showSuccess(merchant: String?, amount: Double) {
        spinner.stopAnimating()
        spinner.isHidden = true
        checkmark.isHidden = false
        let name = merchant ?? "Receipt"
        statusLabel.text = "Saved: \(name) — ₹\(String(format: "%.0f", amount))"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.dismissExtension()
        }
    }

    private func showError(_ message: String) {
        spinner.stopAnimating()
        spinner.isHidden = true
        statusLabel.text = message
        statusLabel.textColor = .systemRed
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.dismissExtension()
        }
    }

    // MARK: - Load Image

    private func loadSharedImage() {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            showError("No content to share")
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
        showError("No image found")
    }

    private func handleLoadedImage(data: Any?, error: Error?) {
        var image: UIImage?

        if let url = data as? URL {
            image = UIImage(contentsOfFile: url.path)
        } else if let imageData = data as? Data {
            image = UIImage(data: imageData)
        } else if let uiImage = data as? UIImage {
            image = uiImage
        }

        guard let finalImage = image else {
            showError("Could not load image")
            return
        }

        processAndSave(image: finalImage)
    }

    // MARK: - Process & Save

    private func processAndSave(image: UIImage) {
        Task {
            // Step 1: OCR
            let ocrText = await performOCR(image: image)

            guard let text = ocrText, !text.isEmpty else {
                await MainActor.run { showError("No text found in image") }
                return
            }

            // Step 2: AI Extraction
            await MainActor.run { statusLabel.text = "Extracting details..." }

            var result = await extractViaFoundationModels(ocrText: text)
            if result == nil {
                result = await extractViaAzureAI(ocrText: text)
            }

            guard let extracted = result, extracted.amount > 0 else {
                await MainActor.run { showError("Could not extract expense") }
                return
            }

            // Step 3: Save to App Group
            let manager = PendingExpenseManager()
            guard manager.isContainerAvailable else {
                await MainActor.run { showError("Shared storage unavailable") }
                return
            }

            var pending = PendingExpense(
                amount: extracted.amount,
                merchant: extracted.merchant,
                date: extracted.date ?? Date(),
                category: extracted.category,
                note: extracted.note,
                source: "share"
            )

            // Save receipt image
            if let imageData = image.jpegData(compressionQuality: 0.7) {
                let filename = UUID().uuidString + ".jpg"
                manager.saveReceiptImage(data: imageData, filename: filename)
                pending.receiptImageFilename = filename
            }

            manager.addPendingExpense(pending)
            print("[ShareExt] ✓ Saved pending expense: \(extracted.merchant ?? "?") ₹\(extracted.amount)")

            await MainActor.run {
                showSuccess(merchant: extracted.merchant, amount: extracted.amount)
            }
        }
    }

    // MARK: - OCR

    private func performOCR(image: UIImage) async -> String? {
        guard let cgImage = image.cgImage else { return nil }

        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                guard error == nil,
                      let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: nil)
                    return
                }
                let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: trimmed.isEmpty ? nil : trimmed)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    // MARK: - Foundation Models

    private func extractViaFoundationModels(ocrText: String) async -> ExtractedExpense? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return nil }
        guard case .available = SystemLanguageModel.default.availability else { return nil }

        let prompt = """
        Extract expense data from this receipt OCR text. Return ONLY valid JSON:
        {"amount":number,"merchant":"string","date":"YYYY-MM-DD","category":"string","note":"string"}
        Categories: [Food, Transport, Shopping, Bills, Entertainment, Health, Education, Travel, Groceries, Other]
        Use the grand total (final amount paid). Ignore change/tendered lines. Use null for missing fields.

        Receipt text:
        \(ocrText)
        """

        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt)
            return parseJSON(response.content)
        } catch {
            print("[ShareExt] FM error: \(error)")
            return nil
        }
        #else
        return nil
        #endif
    }

    // MARK: - Azure AI

    private func extractViaAzureAI(ocrText: String) async -> ExtractedExpense? {
        let endpoint = "https://ai-isow-np.openai.azure.com"
        let deployment = "gpt-4o-mini"
        let apiVersion = "2025-01-01-preview"
        let apiKey = ShareExtensionConfig.azureAPIKey

        guard !apiKey.isEmpty, apiKey != "YOUR_API_KEY_HERE" else { return nil }

        let urlString = "\(endpoint)/openai/deployments/\(deployment)/chat/completions?api-version=\(apiVersion)"
        guard let url = URL(string: urlString) else { return nil }

        let systemPrompt = """
        Extract expense data from receipt OCR text. Return ONLY valid JSON:
        {"amount":number,"merchant":"string","date":"YYYY-MM-DD","category":"string","note":"string"}
        Categories: [Food, Transport, Shopping, Bills, Entertainment, Health, Education, Travel, Groceries, Other]
        Use the grand total (final amount paid). Ignore change/tendered lines. Use null for missing fields.
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

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return nil
        }

        return parseJSON(content)
    }

    // MARK: - JSON Parsing

    private func parseJSON(_ content: String) -> ExtractedExpense? {
        let cleaned = content
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

        var parsedDate: Date? = nil
        if let dateStr = parsed["date"] as? String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            parsedDate = formatter.date(from: dateStr)
        }

        return ExtractedExpense(amount: amount, merchant: merchant, category: category, note: note, date: parsedDate)
    }

    // MARK: - Dismiss

    private func dismissExtension() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

// MARK: - Models

private struct ExtractedExpense {
    let amount: Double
    let merchant: String?
    let category: String?
    let note: String?
    let date: Date?
}

enum ShareExtensionConfig {
    static let azureAPIKey = "YOUR_API_KEY_HERE"
}

