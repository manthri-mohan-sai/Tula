//
//  Tula_WidgetLiveActivity.swift
//  Tula Widget
//

import ActivityKit
import SwiftUI
import WidgetKit

/// Lock Screen and Dynamic Island presentation of the day's spending.
///
/// **What it shows, and why.** Not a bare running total — that reads ~0 all
/// morning and is unactionable in the evening, because a number with no
/// reference point cannot be judged. The centrepiece is a pace track: spend
/// fills it, and a marker sits at what the daily budget says should have been
/// spent by now. Fill short of the marker means comfortable, fill past it
/// means running hot. Readable at a glance without reading any digits.
///
/// **Interaction.** A Live Activity cannot host a text field — ActivityKit has
/// no such affordance. The whole surface is one tap target into the app's
/// voice capture. Typing without opening the app happens on the *notification*
/// (`UNTextInputNotificationAction`), not here.
struct TulaSpendLiveActivity: Widget {

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TulaSpendActivityAttributes.self) { context in
            LockScreenView(
                state: context.state,
                currencyCode: context.attributes.currencyCode
            )
            .widgetURL(URL(string: "tula://voice"))

        } dynamicIsland: { context in
            IslandBuilder.build(
                state: context.state,
                currencyCode: context.attributes.currencyCode
            )
        }
    }
}

// MARK: - Style

/// The user's chosen theme accent, so the Lock Screen matches the app rather
/// than hardcoding one brand colour.
private var accent: Color { TulaTheme.current.color }

/// Green / accent / orange by pace, not by absolute spend. Spending a lot
/// early in a generous budget is fine; spending a little against a tight one
/// at 11pm is not.
private func paceColor(_ state: TulaSpendActivityAttributes.ContentState) -> Color {
    if state.isOverBudget { return .orange }
    if state.isAheadOfPace { return .yellow }
    return accent
}

private func paceGradient(_ state: TulaSpendActivityAttributes.ContentState) -> LinearGradient {
    let base: Color = paceColor(state)
    return LinearGradient(
        colors: [base.opacity(0.55), base],
        startPoint: .leading,
        endPoint: .trailing
    )
}

// MARK: - Lock Screen

private struct LockScreenView: View {
    let state: TulaSpendActivityAttributes.ContentState
    let currencyCode: String

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            amountRow
            PaceTrack(state: state)
            if let verdict = verdictText {
                Text(verdict)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    /// Identity strip. Brand mark, then the day's shape in words — the top
    /// category earns its place here as plain text rather than as a chip,
    /// which was chrome around content that did not need a container.
    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(accent)
                .frame(width: 6, height: 6)

            Text("TULA")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Text(contextLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var contextLabel: String {
        let count = state.expenseCount == 1 ? "1 expense" : "\(state.expenseCount) expenses"
        guard let category = state.topCategoryName else { return count }
        return "\(count) · \(category)"
    }

    /// Concrete number on the left, pace verdict on the right. The verdict is
    /// the interpretation the raw total cannot supply on its own.
    private var amountRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(Currency.format(state.todayTotal, code: currencyCode))
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)

            Spacer(minLength: 0)

            if let remaining = state.budgetRemaining {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(Currency.format(abs(remaining), code: currencyCode))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(paceColor(state))
                    Text(state.isOverBudget ? "over budget" : "left today")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// One short sentence naming the situation. Neutral throughout — the point
    /// is orientation, not reproach.
    private var verdictText: String? {
        guard let delta = state.paceDelta else { return nil }
        let amount = Currency.format(abs(delta), code: currencyCode)
        if state.isOverBudget { return "\(amount) over today's budget" }
        if state.isAheadOfPace { return "\(amount) ahead of pace for now" }
        if delta < 0 { return "\(amount) under pace for now" }
        return "On pace"
    }
}

// MARK: - Pace track

/// Spend fills the track; a marker sits at expected-by-now.
///
/// This is the whole idea of the activity in one control: the relationship
/// between the fill and the marker is the answer, and it needs no digits.
/// Without a budget there is no pace to show, so it degrades to a plain
/// divider rather than an empty or misleading bar.
private struct PaceTrack: View {
    let state: TulaSpendActivityAttributes.ContentState

    private let height: CGFloat = 7

    var body: some View {
        GeometryReader { geometry in
            let width: CGFloat = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.10))

                Capsule()
                    .fill(paceGradient(state))
                    .frame(width: width * state.budgetFraction)

                if let expected = state.expectedFraction {
                    marker(at: width * expected)
                }
            }
        }
        .frame(height: height + 6)
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
    }

    /// Thin notch rather than a dot: it has to read as a *position on the
    /// track*, and a dot floating over the fill reads as another data point.
    private func marker(at x: CGFloat) -> some View {
        Capsule()
            .fill(Color.primary.opacity(0.85))
            .frame(width: 2.5, height: height + 6)
            .offset(x: max(0, x - 1.25))
    }

    private var accessibilityText: String {
        guard state.paceDelta != nil else { return "Spending today" }
        if state.isOverBudget { return "Over today's budget" }
        if state.isAheadOfPace { return "Ahead of pace for this time of day" }
        return "On pace for this time of day"
    }
}

// MARK: - Dynamic Island

/// Built in a plain enum of small functions rather than inline in `body`.
///
/// `DynamicIsland` with four trailing closures plus nested view builders is a
/// large single expression, and this file already cost one "unable to
/// type-check in reasonable time" failure. One function per region keeps the
/// solver's work bounded.
private enum IslandBuilder {

    static func build(
        state: TulaSpendActivityAttributes.ContentState,
        currencyCode code: String
    ) -> DynamicIsland {
        DynamicIsland {
            DynamicIslandExpandedRegion(.leading) {
                leading()
            }
            DynamicIslandExpandedRegion(.trailing) {
                trailing(state: state)
            }
            DynamicIslandExpandedRegion(.bottom) {
                bottom(state: state, code: code)
            }
        } compactLeading: {
            Circle()
                .fill(paceColor(state))
                .frame(width: 8, height: 8)
        } compactTrailing: {
            Text(Currency.format(state.todayTotal, code: code))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(paceColor(state))
        } minimal: {
            Circle()
                .fill(paceColor(state))
                .frame(width: 8, height: 8)
        }
        .widgetURL(URL(string: "tula://voice"))
        .keylineTint(accent)
    }

    private static func leading() -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(accent)
                .frame(width: 6, height: 6)
            Text("TULA")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.0)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 4)
    }

    private static func trailing(
        state: TulaSpendActivityAttributes.ContentState
    ) -> some View {
        let label: String = state.expenseCount == 1
            ? "1 expense"
            : "\(state.expenseCount) expenses"
        return Text(label)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .padding(.trailing, 4)
    }

    private static func bottom(
        state: TulaSpendActivityAttributes.ContentState,
        code: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Currency.format(state.todayTotal, code: code))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)

                Spacer(minLength: 0)

                if let remaining = state.budgetRemaining {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(Currency.format(abs(remaining), code: code))
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(paceColor(state))
                        Text(state.isOverBudget ? "over budget" : "left today")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if state.dailyBudget != nil {
                PaceTrack(state: state)
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
    }
}
