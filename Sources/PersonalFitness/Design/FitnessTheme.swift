import SwiftUI
import UIKit
import FitnessCore

/// The visual system: warm paper, one terracotta signal colour, generous rounding.
///
/// Token names are unchanged from earlier versions on purpose. Every screen already refers to
/// `accent` / `canvas` / `ink` / …, so retuning the values here moves the whole app at once instead
/// of editing 140+ call sites and leaving half of them inconsistent.
///
/// Light is the primary design. Dark is a warm-brown counterpart, not a colour inversion: a pure
/// inversion of warm paper reads as cold grey, which is the exact thing the light theme avoids.
enum FitnessTheme {

    // MARK: - Core palette

    /// Primary action and the coach's voice.
    static let accent = adaptive(0xE8734A, 0xF0855C)
    /// Text on top of `accent`.
    static let accentInk = adaptive(0xFFFFFF, 0x2A1A14)
    /// Page background: warm paper, not grey.
    static let canvas = adaptive(0xFAF6F1, 0x17130F)
    /// Raised surface: cards sit on the paper.
    static let surface = adaptive(0xFFFFFF, 0x231D18)
    /// Primary text: warm near-black, never pure black.
    static let ink = adaptive(0x2A2320, 0xF5EFE8)
    /// Secondary text.
    static let muted = adaptive(0x7A6A5E, 0xB5A79A)
    /// Tertiary text, metadata, captions.
    static let faint = adaptive(0xA89789, 0x8A7C6F)
    /// Tinted fill behind accent-coloured content.
    static let blueTint = adaptive(0xFBE4DA, 0x35251D)
    /// Quiet fill for thumbnails and input wells.
    static let sunken = adaptive(0xF5EEE6, 0x2C241E)
    /// Hairline separator.
    static let line = adaptive(0xEDE3D8, 0x362D26)

    /// Success, recovery, "done" states. A muted sage, not a saturated green.
    static let teal = adaptive(0x6E9373, 0x8FB894)
    static let tealTint = adaptive(0xE4EEE4, 0x24301F)

    /// Caution. Deliberately darker and redder than `accent`, so the two never read as the same
    /// signal: terracotta means "your coach is talking", this means "stop and read".
    static let orange = adaptive(0xC2410C, 0xE8916B)
    static let orangeTint = adaptive(0xFDE8E0, 0x3A2418)

    /// Coach-adjacent accents (suggestions, adjustment cards).
    static let violet = adaptive(0x9A6B8F, 0xC79BB8)
    static let violetTint = adaptive(0xF4E9F0, 0x33222E)

    static let success = teal
    static let cover = adaptive(0x8B5A3C, 0x4A3327)

    // MARK: - Shape and depth

    /// Corner radii. Larger than a stock iOS card; some of the warmth comes from softness.
    enum Radius {
        static let chip: CGFloat = 12
        static let control: CGFloat = 14
        static let card: CGFloat = 20
        static let sheet: CGFloat = 26
    }

    /// One shadow recipe used everywhere: a tight contact shadow plus a wide soft one. That pair is
    /// what makes a card look lifted rather than merely outlined.
    static var cardShadow: Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0, green: 0, blue: 0, alpha: 0.42)
                : UIColor(red: 0.47, green: 0.37, blue: 0.27, alpha: 0.09)
        })
    }

    // MARK: - Motion

    /// Short and consistent: quick for state, state for toggles, layout for reflow, celebrate for
    /// a completed set or a finished session.
    enum Motion {
        static let quick = Animation.easeOut(duration: 0.18)
        static let state = Animation.spring(response: 0.32, dampingFraction: 0.72)
        static let layout = Animation.spring(response: 0.42, dampingFraction: 0.82)
        static let celebrate = Animation.spring(response: 0.5, dampingFraction: 0.6)
    }

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
}

/// The primary action: a filled terracotta pill with a soft cast, and a press that compresses rather
/// than only dimming — the button should feel like a physical control.
struct FitnessPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold, design: .rounded))
            .foregroundStyle(FitnessTheme.accentInk)
            .padding(.horizontal, 18).padding(.vertical, 15)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(FitnessTheme.accent.opacity(isEnabled ? 1 : 0.38))
                    .shadow(color: FitnessTheme.accent.opacity(isEnabled ? 0.28 : 0),
                            radius: 14, y: 6)
            )
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(FitnessTheme.Motion.quick, value: configuration.isPressed)
    }
}

/// Secondary action: paper-coloured with a hairline, so it never competes with the primary.
struct FitnessSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold, design: .rounded))
            .foregroundStyle(FitnessTheme.ink)
            .padding(.horizontal, 16).padding(.vertical, 13)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(FitnessTheme.surface)
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(FitnessTheme.line, lineWidth: 1))
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(FitnessTheme.Motion.quick, value: configuration.isPressed)
    }
}

/// A card that matches the mockup: white surface, 20pt radius, one shared shadow.
struct FitnessCard<Content: View>: View {
    var padding: CGFloat = 18
    private let content: Content
    init(padding: CGFloat = 18, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }
    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: FitnessTheme.Radius.card, style: .continuous)
                    .fill(FitnessTheme.surface)
                    .shadow(color: FitnessTheme.cardShadow, radius: 11, y: 5)
            )
    }
}


@MainActor
struct ExerciseTile: View {
    let exercise: Exercise
    var size: CGFloat = 48
    var animated: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if animated, !reduceMotion, scenePhase == .active,
                   let gif = ExerciseDetails.details(for: exercise.id)?.media?.previewGIFFileName {
                    ExerciseAnimatedThumbnail(fileName: gif, poster: ExerciseMediaAsset.poster(for: exercise.id))
                        .background(Color.white)
                } else if let poster = ExerciseMediaAsset.poster(for: exercise.id) {
                    Image(uiImage: poster).resizable().scaledToFit().background(Color.white)
                } else {
                    ZStack {
                        FitnessTheme.blueTint
                        Image(systemName: exercise.kind == .cardio ? "figure.walk" : exercise.kind == .bodyweight ? "figure.strengthtraining.functional" : "dumbbell")
                            .font(.system(size: size * 0.38, weight: .medium)).foregroundStyle(FitnessTheme.accent)
                    }
                }
            }.frame(width: size, height: size)
            if ExerciseDetails.details(for: exercise.id)?.media?.kind == .video {
                Image(systemName: "play.circle.fill").font(.caption2).foregroundStyle(.white, .black).padding(2)
            }
        }
        .frame(width: size, height: size)
        .background(FitnessTheme.canvas, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
    }
}

struct FitnessIconBadge: View {
    let symbol: String
    var color: Color = FitnessTheme.accent
    var body: some View {
        Image(systemName: symbol).font(.system(size: 19, weight: .semibold))
            .foregroundStyle(color).frame(width: 42, height: 42)
            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityHidden(true)
    }
}

struct FitnessSectionHeading: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline).foregroundStyle(FitnessTheme.ink)
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(FitnessTheme.muted) }
        }
    }
}

extension View {
    func fitnessError(_ issue: Binding<String?>) -> some View {
        alert("操作未完成", isPresented: Binding(
            get: { issue.wrappedValue != nil },
            set: { if !$0 { issue.wrappedValue = nil } }
        )) {
            Button("知道了", role: .cancel) { issue.wrappedValue = nil }
        } message: {
            Text(issue.wrappedValue ?? "请重试。")
        }
    }
}

enum UIInput {
    struct Invalid: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func double(_ text: String, label: String) throws -> Double? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard let number = Double(value.replacingOccurrences(of: ",", with: ".")), number.isFinite else {
            throw Invalid(message: "\(label)请输入有效数字，不能把无效输入当作零。")
        }
        return number
    }

    static func integer(_ text: String, label: String) throws -> Int? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard let number = Int(value) else { throw Invalid(message: "\(label)请输入整数。") }
        return number
    }

    static func number(_ value: Double?) -> String {
        guard let value else { return "" }
        return value.formatted(.number.precision(.fractionLength(0...2)).grouping(.never))
    }

    static func duration(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0, interval < Double(Int.max) else { return "超出显示范围" }
        let seconds = Int(interval)
        return seconds >= 3_600
            ? "\(seconds / 3_600):" + String(format: "%02d:%02d", seconds / 60 % 60, seconds % 60)
            : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
