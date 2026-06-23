//
//  SoundEffects.swift
//  Tula
//
//  Created by Mohan Manthri on 28/05/26.
//


import AudioToolbox

/// Centralized system-sound playback for functional audio cues.
///
/// Voice sounds use `AudioServicesPlaySystemSound`, which **respects the
/// silent switch**. If the user has silenced their phone, these are
/// quiet. Haptics still fire — they're the redundant channel that
/// works in any mode.
enum SoundEffects {

    // MARK: - Voice (always play — functional, not decorative)

    /// "Begin recording" — short ascending two-tone. Same sound Apple
    /// uses when Siri or Voice Memos starts listening. Plays when the
    /// speech recognizer engages, signaling the mic is hot.
    static func voiceStart() {
        AudioServicesPlaySystemSound(1113)
    }

    /// Plays the start tone and calls `completion` on the main queue
    /// once the sound finishes. Use this when the caller needs to
    /// reconfigure the audio session afterwards — switching to
    /// `.playAndRecord` while the tone is still playing cuts it off.
    static func voiceStart(completion: @escaping @Sendable () -> Void) {
        AudioServicesPlaySystemSoundWithCompletion(1113) {
            DispatchQueue.main.async {
                completion()
            }
        }
    }

    /// "End recording" — short descending two-tone. Voice Memos /
    /// Siri stop tone. Plays when the recognizer finalizes its result
    /// or the user manually stops dictation.
    static func voiceEnd() {
        AudioServicesPlaySystemSound(1114)
    }
}
