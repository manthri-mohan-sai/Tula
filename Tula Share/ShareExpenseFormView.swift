//
//  ShareExpenseFormView.swift
//  Tula Share
//
//  SwiftUI form shown in the Share Extension. Displays extracted
//  expense details from the receipt photo, lets the user verify/edit,
//  and saves to the App Group for the main app to import.
//

import SwiftUI
import Vision
#if canImport(FoundationModels)
import FoundationModels
#endif

struct ShareExpenseFormView: View {
    let image: UIImage
    let onDismiss: () -> Void

    @State private var amount: String = ""
    @State private var merchant: String = ""
    @State private var category: String = "Other"
    @State private var note: String = ""
    @State private var date: Date = .now
    @State private var isProcessing: Bool = true
    @State private var processingStatus: String = "Reading receipt..."
    @State private var isSaved: Bool = false
    @State private var errorMessage: String? = nil

    private let categories = [
        "Food", "Transport", "Shopping", "Bills",
        "Entertainment", "Health", "Education",
        "Travel", "Groceries", "Other"
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                if isProcessing {
                    processingView
                } else if isSaved {
                    successView
                } else {
                    formContent
                }
            }
            .navigationTitle("Add Expense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                }
                if !isProcessing && !isSaved {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { saveExpense() }
                            .bold()
                            .disabled(amountValue <= 0)
                    }
                }
            }
        }
        .task {
            await processImage()
        }
    }

    // MARK: - Processing View

    private var processingView: some View {
        VStack(spacing: 20) {
            // Receipt thumbnail
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 200)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(radius: 4)

            ProgressView()
                .scaleEffect(1.2)

            Text(processingStatus)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .padding()
    }

    // MARK: - Success View

    private var successView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)

            Text("Expense Saved!")
                .font(.title2.bold())

            if amountValue > 0 {
                Text("\(merchant.isEmpty ? "Receipt" : merchant) — ₹\(String(format: "%.0f", amountValue))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text("Open Tula to see it in your expenses.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                onDismiss()
            }
        }
    }

    // MARK: - Form

    private var formContent: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Receipt thumbnail
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(radius: 2)
                    .padding(.top, 8)

                // Amount
                VStack(alignment: .leading, spacing: 6) {
                    Label("Amount", systemImage: "indianrupeesign")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    TextField("0", text: $amount)
                        .keyboardType(.decimalPad)
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .padding()
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal)

                // Merchant
                VStack(alignment: .leading, spacing: 6) {
                    Label("Merchant", systemImage: "storefront")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    TextField("Store name", text: $merchant)
                        .font(.body)
                        .padding()
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal)

                // Category
                VStack(alignment: .leading, spacing: 6) {
                    Label("Category", systemImage: "tag")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    categoryPicker
                }
                .padding(.horizontal)

                // Date
                VStack(alignment: .leading, spacing: 6) {
                    Label("Date", systemImage: "calendar")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    DatePicker("", selection: $date, displayedComponents: .date)
                        .labelsHidden()
                        .padding(.horizontal)
                }
                .padding(.horizontal)

                // Note
                VStack(alignment: .leading, spacing: 6) {
                    Label("Note", systemImage: "note.text")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    TextField("Optional note", text: $note)
                        .font(.body)
                        .padding()
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 30)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    // MARK: - Category Picker

    private var categoryPicker: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(categories, id: \.self) { cat in
                Button {
                    category = cat
                } label: {
                    Text(cat)
                        .font(.caption)
                        .fontWeight(category == cat ? .bold : .regular)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(category == cat ? Color.accentColor.opacity(0.2) : Color(.systemGray6))
                        .foregroundStyle(category == cat ? Color.accentColor : .primary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Processing

    private func processImage() async {
        // Step 1: OCR
        processingStatus = "Reading receipt text..."
        guard let ocrText = await performOCR() else {
            processingStatus = "No text found in image"
            errorMessage = "Could not read text from this image."
            // Still show the form with empty fields
            isProcessing = false
            return
        }

        // Step 2: AI Extraction (Foundation Models → Azure AI)
        processingStatus = "Extracting expense details..."

        // Try Foundation Models first
        if let result = await extractViaFoundationModels(ocrText: ocrText) {
            applyResult(result)
            isProcessing = false
            return
        }

        // Fallback: Azure AI
        if let result = await extractViaAzureAI(ocrText: ocrText) {
            applyResult(result)
            isProcessing = false
            return
        }

        // No AI available — show form with empty fields
        isProcessing = false
    }

    private func applyResult(_ result: ExtractedExpense) {
        if result.amount > 0 {
            amount = String(format: "%.0f", result.amount)
        }
        if let m = result.merchant, !m.isEmpty {
            merchant = m
        }
        if let c = result.category, categories.contains(c) {
            category = c
        }
        if let n = result.note, !n.isEmpty {
            note = n
        }
        if let d = result.date {
            date = d
        }
    }

    // MARK: - OCR

    private func performOCR() async -> String? {
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
        Extract expense data from receipt OCR text. Return ONLY valid JSON with these fields:
        {"amount":number,"merchant":"string","date":"YYYY-MM-DD","category":"string","note":"string"}
        Categories: [Food, Transport, Shopping, Bills, Entertainment, Health, Education, Travel, Groceries, Other]
        Use the grand total line (final amount paid). Ignore change/tendered/cash lines.
        Use null for fields not found.
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

        var parsedDate: Date? = nil
        if let dateStr = parsed["date"] as? String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            parsedDate = formatter.date(from: dateStr)
        }

        return ExtractedExpense(
            amount: amount,
            merchant: merchant,
            category: category,
            note: note,
            date: parsedDate
        )
    }

    // MARK: - Save

    private var amountValue: Double {
        Double(amount) ?? 0
    }

    private func saveExpense() {
        let manager = PendingExpenseManager()

        guard manager.isContainerAvailable else {
            errorMessage = "Shared storage not available"
            return
        }

        var pending = PendingExpense(
            amount: amountValue,
            merchant: merchant.isEmpty ? nil : merchant,
            date: date,
            category: category,
            note: note.isEmpty ? nil : note,
            source: "share"
        )

        // Save receipt image
        if let imageData = image.jpegData(compressionQuality: 0.7) {
            let filename = UUID().uuidString + ".jpg"
            manager.saveReceiptImage(data: imageData, filename: filename)
            pending.receiptImageFilename = filename
        }

        manager.addPendingExpense(pending)
        isSaved = true
    }
}

// MARK: - Extracted Expense (local model)

private struct ExtractedExpense {
    let amount: Double
    let merchant: String?
    let category: String?
    let note: String?
    let date: Date?
}

// MARK: - Config

enum ShareExtensionConfig {
    // Keep in sync with AzureAIExtractor.swift hardcodedAPIKey
    static let azureAPIKey = "YOUR_API_KEY_HERE"
    static let appGroupID = "group.com.app.Tula"
}
