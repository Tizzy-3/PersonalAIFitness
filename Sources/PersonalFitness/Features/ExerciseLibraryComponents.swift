import SwiftUI
import FitnessCore

@MainActor
struct ExerciseLibraryCard: View {
    let exercise: Exercise
    let favorite: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var media: ExerciseMediaDescriptor? { ExerciseDetails.details(for: exercise.id)?.media }
    private var hasVideo: Bool {
        guard let media, media.kind == .video else { return false }
        return ExerciseMediaAsset.url(for: media.fileName) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let poster = ExerciseMediaAsset.poster(for: exercise.id) {
                        Image(uiImage: poster).resizable().scaledToFit().frame(maxWidth: .infinity)
                            .background(Color.white)
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: exercise.kind == .cardio ? "figure.walk" : exercise.kind == .bodyweight ? "figure.strengthtraining.functional" : "dumbbell")
                                .font(.largeTitle.weight(.light)).foregroundStyle(FitnessTheme.accent.opacity(0.8))
                            Text("暂无示范素材").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(FitnessTheme.canvas)
                    }
                }
                .frame(height: dynamicTypeSize.isAccessibilitySize ? 150 : 106)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                if hasVideo {
                    Image(systemName: "play.fill").font(.caption2.weight(.semibold))
                        .foregroundStyle(FitnessTheme.accent).padding(.horizontal, 9).padding(.vertical, 6)
                        .background(FitnessTheme.blueTint, in: RoundedRectangle(cornerRadius: 6))
                        .padding(4)
                }
                if favorite {
                    Image(systemName: "star.fill").font(.caption).foregroundStyle(FitnessTheme.orange)
                        .padding(7).background(FitnessTheme.surface, in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(3)
                }
            }.accessibilityHidden(true)
            Text(exercise.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(exercise.muscle) · \(exercise.equipment)")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            if exercise.isCustom {
                Text("自定义").font(.caption2.weight(.medium)).foregroundStyle(FitnessTheme.teal)
            } else if let media, media.kind != .video {
                Label("静态图示\((media.stillImages?.count ?? 1) > 1 ? " · 多图" : "")", systemImage: "photo")
                    .font(.caption2).foregroundStyle(FitnessTheme.teal)
            }
        }
        .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(FitnessTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityValue(favorite ? "已收藏" : "未收藏")
        .accessibilityHint(hasVideo ? "打开动作资料和离线示范短片" : media == nil ? "打开动作资料；尚无示范素材" : "打开静态动作图示；不是视频或动图")
    }
}

struct ExerciseInstructionRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(String(number)).font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(FitnessTheme.accent).frame(minWidth: 28, minHeight: 28)
                .background(FitnessTheme.blueTint, in: RoundedRectangle(cornerRadius: 8))
            Text(text).font(.body).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 3)
        }.padding(.vertical, 4).accessibilityElement(children: .combine)
    }
}
