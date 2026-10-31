import SwiftUI
import UIKit

/// Haptics are part of the interface, not decoration: a set is only "done" when you can feel it.
///
/// Everything routes through here so the whole app uses one vocabulary — a light tap for a state
/// change, a success pattern for a completed set, a warning for a safety prompt. The device decides
/// whether it can deliver; nothing breaks when haptics are unavailable.
///
/// Generators are prepared before use so the tap lands with the animation rather than a few
/// milliseconds after it, which is the difference between "feels connected" and "feels laggy".
///
/// `UIImpactFeedbackGenerator` is `@MainActor`-isolated, so the generators cannot be nonisolated
/// static stored properties. They live in a small reference holder created on first use and kept
/// alive between calls; the holder is only ever touched from `@MainActor` code.
private final class HapticStore: @unchecked Sendable {
    static let shared = HapticStore()
    var light: UIImpactFeedbackGenerator?
    var medium: UIImpactFeedbackGenerator?
    var rigid: UIImpactFeedbackGenerator?
    var notify: UINotificationFeedbackGenerator?
    var selection: UISelectionFeedbackGenerator?
}

@MainActor
enum Haptics {
    private static let store = HapticStore.shared

    private static func lightGenerator() -> UIImpactFeedbackGenerator {
        if let existing = store.light { return existing }
        let created = UIImpactFeedbackGenerator(style: .light); store.light = created; return created
    }
    private static func mediumGenerator() -> UIImpactFeedbackGenerator {
        if let existing = store.medium { return existing }
        let created = UIImpactFeedbackGenerator(style: .medium); store.medium = created; return created
    }
    private static func rigidGenerator() -> UIImpactFeedbackGenerator {
        if let existing = store.rigid { return existing }
        let created = UIImpactFeedbackGenerator(style: .rigid); store.rigid = created; return created
    }
    private static func notifyGenerator() -> UINotificationFeedbackGenerator {
        if let existing = store.notify { return existing }
        let created = UINotificationFeedbackGenerator(); store.notify = created; return created
    }
    private static func selectionGenerator() -> UISelectionFeedbackGenerator {
        if let existing = store.selection { return existing }
        let created = UISelectionFeedbackGenerator(); store.selection = created; return created
    }

    /// Warm the generators up when a screen that will need them appears.
    static func prepare() {
        lightGenerator().prepare(); mediumGenerator().prepare(); rigidGenerator().prepare()
        notifyGenerator().prepare(); selectionGenerator().prepare()
    }

    /// A control responded: tab change, chip tap, small toggle.
    static func tap() {
        let generator = selectionGenerator()
        generator.selectionChanged()
        generator.prepare()
    }

    /// A set was completed. Slightly heavier than `tap` so it reads as progress, not as a click.
    static func setCompleted() {
        let generator = rigidGenerator()
        generator.impactOccurred(intensity: 0.85)
        generator.prepare()
    }

    /// A set was un-completed (undo). Deliberately softer: going backwards should feel lighter.
    static func setReverted() {
        let generator = lightGenerator()
        generator.impactOccurred(intensity: 0.6)
        generator.prepare()
    }

    /// Rest ended, or a timer reached zero.
    static func timerDone() {
        let generator = notifyGenerator()
        generator.notificationOccurred(.success)
        generator.prepare()
    }

    /// Something needs attention: a safety question, a rejected action, a failed save.
    static func warning() {
        let generator = notifyGenerator()
        generator.notificationOccurred(.warning)
        generator.prepare()
    }

    /// A workout was saved: one solid impact plus the success pattern, in that order, so the
    /// completion is felt before the confirmation sound-like pattern.
    static func sessionSaved() {
        let impact = mediumGenerator()
        impact.impactOccurred(intensity: 0.9)
        let notification = notifyGenerator()
        notification.notificationOccurred(.success)
        impact.prepare(); notification.prepare()
    }
}

/// Plays a short success pattern when the value it is bound to changes from false to true, then
/// resets itself. Used by set rows and the finish button.
///
/// Marked `@MainActor` because `onChange` already runs on the main actor and the haptic generators
/// require it; this keeps the closure type honest instead of casting at the call site.
@MainActor
struct HapticOnCompletion: ViewModifier {
    let trigger: Bool
    let action: () -> Void
    @State private var last = false

    func body(content: Content) -> some View {
        content.onChange(of: trigger) { _, now in
            if now, !last { action() }
            last = now
        }
    }
}

extension View {
    /// Default action is a completed-set haptic; pass another for other transitions.
    func haptic(when trigger: Bool, _ action: @escaping () -> Void = Haptics.setCompleted) -> some View {
        modifier(HapticOnCompletion(trigger: trigger, action: action))
    }
}

/// A number that rolls to its new value instead of swapping instantly. `contentTransition` handles
/// the digits; the spring makes the roll feel weighted rather than mechanical.
struct RollingNumber: View {
    let value: Int
    var size: CGFloat = 26
    var weight: Font.Weight = .bold
    var color: Color = FitnessTheme.ink
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text("\(value)")
            .font(.system(size: size, weight: weight, design: .rounded))
            .foregroundStyle(color)
            .monospacedDigit()
            .contentTransition(reduceMotion ? .identity : .numericText(value: Double(value)))
            .animation(reduceMotion ? nil : FitnessTheme.Motion.state, value: value)
    }
}

/// A ring that fills to `progress` (0…1). Used for the weekly target and the rest countdown.
struct ProgressRing<Center: View>: View {
    let progress: Double
    var lineWidth: CGFloat = 3.5
    var tint: Color = FitnessTheme.accent
    var track: Color = FitnessTheme.line
    @ViewBuilder let center: () -> Center

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, min(1, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(FitnessTheme.Motion.state, value: progress)
            center()
        }
        .accessibilityHidden(true)
    }
}
