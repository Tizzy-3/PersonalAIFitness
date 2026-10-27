import SwiftUI
import UIKit
import FitnessCore

enum FitnessTheme {
    static let accent = adaptive(0x1967DF, 0x8EB8FF)
    static let accentInk = adaptive(0xFFFFFF, 0x10294D)
    static let canvas = adaptive(0xF3F6FA, 0x101720)
    static let surface = adaptive(0xFFFFFF, 0x1A2431)
    static let ink = adaptive(0x182335, 0xF2F5FA)
    static let muted = adaptive(0x6B778A, 0xA7B5C8)
    static let blueTint = adaptive(0xEAF2FF, 0x203452)
    static let teal = adaptive(0x16836C, 0x72D9BE)
    static let orange = adaptive(0xB65C1A, 0xF5B574)
    static let violet = adaptive(0x7455C9, 0xBCA8FF)
    static let success = teal
    static let cover = adaptive(0x184A94, 0x19365D)

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
}

struct FitnessPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(FitnessTheme.accentInk)
            .padding(.horizontal, 16).padding(.vertical, 13)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(FitnessTheme.accent.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 14))
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
