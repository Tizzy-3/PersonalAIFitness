import SwiftUI
import FitnessCore

enum FitnessTheme {
    static let accent = Color(red: 0.84, green: 0.96, blue: 0.37)
    static let accentInk = Color(red: 0.10, green: 0.16, blue: 0.04)
    static let canvas = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let success = Color(uiColor: .systemGreen)
    static let cover = Color(red: 0.11, green: 0.15, blue: 0.12)
}

struct FitnessPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(FitnessTheme.accentInk)
            .frame(maxWidth: .infinity, minHeight: 52)
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
                    Image(systemName: exercise.kind == .cardio ? "figure.walk" : exercise.kind == .bodyweight ? "figure.strengthtraining.functional" : "dumbbell")
                        .font(.system(size: size * 0.42, weight: .medium)).foregroundStyle(.secondary)
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
