//
//  QwenExtractor.swift
//  Tula
//
//  On-device Qwen2.5-0.5B inference via llama.cpp for receipt
//  expense extraction. Enables accurate parsing on iPhone 12+
//  devices that lack Apple Foundation Models support.
//
//  Fallback chain: Foundation Models → Qwen → Vision regex.
//

import Foundation
import llama

/// On-device LLM extractor using Qwen2.5-0.5B-Instruct (Q4_K_M GGUF).
/// Singleton with lazy model loading — loads on first extraction call,
/// auto-unloads after 30s idle to free ~370MB RAM.
final class QwenExtractor: @unchecked Sendable {

    static let shared = QwenExtractor()

    // MARK: - Configuration

    private static let modelFileName = "Qwen2.5-0.5B-Instruct-Q4_K_M"
    private static let modelFileExtension = "gguf"
    private static let contextSize: UInt32 = 2048
    private static let maxTokens: Int = 512
    private static let temperature: Float = 0.1
    private static let topP: Float = 0.9
    private static let unloadDelay: TimeInterval = 30

    // MARK: - State

    private var model: OpaquePointer? // llama_model *
    private var ctx: OpaquePointer?   // llama_context *
    private var unloadWorkItem: DispatchWorkItem?
    private var isLoaded: Bool { model != nil && ctx != nil }
    private let lock = NSLock()

    // MARK: - Availability

    /// Whether the Qwen GGUF model file is bundled in the app.
    var isAvailable: Bool {
        modelPath != nil
    }

    private var modelPath: String? {
        Bundle.main.path(
            forResource: Self.modelFileName,
            ofType: Self.modelFileExtension
        )
    }

    // MARK: - Lifecycle

    private init() {}

    /// Load model into memory. Called lazily on first extraction.
    private func loadModel() throws {
        guard !isLoaded else { return }
        guard let path = modelPath else {
            throw QwenError.modelFileNotFound
        }

        llama_backend_init()

        // Model parameters
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 99 // Offload all layers to Metal GPU

        guard let loadedModel = llama_model_load_from_file(path, modelParams) else {
            throw QwenError.modelLoadFailed
        }
        self.model = loadedModel

        // Context parameters
        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = Self.contextSize
        ctxParams.n_batch = 512
        ctxParams.n_threads = UInt32(min(ProcessInfo.processInfo.activeProcessorCount, 4))
        ctxParams.n_threads_batch = ctxParams.n_threads

        guard let context = llama_init_from_model(loadedModel, ctxParams) else {
            llama_model_free(loadedModel)
            self.model = nil
            throw QwenError.contextCreationFailed
        }
        self.ctx = context
    }

    /// Unload model from memory to free ~370MB RAM.
    private func unloadModel() {
        if let ctx = self.ctx {
            llama_free(ctx)
            self.ctx = nil
        }
        if let model = self.model {
            llama_model_free(model)
            self.model = nil
        }
        llama_backend_free()
    }

    /// Schedule auto-unload after idle period. Resets timer on each call.
    private func scheduleUnload() {
        unloadWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.unloadModel()
            self.lock.unlock()
        }
        unloadWorkItem = workItem
        DispatchQueue.global().asyncAfter(
            deadline: .now() + Self.unloadDelay,
            execute: workItem
        )
    }

    // MARK: - Extraction

    /// Extract expense info from receipt OCR text using Qwen.
    /// - Parameters:
    ///   - rawText: OCR'd receipt text from Vision framework.
    ///   - categoryNames: User's category names for constrained selection.
    /// - Returns: Parsed extraction or nil on failure.
    func extractFromReceipt(rawText: String, categoryNames: [String]) async -> ReceiptSmartParseResult? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let categoryList = categoryNames.joined(separator: ", ")
        let prompt = buildReceiptPrompt(rawText: trimmed, categoryList: categoryList)

        guard let response = await runInference(prompt: prompt) else { return nil }
        return parseReceiptResponse(response)
    }

    /// Extract basic expense info from free text using Qwen.
    func extract(from text: String, categoryNames: [String]) async -> ExpenseExtraction? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let categoryList = categoryNames.joined(separator: ", ")
        let prompt = buildExtractionPrompt(text: trimmed, categoryList: categoryList)

        guard let response = await runInference(prompt: prompt) else { return nil }
        return parseExtractionResponse(response)
    }

    // MARK: - Inference

    private func runInference(prompt: String) async -> String? {
        return await withCheckedContinuation { continuation in
            // Use Thread with 8MB stack (dispatch queues only have 512KB,
            // which can overflow during model load/inference)
            let thread = Thread {
                self.lock.lock()
                defer { self.lock.unlock() }

                // Cancel any pending unload since we're about to use the model
                self.unloadWorkItem?.cancel()

                do {
                    try self.loadModel()
                } catch {
                    print("[QwenExtractor] Load error: \(error)")
                    continuation.resume(returning: nil)
                    return
                }

                guard let model = self.model, let ctx = self.ctx else {
                    continuation.resume(returning: nil)
                    return
                }

                let vocab = llama_model_get_vocab(model)

                // Tokenize prompt using withUnsafeBufferPointer for safe memory
                let promptUTF8 = Array(prompt.utf8CString) // includes null terminator
                let maxTokens = Int32(promptUTF8.count + 256)
                var tokens = [llama_token](repeating: 0, count: Int(maxTokens))

                let nTokens = promptUTF8.withUnsafeBufferPointer { buf in
                    tokens.withUnsafeMutableBufferPointer { tokBuf in
                        llama_tokenize(
                            vocab,
                            buf.baseAddress,
                            Int32(promptUTF8.count - 1), // exclude null terminator
                            tokBuf.baseAddress,
                            maxTokens,
                            true,  // add_special (BOS)
                            false  // parse_special
                        )
                    }
                }

                guard nTokens > 0 else {
                    self.scheduleUnload()
                    continuation.resume(returning: nil)
                    return
                }

                let promptTokens = Array(tokens.prefix(Int(nTokens)))

                // Clear KV cache
                llama_kv_cache_clear(ctx)

                // Process prompt tokens in a single batch
                let batch = llama_batch_get_one(
                    UnsafeMutablePointer(mutating: promptTokens),
                    Int32(promptTokens.count)
                )

                guard llama_decode(ctx, batch) == 0 else {
                    self.scheduleUnload()
                    continuation.resume(returning: nil)
                    return
                }

                // Generate tokens one at a time
                var outputTokens: [llama_token] = []
                let eosToken = llama_vocab_eos(vocab)
                var curPos = Int32(promptTokens.count)

                for _ in 0..<Self.maxTokens {
                    let logits = llama_get_logits_ith(ctx, -1)
                    guard let logitsPtr = logits else { break }

                    let vocabSize = Int(llama_vocab_n_tokens(vocab))

                    let nextToken = Self.sampleToken(
                        logits: logitsPtr,
                        vocabSize: vocabSize,
                        temperature: Self.temperature,
                        topP: Self.topP
                    )

                    if nextToken == eosToken { break }
                    outputTokens.append(nextToken)

                    // Decode next token
                    var nextTokenArr = [nextToken]
                    let nextBatch = llama_batch_get_one(&nextTokenArr, 1)
                    guard llama_decode(ctx, nextBatch) == 0 else { break }
                    curPos += 1
                }

                // Detokenize output
                var output = ""
                var buf = [CChar](repeating: 0, count: 512)
                for token in outputTokens {
                    let len = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
                    if len > 0 {
                        buf[Int(len)] = 0 // null terminate
                        output += String(cString: &buf)
                    }
                }

                self.scheduleUnload()
                continuation.resume(returning: output.isEmpty ? nil : output)
            }
            thread.stackSize = 8 * 1024 * 1024 // 8MB stack
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    // MARK: - Sampling

    private static func sampleToken(
        logits: UnsafeMutablePointer<Float>,
        vocabSize: Int,
        temperature: Float,
        topP: Float
    ) -> llama_token {
        // Apply temperature
        var candidates: [(token: llama_token, logit: Float)] = []
        candidates.reserveCapacity(vocabSize)
        for i in 0..<vocabSize {
            candidates.append((llama_token(i), logits[i]))
        }

        if temperature > 0 {
            // Scale logits by temperature
            for i in 0..<candidates.count {
                candidates[i].logit /= temperature
            }
        }

        // Sort by logit descending
        candidates.sort { $0.logit > $1.logit }

        // Softmax + top-p nucleus sampling
        let maxLogit = candidates[0].logit
        var probs: [Float] = candidates.map { exp($0.logit - maxLogit) }
        let sum = probs.reduce(0, +)
        probs = probs.map { $0 / sum }

        // Top-p cutoff
        var cumSum: Float = 0
        var cutoffIndex = probs.count
        for (i, p) in probs.enumerated() {
            cumSum += p
            if cumSum >= topP {
                cutoffIndex = i + 1
                break
            }
        }

        // Sample from top-p distribution
        let truncatedProbs = Array(probs.prefix(cutoffIndex))
        let truncatedSum = truncatedProbs.reduce(0, +)
        let roll = Float.random(in: 0..<truncatedSum)
        var acc: Float = 0
        for (i, p) in truncatedProbs.enumerated() {
            acc += p
            if acc >= roll {
                return candidates[i].token
            }
        }

        return candidates[0].token
    }

    // MARK: - Prompts

    private func buildReceiptPrompt(rawText: String, categoryList: String) -> String {
        """
        <|im_start|>system
        You extract expense data from OCR receipt text. Return ONLY valid JSON with these fields:
        - amount: number, the grand total (final amount paid). NOT subtotal+total summed. Use the explicit "Grand Total"/"Total"/"Amount Payable" line value.
        - merchant: string, the business name from the top of the receipt. Title-cased.
        - date: string in YYYY-MM-DD format, or null if not found.
        - category: one of [\(categoryList)], best fit for this merchant/items.
        - items: array of {name, price} for line items purchased. Exclude tax/totals/discounts.

        Rules:
        - If subtotal and grand total are the same value, amount = that value (NOT doubled).
        - Ignore "Cash"/"Tendered"/"Change" lines — they are not the total.
        - Do NOT sum line items. Use the printed total.
        - OCR errors: "1" may appear as "I"/"l", "0" as "O", leading digits may be dropped.
        <|im_end|>
        <|im_start|>user
        \(rawText)
        <|im_end|>
        <|im_start|>assistant
        """
    }

    private func buildExtractionPrompt(text: String, categoryList: String) -> String {
        """
        <|im_start|>system
        Extract expense information from user text. Return ONLY valid JSON with fields:
        - amount: number (the spent amount)
        - merchant: string or null
        - category: one of [\(categoryList)] or null
        - account: string or null (payment source mentioned)
        - note: string or null (extra context)
        - date: string YYYY-MM-DD or null
        <|im_end|>
        <|im_start|>user
        \(text)
        <|im_end|>
        <|im_start|>assistant
        """
    }

    // MARK: - Response Parsing

    private func parseReceiptResponse(_ response: String) -> ReceiptSmartParseResult? {
        guard let json = extractJSON(from: response),
              let data = json.data(using: .utf8) else { return nil }

        struct QwenReceiptResult: Decodable {
            let amount: Double?
            let merchant: String?
            let date: String?
            let category: String?
            let items: [QwenLineItem]?

            struct QwenLineItem: Decodable {
                let name: String
                let price: Double
            }
        }

        do {
            let decoded = try JSONDecoder().decode(QwenReceiptResult.self, from: data)
            guard let amount = decoded.amount, amount > 0 else { return nil }

            let items = (decoded.items ?? []).map {
                ReceiptLineItem(name: $0.name, price: $0.price)
            }

            return ReceiptSmartParseResult(
                amount: amount,
                merchant: decoded.merchant,
                date: decoded.date,
                category: decoded.category,
                items: items
            )
        } catch {
            // Attempt lenient extraction if JSON decode fails
            return lenientReceiptParse(response)
        }
    }

    private func parseExtractionResponse(_ response: String) -> ExpenseExtraction? {
        guard let json = extractJSON(from: response),
              let data = json.data(using: .utf8) else { return nil }

        do {
            return try JSONDecoder().decode(ExpenseExtraction.self, from: data)
        } catch {
            return nil
        }
    }

    /// Extract JSON object from model output (may contain markdown fences or preamble).
    private func extractJSON(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try direct parse first
        if trimmed.hasPrefix("{") {
            if let end = findClosingBrace(in: trimmed) {
                return String(trimmed[...end])
            }
        }

        // Strip markdown code fences
        if let range = trimmed.range(of: "```json") ?? trimmed.range(of: "```") {
            let afterFence = trimmed[range.upperBound...]
            if let endFence = afterFence.range(of: "```") {
                let jsonPart = afterFence[..<endFence.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return jsonPart
            }
        }

        // Find first { and last }
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

    /// Last-resort extraction when JSON parsing fails but model output
    /// contains recognizable amount/merchant patterns.
    private func lenientReceiptParse(_ text: String) -> ReceiptSmartParseResult? {
        // Try to find amount via regex
        let amountPattern = /\"amount\"\s*:\s*(\d+\.?\d*)/
        guard let amountMatch = text.firstMatch(of: amountPattern),
              let amount = Double(amountMatch.1) else { return nil }

        // Try merchant
        var merchant: String? = nil
        let merchantPattern = /\"merchant\"\s*:\s*\"([^\"]+)\"/
        if let m = text.firstMatch(of: merchantPattern) {
            merchant = String(m.1)
        }

        // Try date
        var date: String? = nil
        let datePattern = /\"date\"\s*:\s*\"(\d{4}-\d{2}-\d{2})\"/
        if let d = text.firstMatch(of: datePattern) {
            date = String(d.1)
        }

        // Try category
        var category: String? = nil
        let categoryPattern = /\"category\"\s*:\s*\"([^\"]+)\"/
        if let c = text.firstMatch(of: categoryPattern) {
            category = String(c.1)
        }

        return ReceiptSmartParseResult(
            amount: amount,
            merchant: merchant,
            date: date,
            category: category,
            items: []
        )
    }

    // MARK: - Errors

    enum QwenError: Error, LocalizedError {
        case modelFileNotFound
        case modelLoadFailed
        case contextCreationFailed
        case tokenizationFailed
        case generationFailed

        var errorDescription: String? {
            switch self {
            case .modelFileNotFound: "Qwen model file not found in app bundle."
            case .modelLoadFailed: "Failed to load Qwen model."
            case .contextCreationFailed: "Failed to create inference context."
            case .tokenizationFailed: "Failed to tokenize input."
            case .generationFailed: "Token generation failed."
            }
        }
    }
}
