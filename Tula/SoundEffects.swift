//
//  SoundEffects.swift
//  Tula
//
//  Created by Mohan Manthri on 28/05/26.
//


import AudioToolbox

/// Centralized system-sound playback. Mirrors the `Haptics` enum's
/// philosophy — one place that owns "what does the app sound like"
/// so we can refine or theme later without grepping for raw IDs.
///
/// All sounds use `AudioServicesPlaySystemSound`, which **respects the
/// silent switch**. If the user has silenced their phone, these are
/// quiet. Haptics still fire — they're the redundant channel that
/// works in any mode.
///
/// Sound IDs are documented in iOS's `/System/Library/Audio/UISounds`
/// catalog. The two voice IDs (1113/1114) are the exact tones Apple's
/// own Voice Memos and Siri use for "begin listening" / "end listening"
/// — they're effectively the platform convention for voice-input UX.
enum SoundEffects {

    /// "Begin recording" — short ascending two-tone. Same sound Apple
    /// uses when Siri or Voice Memos starts listening. Plays when the
    /// speech recognizer engages, signaling the mic is hot.
    static func voiceStart() {
        AudioServicesPlaySystemSound(1113)
    }

    /// "End recording" — short descending two-tone. Voice Memos /
    /// Siri stop tone. Plays when the recognizer finalizes its result
    /// or the user manually stops dictation.
    static func voiceEnd() {
        AudioServicesPlaySystemSound(1114)
    }
}