//
//  AIProviderConfig.swift
//  Tula
//
//  Stores the user's choice of AI parsing provider and any credentials
//  needed for cloud-based models. Persisted via @AppStorage / UserDefaults.
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Provider Enum

/// The AI provider options available for smart expense parsing.
enum AIProvider: String, CaseIterable, Identifiable {
    case appleFM = "appleFM"
    case openAI = "openAI"
    case gemini = "gemini"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleFM: return "Apple Intelligence (On Device)"
        case .openAI: return "ChatGPT (Cloud)"
        case .gemini: return "Google Gemini (Cloud)"
        }
    }

    var icon: String {
        switch self {
        case .appleFM: return "apple.intelligence"
        case .openAI: return "cloud.fill"
        case .gemini: return "sparkle"
        }
    }

    /// Fallback icon for iOS < 26 where apple.intelligence doesn't exist
    var iconFallback: String {
        switch self {
        case .appleFM: return "sparkles"
        case .openAI: return "cloud.fill"
        case .gemini: return "sparkle"
        }
    }

    var subtitle: String {
        switch self {
        case .appleFM: return "Private, on-device. No data leaves your phone."
        case .openAI: return "Requires API key. Data sent to OpenAI servers."
        case .gemini: return "Google AI. Free tier available."
        }
    }

    /// Whether this provider requires user-entered credentials.
    var requiresConfiguration: Bool {
        switch self {
        case .appleFM: return false
        case .openAI: return true
        case .gemini: return true
        }
    }

    /// Whether this provider is currently usable (hardware + config).
    var isReady: Bool {
        switch self {
        case .appleFM:
            #if canImport(FoundationModels)
            guard #available(iOS 26.0, *) else { return false }
            if case .available = SystemLanguageModel.default.availability {
                return true
            }
            return false
            #else
            return false
            #endif
        case .openAI:
            let config = CloudAIConfig.load()
            return !config.apiKey.isEmpty
        case .gemini:
            let config = CloudAIConfig.loadGemini()
            return !config.apiKey.isEmpty
        }
    }
}

// MARK: - Cloud AI Configuration

/// Stores cloud AI provider settings (endpoint, key, model).
/// Persisted to UserDefaults (App Group-aware so the share extension
/// can also read it).
struct CloudAIConfig: Codable {
    var endpoint: String
    var apiKey: String
    var model: String

    /// Default OpenAI-compatible settings.
    static let `default` = CloudAIConfig(
        endpoint: "https://api.openai.com/v1/chat/completions",
        apiKey: "",
        model: "gpt-4o-mini"
    )

    /// Default Gemini settings (OpenAI-compatible endpoint).
    static let geminiDefault = CloudAIConfig(
        endpoint: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
        apiKey: "",
        model: "gemini-2.5-flash"
    )

    // MARK: - Persistence

    private static let storageKey = "cloudAIConfig"
    private static let geminiStorageKey = "geminiAIConfig"

    /// Load from UserDefaults (shared App Group container).
    static func load() -> CloudAIConfig {
        guard let defaults = UserDefaults(suiteName: "group.com.app.Tula"),
              let data = defaults.data(forKey: storageKey),
              let config = try? JSONDecoder().decode(CloudAIConfig.self, from: data) else {
            return .default
        }
        return config
    }

    /// Save to UserDefaults (shared App Group container).
    func save() {
        guard let defaults = UserDefaults(suiteName: "group.com.app.Tula"),
              let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: CloudAIConfig.storageKey)
    }

    // MARK: - Gemini Persistence

    /// Load Gemini config from UserDefaults.
    static func loadGemini() -> CloudAIConfig {
        guard let defaults = UserDefaults(suiteName: "group.com.app.Tula"),
              let data = defaults.data(forKey: geminiStorageKey),
              let config = try? JSONDecoder().decode(CloudAIConfig.self, from: data) else {
            return .geminiDefault
        }
        return config
    }

    /// Save as Gemini config to UserDefaults.
    func saveAsGemini() {
        guard let defaults = UserDefaults(suiteName: "group.com.app.Tula"),
              let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: CloudAIConfig.geminiStorageKey)
    }

}

// MARK: - Receipt Parsing Mode

/// How receipts are parsed when using a cloud AI provider.
/// Apple FM always uses OCR (on-device only), so this setting only
/// applies when OpenAI or Gemini is selected.
enum ReceiptParsingMode: String, CaseIterable, Identifiable {
    case ocrThenAI = "ocrThenAI"
    case directImage = "directImage"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ocrThenAI: return "OCR → Text → AI"
        case .directImage: return "Send Image Directly"
        }
    }

    var subtitle: String {
        switch self {
        case .ocrThenAI: return "Extract text on-device first, then send text to AI."
        case .directImage: return "Send receipt photo directly to AI for better accuracy."
        }
    }

    var icon: String {
        switch self {
        case .ocrThenAI: return "doc.text.viewfinder"
        case .directImage: return "photo"
        }
    }
}

enum ReceiptParsingModeStorage {
    private static let key = "receiptParsingMode"

    static var selected: ReceiptParsingMode {
        get {
            guard let defaults = UserDefaults(suiteName: "group.com.app.Tula"),
                  let raw = defaults.string(forKey: key),
                  let mode = ReceiptParsingMode(rawValue: raw) else {
                return .directImage
            }
            return mode
        }
        set {
            guard let defaults = UserDefaults(suiteName: "group.com.app.Tula") else { return }
            defaults.set(newValue.rawValue, forKey: key)
        }
    }
}

// MARK: - Selected Provider Storage

/// Convenience for reading/writing the selected provider to UserDefaults.
enum AIProviderStorage {
    private static let key = "selectedAIProvider"

    /// Whether the user has explicitly chosen a provider in Settings.
    /// When false, `selected` returns a default — callers should use
    /// their own auto-detection logic rather than trusting the default.
    static var hasExplicitSelection: Bool {
        UserDefaults(suiteName: "group.com.app.Tula")?
            .string(forKey: key) != nil
    }

    static var selected: AIProvider {
        get {
            guard let defaults = UserDefaults(suiteName: "group.com.app.Tula"),
                  let raw = defaults.string(forKey: key),
                  let provider = AIProvider(rawValue: raw) else {
                return .gemini
            }
            return provider
        }
        set {
            guard let defaults = UserDefaults(suiteName: "group.com.app.Tula") else { return }
            defaults.set(newValue.rawValue, forKey: key)
        }
    }
}
