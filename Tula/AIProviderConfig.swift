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

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleFM: return "Apple FM (On Device)"
        case .openAI: return "ChatGPT (Cloud)"
        }
    }

    var icon: String {
        switch self {
        case .appleFM: return "apple.intelligence"
        case .openAI: return "cloud.fill"
        }
    }

    /// Fallback icon for iOS < 26 where apple.intelligence doesn't exist
    var iconFallback: String {
        switch self {
        case .appleFM: return "sparkles"
        case .openAI: return "cloud.fill"
        }
    }

    var subtitle: String {
        switch self {
        case .appleFM: return "Private, on-device. No data leaves your phone."
        case .openAI: return "Requires API key. Data sent to OpenAI servers."
        }
    }

    /// Whether this provider requires user-entered credentials.
    var requiresConfiguration: Bool {
        switch self {
        case .appleFM: return false
        case .openAI: return true
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

    // MARK: - Persistence

    private static let storageKey = "cloudAIConfig"

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
        defaults.set(data, forKey: storageKey)
    }
}

// MARK: - Selected Provider Storage

/// Convenience for reading/writing the selected provider to UserDefaults.
enum AIProviderStorage {
    private static let key = "selectedAIProvider"

    static var selected: AIProvider {
        get {
            guard let defaults = UserDefaults(suiteName: "group.com.app.Tula"),
                  let raw = defaults.string(forKey: key),
                  let provider = AIProvider(rawValue: raw) else {
                return .appleFM
            }
            return provider
        }
        set {
            guard let defaults = UserDefaults(suiteName: "group.com.app.Tula") else { return }
            defaults.set(newValue.rawValue, forKey: key)
        }
    }
}
