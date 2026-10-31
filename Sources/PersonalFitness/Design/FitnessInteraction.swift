import SwiftUI
import UIKit

/// Haptics are part of the interface, not decoration: a set is only "done" when you can feel it.
///
/// Everything routes through here so the whole app uses one vocabulary — a light tap for a state
/// change, a success pattern for a completed set, a warning for a safety prompt. The device decides
/// whether it can deliver; nothing breaks when haptics are unavailable.
///
/// `UIImpactFeedbackGenerator` is prepared before use so the tap lands with the animation instead of
/// a few milliseconds after it, which is the difference between "feels connected" and "feels laggy".
enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let notify = UINotificationFeedbackGenerator()
    private static let selection = UISelectionFeedbackGenerator()

    /// Warm the generators up when a screen that will need them appears.
    static func prepare() {
        light.prepare(); medium.prepare(); rigid.prepare()
        notify.prepare(); selection.prepare()
    }

    /// A control responded: tab change, chip tap, small toggle.
    static func tap() {
        selection.selectionChanged()
        selection.prepare()
    }

    /// A set was completed. Slightly heavier than `tap` so it reads as progress, not as a click.
    static func setCompleted() {
        rigid.impactOccurred(intensity: 0.85)
        rigid.prepare()
    }

    /// A set was un-completed (undo). Deliberately softer: going backwards should feel lighter.
    static func setReverted() {
        light.impactOccurred(intensity: 0.6)
        light.prepare()
    }

    /// Rest ended, or a timer reached zero.
    static func timerDone() {
        notify.notificationOccurred(.success)
        notify.prepare()
    }

    /// Something needs attention: a safety question, a rejected action, a failed save.
    static func warning() {
        notify.notificationOccurred(.warning)
        notify.prepare()
    }

    /// A workout was saved.
    static func sessionSaved() {
        medium.impactOccurred(intensity: 0.9)
        notify.notificationOccurred(.success)
        medium.prepare(); notify.prepare()
    }
}

/// Plays a short success pattern when the value it is bound to changes from false to true, then
/// resets itself. Used by set rows and the finish button.
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
