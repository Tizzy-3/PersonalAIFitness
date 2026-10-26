import SwiftUI
import AVKit
import FitnessCore

@MainActor
enum ExerciseMediaAsset {
    private static var posters: [String: UIImage] = [:]

    static func url(for fileName: String) -> URL? {
        guard !fileName.contains("/"), !fileName.contains("\\"), !fileName.contains("..") else { return nil }
        return Bundle.main.url(forResource: fileName, withExtension: nil, subdirectory: "ExerciseMedia")
    }

    static func poster(for exerciseID: String) -> UIImage? {
        guard let media = ExerciseDetails.details(for: exerciseID)?.media else { return nil }
        if let cached = posters[media.posterFileName] { return cached }
        guard let url = url(for: media.posterFileName), let image = UIImage(contentsOfFile: url.path) else { return nil }
        posters[media.posterFileName] = image
        return image
    }
}

/// A small licensed source clip, not a full teaching lesson or an AI-generated animation.
@MainActor
struct ExerciseDemonstrationView: View {
    let exerciseID: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
    @State private var showingPlayer = false

    private var media: ExerciseMediaDescriptor? { ExerciseDetails.details(for: exerciseID)?.media }

    var body: some View {
        if let media, let fileURL = ExerciseMediaAsset.url(for: media.fileName) {
            VStack(alignment: .leading, spacing: 9) {
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if media.kind == .video, !reduceMotion, let player {
                            VideoPlayer(player: player).allowsHitTesting(false)
                        } else if let poster = ExerciseMediaAsset.poster(for: exerciseID) {
                            Image(uiImage: poster).resizable().scaledToFit().frame(maxWidth: .infinity)
                        }
                    }
                    .frame(maxWidth: .infinity).frame(height: 220)
                    .background(Color.white)
                    if media.kind == .video {
                        Button { showingPlayer = true } label: {
                            Label("播放示范短片", systemImage: "play.fill")
                                .font(.subheadline.weight(.semibold)).padding(12)
                                .foregroundStyle(.white).background(.black.opacity(0.75), in: Capsule())
                        }.buttonStyle(.plain).padding(12)
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 14))
                Text(media.kind == .video ? "离线示范短片 · 可循环预览 · 非完整教学" : "离线动作图示 · 静态图片")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .task(id: media.fileName) { configure(media: media, url: fileURL) }
            .onChange(of: reduceMotion) { _, _ in configure(media: media, url: fileURL) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, !reduceMotion, !showingPlayer { player?.play() } else { player?.pause() }
            }
            .onChange(of: showingPlayer) { _, showing in
                if showing { player?.pause() } else if !reduceMotion, scenePhase == .active { player?.play() }
            }
            .onDisappear { stop() }
            .sheet(isPresented: $showingPlayer) {
                NavigationStack { ExerciseFullPlayer(url: fileURL) }
            }
        } else {
            Label("这个动作暂未提供已核验的示范素材", systemImage: "video.slash")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func configure(media: ExerciseMediaDescriptor, url: URL) {
        stop()
        guard media.kind == .video, !reduceMotion, scenePhase == .active else { return }
        let queue = AVQueuePlayer()
        queue.isMuted = true
        looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url))
        player = queue
        queue.play()
    }

    private func stop() {
        player?.pause()
        looper?.disableLooping()
        player?.removeAllItems()
        looper = nil
        player = nil
    }
}

@MainActor
private struct ExerciseFullPlayer: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .navigationTitle("动作示范短片").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onAppear { let value = AVPlayer(url: url); player = value; value.play() }
            .onDisappear { player?.pause(); player = nil }
    }
}
