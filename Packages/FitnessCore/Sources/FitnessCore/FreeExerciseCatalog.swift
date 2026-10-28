import Foundation

/// A separately identified source demonstration. Labels describe the demonstrator, not suitability.
public struct ExerciseDemonstrationVariant: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let media: ExerciseMediaDescriptor
    public init(id: String, label: String, media: ExerciseMediaDescriptor) {
        self.id = id; self.label = label; self.media = media
    }
}

public struct FreeExerciseSourceRecord: Codable, Equatable, Sendable {
    public let sourceID: String
    public let exerciseID: String
    public let isNew: Bool
    public let name: String
    public let englishName: String
    public let kind: TrainingKind
    public let metric: RecordingMetric
    public let equipment: String
    public let muscle: String
    public let loadConvention: LoadConvention
    public let aliases: [String]
    public let secondaryMuscles: [String]
    public let movementPattern: String
    public let difficulty: String
    public let steps: [String]
    public let commonMistakes: [String]
    public let originalInstructions: String
    public let formCues: [String]
    public let breathing: String
    public let videos: [String: String]
    public let thumbnails: [String: String]
    public let sourceURL: String
    public let metadataLicense: String
    public let videoAuthorizationBasis: String

    public var demonstrations: [ExerciseDemonstrationVariant] {
        ["male", "female"].compactMap { variant in
            guard let source = videos[variant] else { return nil }
            let stem = "fed-\(sourceID)-\(variant)"
            let media = ExerciseMediaDescriptor(kind: .video, fileName: stem + ".mp4",
                posterFileName: stem + ".jpg", previewGIFFileName: stem + ".gif",
                sourceURL: source, author: "free-exercise-db-api 素材提供者",
                licenseName: "视频使用由本人确认", licenseURL: "https://github.com/luisaraujoc/free-exercise-db-api#credits",
                changes: "由本人确认接入；上游维护者自述来源保留。完整短片转为480px以内H.264静音MP4，连续片段生成160px GIF，封面缩放；非完整教学课程。",
                durationSeconds: nil)
            return ExerciseDemonstrationVariant(id: sourceID + "." + variant,
                label: variant == "male" ? "男示范" : "女示范", media: media)
        }
    }

    var exercise: Exercise {
        Exercise(id: exerciseID, name: name, englishName: englishName, kind: kind, metric: metric,
            equipment: equipment, muscle: muscle, loadConvention: loadConvention,
            instructions: ["以下保留上游英文步骤；该来源教学由维护者生成整理，未完成逐项中文教学审校，不是本人限制下的运动许可。"] + steps)
    }

    var detail: ExerciseDetail {
        ExerciseDetail(aliases: aliases, secondaryMuscles: secondaryMuscles.filter { $0 != muscle },
            movementPattern: movementPattern, difficulty: difficulty,
            commonMistakes: ["以下为上游英文常见错误提示。"] + commonMistakes,
            alternativeIDs: [], progressionIDs: [], media: demonstrations.first?.media)
    }

    var contentSource: ExerciseContentSource {
        ExerciseContentSource(title: englishName, url: sourceURL, author: "Arham Wani / free-exercise-db-api",
            licenseName: metadataLicense, licenseURL: "https://github.com/luisaraujoc/free-exercise-db-api/blob/main/LICENSE",
            originalDescription: originalInstructions)
    }
}

/// Complete pinned upstream metadata. Names/mappings are reviewed separately from generated guidance.
/// New variants are available for manual plans, but are not automatically admitted to PlannerEngine.
public enum FreeExerciseCatalog {
    public static let sourceDatasetSHA256 = "4f6e887b23e88ebcd71d510947bda839dfb7caf6876c2381b0309188ea56b48e"
    private struct Document: Decodable { let formatVersion: Int; let sourceDatasetSHA256: String; let records: [FreeExerciseSourceRecord] }

    public static let records: [FreeExerciseSourceRecord] = {
        guard let url = Bundle.module.url(forResource: "free-exercise-catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url), let document = try? JSONDecoder().decode(Document.self, from: data),
              document.formatVersion == 1, document.sourceDatasetSHA256 == sourceDatasetSHA256,
              document.records.count == 317 else {
            preconditionFailure("Bundled exercise source catalog is missing or invalid.")
        }
        return document.records
    }()

    private static let grouped = Dictionary(grouping: records, by: \.exerciseID)
    public static let sourceToExerciseID = Dictionary(uniqueKeysWithValues: records.map { ($0.sourceID, $0.exerciseID) })
    public static let exercises: [Exercise] = records.filter(\.isNew).map(\.exercise)
    static let details = Dictionary(uniqueKeysWithValues: records.filter(\.isNew).map { ($0.exerciseID, $0.detail) })
    static let sources = Dictionary(uniqueKeysWithValues: records.map { ($0.exerciseID, $0.contentSource) })

    public static func mediaVariants(for exerciseID: String) -> [ExerciseDemonstrationVariant] {
        (grouped[exerciseID] ?? []).flatMap(\.demonstrations)
    }

    public static func sourceRecords(for exerciseID: String) -> [FreeExerciseSourceRecord] { grouped[exerciseID] ?? [] }
}
