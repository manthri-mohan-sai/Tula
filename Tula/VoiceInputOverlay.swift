import SwiftUI
import SwiftData
import Combine

// MARK: - Voice Overlay Phase

private enum VoiceOverlayPhase: Equatable {
    case listening
    case processing
    case result
}

private enum ProcessingStep: String {
    case analyzing = "Analyzing your words…"
    case understanding = "Understanding context…"
    case almostReady = "Almost ready…"
}

private enum ProcessingSubPhase: Equatable {
    case analyzing      // word reveal + blob animating
    case gathering      // words flying to convergence point
    case revealing      // condensed preview before result
}

// MARK: - Word Position Capture

private struct WordPositionPreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// MARK: - Word Classification

enum WordRole {
    case amount, merchant, category, account, filler, unmatched
}

struct ClassifiedWord: Identifiable {
    let id = UUID()
    let text: String
    let role: WordRole
}

// MARK: - VoiceInputOverlay

struct VoiceInputOverlay: View {
    let accounts: [Account]
    let categories: [Category]
    let merchantRules: [MerchantRule]
    let defaultAccount: Account?
    let currencyCode: String
    let topMerchants: [String]
    let onSave: (Expense) -> Void
    let onEdit: (Expense) -> Void
    /// Commit multiple expenses at once (multi-expense / multi-account input).
    var onSaveMany: ([Expense]) -> Void = { _ in }
    let onDismiss: () -> Void

    @StateObject private var speech = SpeechRecognizer()
    @State private var phase: VoiceOverlayPhase = .listening
    @State private var showingPermissionDenied = false
    @State private var appeared = false

    // Processing phase state
    @State private var classifiedWords: [ClassifiedWord] = []
    @State private var revealedWordCount = 0
    @State private var processingStep: ProcessingStep = .analyzing
    @State private var processingSubPhase: ProcessingSubPhase = .analyzing
    @State private var frozenTranscript: String = ""

    // Word gathering animation
    @State private var wordGatheringActive = false
    @State private var gatherTargetPosition: CGPoint = .zero
    @State private var wordPositions: [UUID: CGRect] = [:]

    // Result phase state
    /// Editable staging draft + confidence shown in the result card. Built
    /// once FM enrichment settles; the real Expense is created only on commit.
    @State private var draft: ExpenseDraft?
    /// Populated instead of `draft` when the input contains 2+ expenses
    /// ("140 on SBI and 40 cash"). Each is independently editable.
    @State private var drafts: [ExpenseDraft] = []
    @State private var showResultCard = false
    @State private var showResultButtons = false

    // Animation state
    @State private var drifting = false
    // Ring morph: 1.0 = full bars, 0.0 = smooth circle
    @State private var ringBarStrength: CGFloat = 1.0
    @State private var usedProviderLabel: String = ""

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        ZStack {
            backgroundLayer

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, Spacing.lg)
                    .padding(.top, Spacing.sm)

                Group {
                    switch phase {
                    case .listening:
                        listeningPhase
                            .transition(.asymmetric(
                                insertion: .opacity,
                                removal: .opacity.combined(with: .scale(scale: 0.96))
                            ))
                    case .processing:
                        processingPhase
                            .transition(.opacity.combined(with: .offset(y: 20)))
                    case .result:
                        resultPhase
                            .transition(.opacity)
                    }
                }
                .animation(AppAnimation.gentle, value: phase)
            }
        }
        .alert("Microphone Access Required",
               isPresented: $showingPermissionDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) { dismiss() }
        } message: {
            Text("Tula needs microphone access to capture voice input. Please enable it in Settings.")
        }
        .onAppear {
            beginListening()
            withAnimation(.easeOut(duration: 0.6)) { appeared = true }
            drifting = true
        }
    }

    // MARK: - Dynamic Background (5 Orbs)

    private var backgroundLayer: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Orb 1 — largest, audio-reactive during listening
            orbView(
                color: phaseOrbColor(index: 0),
                size: 400, blur: 130,
                driftX: (70, -70), driftY: (-180, -100),
                period: 7,
                audioScale: phase == .listening ? speech.audioLevel * 0.25 : 0,
                baseOpacity: 0.14
            )

            // Orb 2 — complementary accent
            orbView(
                color: phaseOrbColor(index: 1),
                size: 320, blur: 110,
                driftX: (-80, 100), driftY: (170, 110),
                period: 9,
                audioScale: 0,
                baseOpacity: 0.11
            )

            // Orb 3 — depth
            orbView(
                color: phaseOrbColor(index: 2),
                size: 260, blur: 100,
                driftX: (50, -60), driftY: (-30, 70),
                period: 5,
                audioScale: 0,
                baseOpacity: 0.08
            )

            // Orb 4 — subtle warmth
            orbView(
                color: phaseOrbColor(index: 3),
                size: 200, blur: 100,
                driftX: (-40, 80), driftY: (90, -50),
                period: 11,
                audioScale: 0,
                baseOpacity: 0.06
            )

            // Orb 5 — micro accent
            orbView(
                color: phaseOrbColor(index: 4),
                size: 160, blur: 90,
                driftX: (60, -30), driftY: (-100, 40),
                period: 6,
                audioScale: 0,
                baseOpacity: 0.05
            )
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.8), value: phase)
    }

    private func orbView(
        color: Color, size: CGFloat, blur: CGFloat,
        driftX: (CGFloat, CGFloat), driftY: (CGFloat, CGFloat),
        period: Double, audioScale: CGFloat, baseOpacity: Double
    ) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [color, color.opacity(0)],
                    center: .center,
                    startRadius: 0,
                    endRadius: size / 2
                )
            )
            .frame(width: size, height: size)
            .blur(radius: blur)
            .opacity(baseOpacity + Double(audioScale) * 0.15)
            .offset(
                x: drifting ? driftX.0 : driftX.1,
                y: drifting ? driftY.0 : driftY.1
            )
            .animation(
                .easeInOut(duration: period).repeatForever(autoreverses: true),
                value: drifting
            )
            .animation(.easeOut(duration: 0.12), value: speech.audioLevel)
    }

    private func phaseOrbColor(index: Int) -> Color {
        let palettes: [[Color]] = {
            switch phase {
            case .listening:
                return [
                    [.red, .pink, Color(red: 1.0, green: 0.4, blue: 0.3), .orange, .red.opacity(0.7)]
                ]
            case .processing:
                return [
                    [Color.tulaBrandFallback, .orange, Color(red: 1.0, green: 0.7, blue: 0.2), Color.tulaBrandFallback.opacity(0.8), .yellow]
                ]
            case .result:
                return [
                    [.green, .teal, .cyan, .mint, .green.opacity(0.7)]
                ]
            }
        }()
        return palettes[0][min(index, palettes[0].count - 1)]
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            HStack(spacing: 6) {
                Circle()
                    .fill(phaseIndicatorColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: phaseIndicatorColor.opacity(0.8), radius: 6)

                Text(phaseLabel)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.5))
                    .textCase(.uppercase)
                    .tracking(1.0)
            }
            .animation(AppAnimation.snappy, value: phase)

            Spacer()

            Button {
                Haptics.tap()
                speech.stop()
                onDismiss()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.06), in: Circle())
            }
        }
    }

    private var phaseIndicatorColor: Color {
        switch phase {
        case .listening:  return .red
        case .processing: return Color.tulaBrandFallback
        case .result:     return .green
        }
    }

    private var phaseLabel: String {
        switch phase {
        case .listening:  return "Listening"
        case .processing: return "Processing"
        case .result:     return "Ready"
        }
    }

    // MARK: - Phase 1: Listening

    private var listeningPhase: some View {
        VStack(spacing: 0) {
            Spacer()

            // AudioRing — circular radial visualizer
            AudioRing(
                audioLevel: speech.audioLevel,
                isActive: speech.isRecording,
                barStrength: ringBarStrength,
                accentColor: Color.tulaBrandFallback
            )
            .frame(width: 260, height: 260)

            Spacer()
                .frame(height: Spacing.xxl)

            // Live transcription
            Group {
                if speech.transcript.isEmpty {
                    VStack(spacing: Spacing.sm) {
                        Text("Speak naturally")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white.opacity(0.2))
                        Text("\"350 at Swiggy for lunch\"")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.1))
                            .italic()
                    }
                } else {
                    // Scrollable so the FULL utterance stays readable no matter
                    // how long; auto-pins to the latest words as you speak.
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            Text(speech.transcript)
                                .font(.system(size: 26, weight: .bold))
                                .foregroundStyle(.white.opacity(0.95))
                                .multilineTextAlignment(.center)
                                .lineSpacing(4)
                                .minimumScaleFactor(0.7)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                                .id("transcriptTail")
                        }
                        .frame(maxHeight: 200)
                        .onChange(of: speech.transcript) { _, _ in
                            withAnimation(.easeOut(duration: 0.25)) {
                                proxy.scrollTo("transcriptTail", anchor: .bottom)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Spacing.xl)
            .frame(minHeight: 80)

            // Recording indicator
            VStack(spacing: 6) {
                HStack(spacing: Spacing.sm) {
                    if speech.isRecording {
                        PulsingDot()
                        Text("Listening")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.3))
                    } else if speech.isCorrecting {
                        ProgressView()
                            .scaleEffect(0.6)
                            .tint(.white.opacity(0.3))
                        Text("Refining...")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                }
                .frame(height: 20)

                if hasMeaningfulTranscript {
                    Text("AI will refine and parse your expense")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.15))
                        .transition(.opacity)
                }
            }
            .padding(.top, Spacing.md)

            Spacer()

            listeningActions
                .padding(.horizontal, Spacing.lg)
                .padding(.bottom, Spacing.xxl)
        }
    }

    private var listeningActions: some View {
        HStack(spacing: Spacing.md) {
            Button {
                Haptics.selection()
                speech.clearTranscript()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.subheadline.weight(.medium))
                    Text("Clear")
                        .font(.subheadline.weight(.medium))
                }
                .foregroundStyle(.white.opacity(speech.transcript.isEmpty ? 0.15 : 0.6))
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(.white.opacity(0.06), in: Capsule())
            }
            .disabled(speech.transcript.isEmpty)

            Button {
                Haptics.impact()
                stopAndProcess()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.subheadline.weight(.bold))
                    Text("Process")
                        .font(.headline.weight(.semibold))
                    Image(systemName: "arrow.right")
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(hasMeaningfulTranscript ? .white : .white.opacity(0.3))
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(
                    hasMeaningfulTranscript
                        ? Color.tulaBrandFallback
                        : Color.tulaBrandFallback.opacity(0.15),
                    in: Capsule()
                )
                .shadow(
                    color: hasMeaningfulTranscript
                        ? Color.tulaBrandFallback.opacity(0.4) : .clear,
                    radius: 16, y: 6
                )
            }
            .disabled(!hasMeaningfulTranscript)
        }
    }

    private var hasMeaningfulTranscript: Bool {
        !speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Phase 2: Processing

    private var processingPhase: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // Provider label
                if !usedProviderLabel.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.caption2)
                        Text(usedProviderLabel)
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(.white.opacity(0.2))
                    .padding(.top, Spacing.sm)
                    .transition(.opacity)
                }

                Spacer()
                    .frame(height: Spacing.xxl)

                // Annotated transcript with position capture
                annotatedTranscriptWithPositions
                    .padding(.horizontal, Spacing.xl)
                    .opacity(processingSubPhase == .revealing ? 0 : 1)
                    .animation(AppAnimation.gentle, value: processingSubPhase)

                Spacer()
                    .frame(height: Spacing.xl)

                // AIProcessingBlob — visible during analyzing
                if processingSubPhase == .analyzing {
                    AIProcessingBlob()
                        .frame(width: 160, height: 160)
                        .transition(.scale.combined(with: .opacity))
                }

                // Gathered preview pill — appears after words converge
                if processingSubPhase == .gathering || processingSubPhase == .revealing {
                    gatheredPreviewPill
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }

                Spacer()

                // Processing status with step indicator
                if processingSubPhase == .analyzing {
                    HStack(spacing: 10) {
                        ProcessingDots()
                        Text(processingStep.rawValue)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.3))
                            .contentTransition(.numericText())
                            .animation(AppAnimation.snappy, value: processingStep)
                    }
                    .padding(.bottom, Spacing.xxxl)
                    .transition(.opacity)
                }
            }
            .coordinateSpace(name: "processingCoordSpace")
            .onAppear {
                gatherTargetPosition = CGPoint(
                    x: geometry.size.width / 2,
                    y: geometry.size.height * 0.45
                )
            }
        }
    }

    /// Annotated transcript with position capture — each word is individually positioned
    /// in a FlowLayout so we can animate them flying to the gather point
    private var annotatedTranscriptWithPositions: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(classifiedWords.enumerated()), id: \.element.id) { index, word in
                let isRevealed = index < revealedWordCount
                let isFiller = word.role == .filler
                let isGatherable = word.role != .filler && word.role != .unmatched

                Text(word.text)
                    .font(.title3)
                    .fontWeight(isRevealed && !isFiller ? .semibold : .regular)
                    .foregroundStyle(
                        isRevealed
                            ? colorForRole(word.role).opacity(isFiller ? 0.2 : 1.0)
                            : Color.white.opacity(0.06)
                    )
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(
                                isRevealed && isGatherable && !wordGatheringActive
                                    ? colorForRole(word.role).opacity(0.1)
                                    : Color.clear
                            )
                    )
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: WordPositionPreferenceKey.self,
                                value: [word.id: geo.frame(in: .named("processingCoordSpace"))]
                            )
                        }
                    )
                    .opacity(wordGatheringActive ? 0.0 : 1.0)
                    .offset(
                        x: wordGatheringActive && isGatherable
                            ? gatherOffset(for: word.id).width : 0,
                        y: wordGatheringActive && isGatherable
                            ? gatherOffset(for: word.id).height : 0
                    )
                    .scaleEffect(wordGatheringActive && isGatherable ? 0.3 : 1.0)
                    .animation(
                        .spring(response: 0.55, dampingFraction: 0.75)
                            .delay(Double(index) * 0.03),
                        value: wordGatheringActive
                    )
            }
        }
        .frame(maxWidth: .infinity)
        .onPreferenceChange(WordPositionPreferenceKey.self) { positions in
            wordPositions = positions
        }
        .animation(AppAnimation.snappy, value: revealedWordCount)
    }

    /// The draft used for the mid-processing preview pill (single, or the
    /// first of a multi-expense result).
    private var previewDraft: ExpenseDraft? { draft ?? drafts.first }

    /// One-line summary for the preview pill: merchant if present, else items.
    private func pillSummary(for data: ExpenseDraft) -> String? {
        if let m = data.merchant, !m.isEmpty { return m }
        return data.items.isEmpty ? nil : data.items.map { $0.capitalized }.joined(separator: ", ")
    }

    /// Gathered preview pill — appears at convergence after words gather
    private var gatheredPreviewPill: some View {
        VStack(spacing: Spacing.sm) {
            if let data = previewDraft {
                // Category icon with glow
                ZStack {
                    Circle()
                        .fill(categoryColor(for: data.category).opacity(0.12))
                        .frame(width: 48, height: 48)
                        .blur(radius: 8)

                    Image(systemName: data.category?.iconKey ?? "checkmark.circle.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(categoryColor(for: data.category))
                }

                // Condensed amount
                Text(Currency.format(data.amount, code: currencyCode))
                    .font(.system(size: 32, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.tulaBrandFallback)
                    .monospacedDigit()

                // One-line summary — decodes in for the "locking on" beat.
                // Prefer merchant, then the item list.
                if let summary = pillSummary(for: data), !summary.isEmpty {
                    ScrambleText(
                        text: summary,
                        font: .subheadline, weight: .medium,
                        color: .white.opacity(0.6),
                        duration: 0.5
                    )
                    .lineLimit(1)
                }
            }
        }
        .padding(.vertical, Spacing.lg)
        .padding(.horizontal, Spacing.xl)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.large)
                .fill(.ultraThinMaterial.opacity(0.2))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.large)
                        .stroke(.white.opacity(0.06))
                )
        )
        .scaleEffect(processingSubPhase == .revealing ? 1.0 : 0.92)
        .opacity(processingSubPhase == .revealing ? 1.0 : 0.85)
        .animation(AppAnimation.gentle, value: processingSubPhase)
    }

    // MARK: - Phase 3: Result

    private var resultPhase: some View {
        VStack(spacing: 0) {
            // Provider badge
            if !usedProviderLabel.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.caption2)
                    Text(usedProviderLabel)
                        .font(.caption2.weight(.medium))
                }
                .foregroundStyle(.white.opacity(0.35))
                .padding(.top, Spacing.sm)
            }

            // Keep the user's spoken words in scope — the primary object the
            // whole flow is about. Readable, not a faded afterthought.
            spokenTranscriptHeader
                .padding(.horizontal, Spacing.xl)
                .padding(.top, Spacing.md)

            Spacer(minLength: Spacing.md)

            resultContent

            Spacer(minLength: Spacing.md)

            ResultActionBar(
                canSave: canSaveResult,
                showEdit: drafts.isEmpty,
                saveTitle: saveTitle,
                onDiscard: {
                    Haptics.selection()
                    onDismiss()
                    dismiss()
                },
                onStartOver: { startOver() },
                onEdit: {
                    Haptics.selection()
                    if let expense = createExpense() { onEdit(expense) }
                    dismiss()
                },
                onSave: { commitResult() }
            )
            .padding(.horizontal, Spacing.lg)
            .padding(.bottom, Spacing.xxl)
            .opacity(showResultButtons ? 1 : 0)
            .offset(y: showResultButtons ? 0 : 30)
            .animation(AppAnimation.bouncy, value: showResultButtons)
        }
    }

    /// The parsed result: a scrollable stack of editable cards for multi-expense
    /// input, a single card otherwise, or the empty-state when nothing parsed.
    @ViewBuilder
    private var resultContent: some View {
        if !drafts.isEmpty {
            multiExpenseReview
                .opacity(showResultCard ? 1 : 0)
                .scaleEffect(showResultCard ? 1 : 0.96, anchor: .top)
                .animation(AppAnimation.bouncy, value: showResultCard)
        } else if draft != nil {
            EditableExpenseCard(
                draft: draftBinding,
                accounts: accounts,
                categories: categories,
                currencyCode: currencyCode
            )
            .padding(.horizontal, Spacing.lg)
            .opacity(showResultCard ? 1 : 0)
            .scaleEffect(showResultCard ? 1 : 0.96)
            .animation(AppAnimation.bouncy, value: showResultCard)
        } else {
            nothingParsedView
        }
    }

    /// Multi-expense review — a count + total header, then one editable card
    /// per expense in a scroll view.
    private var multiExpenseReview: some View {
        VStack(spacing: Spacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.stack.fill").font(.caption2)
                Text("\(drafts.count) expenses · \(Currency.format(draftsTotal, code: currencyCode))")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(.white.opacity(0.7))

            ScrollView(showsIndicators: false) {
                VStack(spacing: Spacing.md) {
                    ForEach(drafts.indices, id: \.self) { index in
                        EditableExpenseCard(
                            draft: $drafts[index],
                            accounts: accounts,
                            categories: categories,
                            currencyCode: currencyCode,
                            animateIn: false
                        )
                    }
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.xs)
            }
        }
    }

    private var spokenTranscriptHeader: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "quote.opening").font(.caption2)
                Text("You said").font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.white.opacity(0.35))

            // Scrollable so even a long sentence is fully readable while you
            // review the parse — the primary object stays in scope.
            ScrollView(.vertical, showsIndicators: false) {
                Text(frozenTranscript)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: 88)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You said: \(frozenTranscript)")
    }

    private var draftsTotal: Double { drafts.reduce(0) { $0 + $1.amount } }

    private var canSaveResult: Bool {
        drafts.isEmpty ? (draft?.isValid ?? false) : drafts.contains { $0.isValid }
    }

    private var saveTitle: String {
        let count = drafts.filter { $0.isValid }.count
        return count > 1 ? "Save \(count)" : "Save"
    }

    /// Commit the result — all valid drafts for multi-expense, or the single
    /// draft otherwise — then dismiss.
    private func commitResult() {
        if !drafts.isEmpty {
            let expenses = createExpenses()
            if !expenses.isEmpty {
                Haptics.success()
                SoundEffects.voiceEnd()
                onSaveMany(expenses)
            }
        } else if let expense = createExpense() {
            Haptics.success()
            SoundEffects.voiceEnd()
            onSave(expense)
        }
        dismiss()
    }

    /// Non-optional binding into the optional `draft`. The result card is only
    /// rendered when `draft != nil`, so the fallback value is never used in
    /// practice — it exists solely to satisfy the Binding's get.
    private var draftBinding: Binding<ExpenseDraft> {
        Binding(
            get: {
                draft ?? ExpenseDraft(
                    amount: 0, date: .now, merchant: nil, note: nil,
                    category: nil, account: nil, rawInput: frozenTranscript,
                    confidence: ParseConfidence(amount: .low, merchant: .low,
                                                category: .low, account: .low)
                )
            },
            set: { draft = $0 }
        )
    }

    /// Reset everything and return to the listening phase for a fresh capture.
    private func startOver() {
        Haptics.tap()
        draft = nil
        drafts = []
        classifiedWords = []
        revealedWordCount = 0
        wordGatheringActive = false
        processingSubPhase = .analyzing
        processingStep = .analyzing
        showResultCard = false
        showResultButtons = false
        ringBarStrength = 1.0
        usedProviderLabel = ""
        frozenTranscript = ""
        speech.clearTranscript()
        withAnimation(AppAnimation.gentle) { phase = .listening }
        beginListening()
    }

    /// Nothing parsed — fallback view
    private var nothingParsedView: some View {
        VStack(spacing: Spacing.lg) {
            ZStack {
                Circle()
                    .fill(.white.opacity(0.04))
                    .frame(width: 80, height: 80)
                Image(systemName: "waveform.slash")
                    .font(.system(size: 32))
                    .foregroundStyle(.white.opacity(0.2))
            }

            VStack(spacing: Spacing.sm) {
                Text("Couldn't understand that")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Text("Try again or type it manually")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
    }

    private func categoryColor(for category: Category?) -> Color {
        guard let category else { return .green }
        return Color(hex: category.colorHex)
    }

    /// Compute offset for a word to fly toward the gather target
    private func gatherOffset(for wordID: UUID) -> CGSize {
        guard let wordFrame = wordPositions[wordID] else { return .zero }
        let wordCenter = CGPoint(x: wordFrame.midX, y: wordFrame.midY)
        return CGSize(
            width: gatherTargetPosition.x - wordCenter.x,
            height: gatherTargetPosition.y - wordCenter.y
        )
    }

    // MARK: - Actions

    private func beginListening() {
        Task {
            let ok = await speech.requestAuthorization()
            if ok {
                var phrases: [String] = []
                let activeAccounts = accounts.filter { !$0.isArchived }
                phrases.append(contentsOf: activeAccounts.map(\.name))
                // Add individual words from account names so the speech
                // recognizer biases toward abbreviations ("SBI", "HDFC",
                // "ICICI") as standalone words rather than spelling them
                // out as individual letters ("S B I").
                for account in activeAccounts {
                    for word in account.name.components(separatedBy: .whitespaces)
                        where word.count >= 2 {
                        phrases.append(word)
                    }
                }
                phrases.append(contentsOf: categories.filter { !$0.isArchived }.map(\.name))
                phrases.append(contentsOf: topMerchants)
                phrases.append(
                    contentsOf: UserLearningEngine.allMerchantCorrections.values
                )
                phrases.append(contentsOf: [
                    "scratch that", "never mind", "start over", "clear that"
                ])
                speech.contextualPhrases = Array(Set(phrases)).prefix(100).map { $0 }

                Haptics.impact()
                speech.start()
            } else {
                Haptics.error()
                showingPermissionDenied = true
            }
        }
    }

    private func stopAndProcess() {
        speech.stop()

        let rawText = speech.transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty else {
            onDismiss()
            dismiss()
            return
        }

        // Freeze transcript for display in processing phase
        frozenTranscript = rawText

        // Transition to processing
        withAnimation(AppAnimation.gentle) {
            phase = .processing
            processingStep = .analyzing
        }

        // Collapse ring bars over 0.6s
        withAnimation(.easeInOut(duration: 0.6).delay(0.3)) {
            ringBarStrength = 0.0
        }

        // Step 1: Immediate rule parse
        let ruleParsed = ExpenseParser.parse(
            input: rawText,
            accounts: accounts,
            categories: categories,
            merchantRules: merchantRules,
            defaultAccount: defaultAccount
        )
        let firstValid = ruleParsed.first(where: { $0.isValid }) ?? ruleParsed.first

        // Classify words for the reveal animation (uses the quick rule parse).
        classifiedWords = Self.classifyWords(raw: rawText, parsed: firstValid)

        // Animate word reveals with staggered timing
        revealedWordCount = 0
        animateWordReveal()

        // Interpret deterministically off the main thread. The interpreter does
        // its own normalization (abbreviations, number compounds), segmentation,
        // and field extraction — one pipeline for voice and quick-log alike.
        Task.detached(priority: .userInitiated) {
            await runInterpretation(rawText: rawText)
        }
    }

    private func animateWordReveal() {
        let totalWords = classifiedWords.count
        guard totalWords > 0 else { return }

        for i in 1...totalWords {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.1) {
                withAnimation(AppAnimation.snappy) {
                    revealedWordCount = i
                }
            }
        }
    }

    @MainActor
    private func runInterpretation(rawText: String) async {
        let startedAt = Date()
        let minAnimTime: TimeInterval = 1.6

        // Advance to "Understanding context" after word reveal completes
        let wordRevealDuration = Double(classifiedWords.count) * 0.1 + 0.3
        DispatchQueue.main.asyncAfter(deadline: .now() + wordRevealDuration) {
            withAnimation(AppAnimation.snappy) {
                processingStep = .understanding
            }
        }

        // Transparency only — parsing itself is fully on-device / deterministic.
        withAnimation(.easeIn(duration: 0.3)) { usedProviderLabel = "On-device" }

        // Deterministic interpretation — the single source of truth. Same
        // pipeline for every user, no AI required.
        let interpreter = ExpenseInterpreter(
            accounts: accounts, categories: categories,
            merchantRules: merchantRules, defaultAccount: defaultAccount
        )
        var produced = interpreter.interpret(rawText)

        // P4 — optional grounded LLM assist. Only fires for a single expense
        // that's missing a merchant AND an engine is configured (user's AI, or
        // Apple FM). It fills ONLY the gap; deterministic amount/account/date
        // and any resolved category are never touched. With no engine, this is
        // skipped entirely and the deterministic result stands.
        produced = await assistFillingMerchant(produced, rawText: rawText)

        withAnimation(AppAnimation.snappy) { processingStep = .almostReady }
        let elapsed = Date().timeIntervalSince(startedAt)
        if elapsed < minAnimTime {
            try? await Task.sleep(for: .seconds(minAnimTime - elapsed))
        }

        if produced.count > 1 {
            drafts = produced
        } else {
            draft = produced.first
        }

        // === Word gathering animation ===

        // Trigger words flying to convergence point
        withAnimation(AppAnimation.gentle) {
            processingSubPhase = .gathering
            wordGatheringActive = true
        }
        Haptics.selection()

        // Wait for gathering animation
        try? await Task.sleep(for: .seconds(0.65))

        // Reveal gathered preview pill
        withAnimation(AppAnimation.bouncy) {
            processingSubPhase = .revealing
        }
        Haptics.tap()

        // Hold preview briefly
        try? await Task.sleep(for: .seconds(0.6))

        // === Transition to full result phase ===

        withAnimation(AppAnimation.gentle) {
            phase = .result
        }

        // Reveal the editable card, then the action bar. The card runs its own
        // scramble/roll-in reveal internally, so we only gate visibility here.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation(AppAnimation.bouncy) {
                showResultCard = true
            }
            Haptics.success()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            withAnimation(AppAnimation.gentle) {
                showResultButtons = true
            }
        }
    }

    /// P4 grounded LLM assist. Fills ONLY a missing merchant/category on a
    /// single-expense result, using the configured engine (user's AI, else
    /// Apple FM). Deterministic amount/account/date are never touched. Returns
    /// the input unchanged when no engine is available or there's nothing to
    /// fill — so the deterministic path is always complete on its own.
    @MainActor
    private func assistFillingMerchant(_ drafts: [ExpenseDraft],
                                       rawText: String) async -> [ExpenseDraft] {
        guard drafts.count == 1, var d = drafts.first,
              SmartExpenseParser.isAvailable,
              d.merchant == nil || d.category == nil else { return drafts }

        let categoryEntries = categories.filter { !$0.isArchived }
            .map { CategoryEntry(name: $0.name, iconKey: $0.iconKey) }
        let accountEntries = accounts.filter { !$0.isArchived }
            .map { AccountEntry(name: $0.name, kind: $0.kind.displayName, last4Digits: $0.last4Digits) }
        let context = FMContextBuilder.build(modelContext: modelContext)

        // Race the assist against a timeout so a slow cloud call can't stall.
        let fm: SmartParseResult? = await withTaskGroup(of: SmartParseResult?.self) { group in
            group.addTask {
                await SmartExpenseParser.parseVoice(
                    rawText, categories: categoryEntries,
                    accounts: accountEntries, contextBlock: context
                )
            }
            group.addTask { try? await Task.sleep(for: .seconds(4)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let fm else { return drafts }

        var changed = false
        if d.merchant == nil,
           let m = fm.merchant?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty {
            d.merchant = m
            d.confidence.merchant = .medium
            changed = true
        }
        if d.category == nil, let name = fm.category,
           let cat = categories.first(where: {
               !$0.isArchived && $0.name.lowercased() == name.lowercased()
           }) {
            d.category = cat
            d.confidence.category = .medium
            changed = true
        }
        if changed {
            withAnimation(.easeIn(duration: 0.3)) { usedProviderLabel = "AI-assisted" }
        }
        return [d]
    }

    /// Materialize Expense models from every valid draft (multi-expense Save).
    private func createExpenses() -> [Expense] {
        drafts.filter { $0.isValid }.map { d in
            let expense = Expense(
                amount: d.amount, date: d.date,
                merchant: d.merchant, note: d.note,
                source: .smartParsed, category: d.category, account: d.account
            )
            expense.rawInput = d.rawInput
            expense.items = d.items.map { LineItem(name: $0.capitalized) }
            return expense
        }
    }

    /// Creates the actual `Expense` model object from the (possibly edited)
    /// draft — only called when the user taps Save or Edit, so SwiftData
    /// doesn't auto-insert on Discard or Start Over.
    private func createExpense() -> Expense? {
        guard let data = draft, data.isValid else { return nil }
        let expense = Expense(
            amount: data.amount,
            date: data.date,
            merchant: data.merchant,
            note: data.note,
            source: .smartParsed,
            category: data.category,
            account: data.account
        )
        expense.rawInput = data.rawInput
        expense.items = data.items.map { LineItem(name: $0.capitalized) }
        return expense
    }

    // MARK: - Word Classification

    static func classifyWords(raw: String,
                              parsed: ParsedExpense?) -> [ClassifiedWord] {
        let tokens = raw.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }

        guard let parsed else {
            return tokens.map { ClassifiedWord(text: $0, role: .unmatched) }
        }

        let numberWords: Set<String> = [
            "zero", "one", "two", "three", "four", "five", "six", "seven",
            "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen",
            "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty",
            "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
            "hundred", "thousand", "lakh", "crore", "lakhs", "crores",
            "hundreds", "thousands"
        ]

        let fillerWords: Set<String> = [
            "at", "for", "from", "to", "on", "in", "with", "and", "the",
            "a", "an", "of", "by", "via", "ke", "ka", "ki", "se", "mein",
            "pe", "par", "liye", "wala", "wali", "per", "rupees", "rupee",
            "rs", "inr"
        ]

        let merchantLower = parsed.merchant?.lowercased() ?? ""
        let merchantTokens = Set(
            merchantLower.components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
        )
        let accountLower = parsed.account?.name.lowercased() ?? ""

        return tokens.map { token in
            let lower = token.lowercased()
                .trimmingCharacters(in: .punctuationCharacters)

            if Double(lower) != nil || numberWords.contains(lower) {
                return ClassifiedWord(text: token, role: .amount)
            }
            if !merchantTokens.isEmpty, merchantTokens.contains(lower) {
                return ClassifiedWord(text: token, role: .merchant)
            }
            if !accountLower.isEmpty, accountLower.contains(lower) {
                return ClassifiedWord(text: token, role: .account)
            }
            if fillerWords.contains(lower) {
                return ClassifiedWord(text: token, role: .filler)
            }
            if parsed.category != nil,
               ExpenseParser.isCategoryKeyword(lower) {
                return ClassifiedWord(text: token, role: .category)
            }

            return ClassifiedWord(text: token, role: .unmatched)
        }
    }

    // MARK: - Colors

    /// Cohesive palette: the amount gets the brand accent (it's the hero
    /// fact); entities share a single desaturated cool family so the transcript
    /// reads intentional rather than a saturated rainbow; fillers recede.
    private func colorForRole(_ role: WordRole) -> Color {
        switch role {
        case .amount:    return Color.tulaBrandFallback
        case .merchant:  return Color(red: 0.46, green: 0.64, blue: 0.94)  // soft blue
        case .category:  return Color(red: 0.53, green: 0.78, blue: 0.73)  // soft teal
        case .account:   return Color(red: 0.60, green: 0.80, blue: 0.56)  // soft green
        case .filler:    return .white.opacity(0.28)
        case .unmatched: return .white.opacity(0.55)
        }
    }
}

// MARK: - AI Processing Blob

/// Morphing gradient blob used during the processing phase.
/// Three soft organic layers rendered via Canvas at 60fps with trigonometric noise.
private struct AIProcessingBlob: View {
    @State private var time: CGFloat = 0
    @State private var breathing: Bool = false

    private let timer = Timer.publish(
        every: 1.0 / 60.0, on: .main, in: .common
    ).autoconnect()

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let baseRadius = min(size.width, size.height) * 0.32

            // Three layers — each with different phase offsets for organic motion
            let layers: [(opacity: Double, radiusScale: CGFloat, phaseOffset: CGFloat, blur: CGFloat)] = [
                (0.25, 1.0,  0.0, 20),
                (0.18, 0.85, 2.1, 16),
                (0.12, 0.7,  4.2, 12),
            ]

            for layer in layers {
                let pointCount = 60
                var path = Path()

                for i in 0...pointCount {
                    let angle = (CGFloat(i) / CGFloat(pointCount)) * .pi * 2
                    // Organic noise from multiple sine waves
                    let noise1 = sin(angle * 3 + time * 1.2 + layer.phaseOffset) * 0.15
                    let noise2 = sin(angle * 5 + time * 0.8 + layer.phaseOffset * 1.5) * 0.08
                    let noise3 = cos(angle * 2 + time * 1.5 + layer.phaseOffset * 0.7) * 0.1
                    let r = baseRadius * layer.radiusScale * (1.0 + noise1 + noise2 + noise3)

                    let point = CGPoint(
                        x: center.x + cos(angle) * r,
                        y: center.y + sin(angle) * r
                    )
                    if i == 0 {
                        path.move(to: point)
                    } else {
                        path.addLine(to: point)
                    }
                }
                path.closeSubpath()

                context.drawLayer { layerContext in
                    layerContext.addFilter(.blur(radius: layer.blur))
                    layerContext.fill(
                        path,
                        with: .color(Color.tulaBrandFallback.opacity(layer.opacity))
                    )
                }
            }
        }
        .scaleEffect(breathing ? 1.05 : 0.95)
        .animation(
            .easeInOut(duration: 2.0).repeatForever(autoreverses: true),
            value: breathing
        )
        .shadow(color: Color.tulaBrandFallback.opacity(0.2), radius: 30)
        .onAppear { breathing = true }
        .onReceive(timer) { _ in
            time += 1.0 / 60.0
        }
    }
}

// MARK: - AudioRing (Circular Radial Visualizer)

/// 72-bar circular audio visualizer rendered with Canvas for 60fps.
/// Bars radiate outward from a circle. `barStrength` controls how much
/// the bars protrude — animate from 1.0 to 0.0 to morph into a smooth ring.
private struct AudioRing: View {
    let audioLevel: CGFloat
    let isActive: Bool
    let barStrength: CGFloat
    let accentColor: Color

    @State private var time: CGFloat = 0

    private let barCount = 72
    private let baseRadius: CGFloat = 80
    private let maxBarLength: CGFloat = 45

    private let timer = Timer.publish(
        every: 1.0 / 60.0, on: .main, in: .common
    ).autoconnect()

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let effectiveBarStrength = max(barStrength, 0)

            for i in 0..<barCount {
                let angle = (CGFloat(i) / CGFloat(barCount)) * .pi * 2 - .pi / 2
                let norm = CGFloat(i) / CGFloat(barCount)

                // Per-bar organic motion from dual sine waves
                let sine1 = sin(time * 2.5 + norm * .pi * 4) * 0.5 + 0.5
                let sine2 = sin(time * 1.7 + norm * .pi * 6) * 0.3 + 0.5

                // Audio-reactive component
                let audioBoost = audioLevel * (0.6 + sine1 * 0.4)

                // Final bar length
                let idleLength: CGFloat = 3 + (sine1 * 4 + sine2 * 2) * effectiveBarStrength
                let activeLength = idleLength + audioBoost * maxBarLength * effectiveBarStrength

                let barLength = isActive ? activeLength : idleLength

                // Ring stroke when bars are collapsed
                let ringStrokeWidth: CGFloat = 2 + (1 - effectiveBarStrength) * 1.5
                let effectiveLength = max(barLength, ringStrokeWidth)

                let innerRadius = baseRadius
                let outerRadius = baseRadius + effectiveLength

                let innerPoint = CGPoint(
                    x: center.x + cos(angle) * innerRadius,
                    y: center.y + sin(angle) * innerRadius
                )
                let outerPoint = CGPoint(
                    x: center.x + cos(angle) * outerRadius,
                    y: center.y + sin(angle) * outerRadius
                )

                var path = Path()
                path.move(to: innerPoint)
                path.addLine(to: outerPoint)

                // Opacity varies with bar length for depth
                let barOpacity = 0.4 + (effectiveLength / (maxBarLength + 3)) * 0.6
                let glowAmount = audioLevel * effectiveBarStrength * 0.5

                context.stroke(
                    path,
                    with: .color(accentColor.opacity(barOpacity + Double(glowAmount))),
                    lineWidth: 2.5
                )
            }

            // Center glow
            let glowRadius = baseRadius * 0.5
            let glowRect = CGRect(
                x: center.x - glowRadius,
                y: center.y - glowRadius,
                width: glowRadius * 2,
                height: glowRadius * 2
            )
            context.fill(
                Path(ellipseIn: glowRect),
                with: .color(accentColor.opacity(0.04 + Double(audioLevel) * 0.06))
            )
        }
        .shadow(color: accentColor.opacity(0.2 + Double(audioLevel) * 0.2), radius: 30)
        .onReceive(timer) { _ in
            if isActive || barStrength < 1.0 {
                time += 1.0 / 60.0
            }
        }
    }
}

// MARK: - Orbit Ring

/// Orbiting dots with a glowing center. Used during processing phase.
private struct OrbitRing: View {
    @State private var rotation: Double = 0

    private let dotCount = 8
    private let radius: CGFloat = 36

    var body: some View {
        ZStack {
            // Glowing center orb
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.tulaBrandFallback.opacity(0.5),
                            Color.tulaBrandFallback.opacity(0.0)
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 24
                    )
                )
                .frame(width: 48, height: 48)
                .blur(radius: 12)

            // Orbiting dots — comet tail effect
            ForEach(0..<dotCount, id: \.self) { i in
                let trail = 1.0 - (Double(i) / Double(dotCount)) * 0.75
                let size = 5.0 - (Double(i) / Double(dotCount)) * 2.5

                Circle()
                    .fill(Color.tulaBrandFallback)
                    .frame(width: size, height: size)
                    .offset(y: -radius)
                    .rotationEffect(
                        .degrees(
                            Double(i) / Double(dotCount) * 360 + rotation
                        )
                    )
                    .opacity(trail)
            }
        }
        .onAppear {
            withAnimation(
                .linear(duration: 1.5)
                    .repeatForever(autoreverses: false)
            ) {
                rotation = 360
            }
        }
    }
}

// MARK: - Pulsing Dot

private struct PulsingDot: View {
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 8, height: 8)
            .scaleEffect(pulse ? 1.3 : 1.0)
            .opacity(pulse ? 0.7 : 1.0)
            .shadow(color: .red.opacity(0.4), radius: 4)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 0.8)
                        .repeatForever(autoreverses: true)
                ) {
                    pulse = true
                }
            }
    }
}

// MARK: - Processing Dots

private struct ProcessingDots: View {
    @State private var activeIndex = 0

    private let timer = Timer.publish(
        every: 0.4, on: .main, in: .common
    ).autoconnect()

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(
                        Color.tulaBrandFallback
                            .opacity(i == activeIndex ? 0.8 : 0.2)
                    )
                    .frame(width: 5, height: 5)
                    .scaleEffect(i == activeIndex ? 1.3 : 1.0)
                    .animation(.easeInOut(duration: 0.3), value: activeIndex)
            }
        }
        .onReceive(timer) { _ in
            activeIndex = (activeIndex + 1) % 3
        }
    }
}

// MARK: - Flow Layout

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize,
                      subviews: Subviews,
                      cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect,
                       proposal: ProposedViewSize,
                       subviews: Subviews,
                       cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x,
                            y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(proposal: ProposedViewSize,
                         subviews: Subviews) -> ArrangeResult {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalSize: CGSize = .zero

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            totalSize.width = max(totalSize.width, x - spacing)
            totalSize.height = max(totalSize.height, y + rowHeight)
        }

        return ArrangeResult(positions: positions, size: totalSize)
    }

    private struct ArrangeResult {
        var positions: [CGPoint]
        var size: CGSize
    }
}

// MARK: - MerchantRuleResolver Helper

private extension MerchantRuleResolver {
    static func resolveFromRules(for merchant: String?,
                                  rules: [MerchantRule]) -> Category? {
        guard let merchant, !merchant.isEmpty else { return nil }
        let target = merchant.lowercased()
        return rules.first(where: { rule in
            target.contains(rule.pattern.lowercased())
        })?.category
    }
}
