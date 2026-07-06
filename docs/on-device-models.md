# On-device model — Whisper (voice refinement)

The app builds and runs without this. `LocalModelKit.swift` defines the seam;
until WhisperKit is added and the adapter registered, voice falls back to Apple
Speech exactly as before.

> **Note:** On-device Qwen3-VL 2B receipt parsing was evaluated and **removed** —
> a 2B VLM peaks over 3 GB at inference and gets jetsam-killed on-device.
> Receipts use the cloud parser (Gemini). If you revisit on-device vision, use a
> much smaller model and gate it to high-RAM devices.

## Wiring (already in place)

- **Voice:** `SpeechRecognizer` captures the recording to a `.caf` file when
  `LocalModelSettings.whisperRefineEnabled` is on and exposes `lastRecordingURL`;
  `VoiceInputOverlay.runInterpretation` runs `LocalModels.activeTranscriptRefiner`
  over it before parsing. The FM `correctTranscript` pass is skipped when Whisper
  is enabled (Whisper replaces it), and runs as the fallback when it's off.
- Whisper is warmed at launch (`WhisperRefiner.prewarm()` in `TulaApp`) so the
  first voice log doesn't pay the CoreML cold-start.

## 1. Add the Swift package

- **WhisperKit** — `https://github.com/argmaxinc/WhisperKit` (CoreML/ANE Whisper).
  Link it to the **Tula** target. `WhisperRefiner.swift` must also be a member of
  any target that references it.

## 2. Model

WhisperKit downloads its CoreML weights on first use. We use **`base.en`** — the
English-only variant is faster and more accurate for English than multilingual
`base`, and much lighter than `small`. For a short cleanup pass it's the sweet
spot. Decoding is greedy, English, no timestamps (see `WhisperRefiner`).

## 3. Register at launch (TulaApp)

```swift
.onAppear {
    LocalModels.transcriptRefiner = WhisperRefiner()
    if LocalModelSettings.whisperRefineEnabled,
       let refiner = LocalModels.transcriptRefiner {
        Task.detached(priority: .utility) { await refiner.prewarm() }
    }
}
```

## 4. Settings toggle

`SettingsView` → **On-device AI (Beta)** → *Whisper voice refine*, bound to
`LocalModelSettings.whisperRefineEnabled` (off by default).

## Reality check

- **Device only** (CoreML/ANE). Whisper `base.en` is light (~150 MB) and fast
  once warmed — sub-second on a short clip.
- Everything degrades gracefully: any failure returns nil and the Apple Speech
  transcript is used unchanged.
