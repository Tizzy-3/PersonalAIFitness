import Foundation

public struct ExerciseStillFrame: Codable, Equatable, Sendable {
    public let fileName: String
    public let sourceURL: String
    public let author: String
    public let licenseName: String
    public let licenseURL: String
    public let caption: String
}

public struct ExerciseContentSource: Codable, Equatable, Sendable {
    public let title: String
    public let url: String
    public let author: String
    public let licenseName: String
    public let licenseURL: String
    public let originalDescription: String
}

public struct ExerciseMediaDescriptor: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case image, video, stillSequence }
    public let kind: Kind
    public let fileName: String
    public let posterFileName: String
    public let previewGIFFileName: String?
    public let sourceURL: String
    public let author: String
    public let licenseName: String
    public let licenseURL: String
    public let changes: String
    public let durationSeconds: Double?
    public let stillImages: [ExerciseStillFrame]?

    public init(kind: Kind, fileName: String, posterFileName: String, previewGIFFileName: String?, sourceURL: String,
                author: String, licenseName: String, licenseURL: String, changes: String, durationSeconds: Double?,
                stillImages: [ExerciseStillFrame]? = nil) {
        self.kind = kind; self.fileName = fileName; self.posterFileName = posterFileName
        self.previewGIFFileName = previewGIFFileName; self.sourceURL = sourceURL; self.author = author
        self.licenseName = licenseName; self.licenseURL = licenseURL; self.changes = changes
        self.durationSeconds = durationSeconds; self.stillImages = stillImages
    }
}

public struct ExerciseDetail: Codable, Equatable, Sendable {
    public let aliases: [String]
    public let secondaryMuscles: [String]
    public let movementPattern: String
    public let difficulty: String
    public let commonMistakes: [String]
    public let alternativeIDs: [String]
    public let progressionIDs: [String]
    public let media: ExerciseMediaDescriptor?
}

/// Authored general movement notes, not a personal suitability assessment.
/// Licensed media is attributed individually and is never labelled full instruction.
public enum ExerciseDetails {
    public static func details(for id: String) -> ExerciseDetail? { entries[id] }
    public static func contentSource(for id: String) -> ExerciseContentSource? {
        ExpandedExerciseCatalog.sources[id] ?? MotionExerciseCatalog.sources[id]
    }

    public static func matches(_ exercise: Exercise, query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let detail = details(for: exercise.id)
        let searchable = ([exercise.name, exercise.englishName, exercise.muscle, exercise.equipment,
                           detail?.movementPattern ?? ""] + (detail?.aliases ?? []) + (detail?.secondaryMuscles ?? [])).joined(separator: " ")
        return words.allSatisfy { searchable.localizedCaseInsensitiveContains($0) }
    }

    public static let entries: [String: ExerciseDetail] = {
        var result = baseEntries.merging(ExpandedExerciseCatalog.details) { original, _ in original }
        for (id, media) in ExpandedExerciseCatalog.legacyMedia {
            guard let value = result[id], value.media == nil else { continue }
            result[id] = ExerciseDetail(aliases: value.aliases, secondaryMuscles: value.secondaryMuscles,
                movementPattern: value.movementPattern, difficulty: value.difficulty,
                commonMistakes: value.commonMistakes, alternativeIDs: value.alternativeIDs,
                progressionIDs: value.progressionIDs, media: media)
        }
        result.merge(MotionExerciseCatalog.details) { original, _ in original }
        for (id, media) in MotionMediaCatalog.entries {
            guard let value = result[id] else { continue }
            result[id] = ExerciseDetail(aliases: value.aliases, secondaryMuscles: value.secondaryMuscles,
                movementPattern: value.movementPattern, difficulty: value.difficulty,
                commonMistakes: value.commonMistakes, alternativeIDs: value.alternativeIDs,
                progressionIDs: value.progressionIDs, media: media)
        }
        return result
    }()

    private static let baseEntries: [String: ExerciseDetail] = [
        "builtin.dumbbell-bench-press": ExerciseDetail(aliases: ["平板哑铃卧推", "哑铃推胸"], secondaryMuscles: ["肱三头肌", "肩前束"], movementPattern: "水平推", difficulty: "基础", commonMistakes: ["下放失控、弹起借力。", "过度耸肩或手腕明显后折。"], alternativeIDs: ["builtin.barbell-bench-press", "builtin.push-up"], progressionIDs: [], media: ExerciseMediaDescriptor(kind: .video, fileName: "dumbbell-bench-press.mp4", posterFileName: "dumbbell-bench-press-poster.jpg", previewGIFFileName: "dumbbell-bench-press.gif", sourceURL: "https://wger.de/media/exercise-video/75/080c799b-8afd-4130-8d72-9cef0cd79f54.MOV", author: "Goulart", licenseName: "CC-BY-SA 4", licenseURL: "https://creativecommons.org/licenses/by-sa/4.0/deed.en", changes: "Re-encoded to 480px H.264 MP4 without audio; poster extracted from the source. The derivative is licensed under the same CC BY-SA 4.0. A centered continuous segment up to 6 seconds is converted to a 160px/6fps looping GIF preview; poster extracted from the midpoint.", durationSeconds: 14.16)),
        "builtin.incline-dumbbell-press": ExerciseDetail(aliases: ["上斜哑铃推胸"], secondaryMuscles: ["肩前束", "肱三头肌"], movementPattern: "斜向推", difficulty: "基础", commonMistakes: ["凳角度过大却强行当作胸部动作。", "腰部过度反弓、下放过深。"], alternativeIDs: ["builtin.dumbbell-bench-press", "builtin.incline-barbell-press"], progressionIDs: [], media: ExerciseMediaDescriptor(kind: .video, fileName: "incline-dumbbell-press.mp4", posterFileName: "incline-dumbbell-press-poster.jpg", previewGIFFileName: "incline-dumbbell-press.gif", sourceURL: "https://wger.de/media/exercise-video/537/b9c937e9-daeb-42a9-be8e-7a77e368478c.MOV", author: "Goulart", licenseName: "CC-BY-SA 4", licenseURL: "https://creativecommons.org/licenses/by-sa/4.0/deed.en", changes: "Re-encoded to 480px H.264 MP4 without audio; poster extracted from the source. The derivative is licensed under the same CC BY-SA 4.0. A centered continuous segment up to 6 seconds is converted to a 160px/6fps looping GIF preview; poster extracted from the midpoint.", durationSeconds: 27.49)),
        "builtin.dumbbell-shoulder-press": ExerciseDetail(aliases: ["哑铃推肩", "坐姿哑铃推举"], secondaryMuscles: ["肱三头肌", "核心"], movementPattern: "垂直推", difficulty: "基础", commonMistakes: ["肋骨外翻、明显后仰。", "耸肩或突然失控下落。"], alternativeIDs: ["builtin.machine-shoulder-press", "builtin.incline-push-up"], progressionIDs: [], media: ExerciseMediaDescriptor(kind: .video, fileName: "dumbbell-shoulder-press.mp4", posterFileName: "dumbbell-shoulder-press-poster.jpg", previewGIFFileName: "dumbbell-shoulder-press.gif", sourceURL: "https://wger.de/media/exercise-video/567/64f33c19-1d96-4b7c-af17-6c6a4941c614.MOV", author: "Goulart", licenseName: "CC-BY-SA 4", licenseURL: "https://creativecommons.org/licenses/by-sa/4.0/deed.en", changes: "Re-encoded to 480px H.264 MP4 without audio; poster extracted from the source. The derivative is licensed under the same CC BY-SA 4.0. A centered continuous segment up to 6 seconds is converted to a 160px/6fps looping GIF preview; poster extracted from the midpoint.", durationSeconds: 23.13)),
        "builtin.dumbbell-row": ExerciseDetail(aliases: ["单臂划船", "哑铃单手划船"], secondaryMuscles: ["肱二头肌", "肩后束"], movementPattern: "水平拉", difficulty: "基础", commonMistakes: ["用躯干旋转甩起重量。", "只耸肩、不让上臂后移。"], alternativeIDs: ["builtin.seated-cable-row", "builtin.chest-supported-row"], progressionIDs: [], media: nil),
        "builtin.lat-pulldown": ExerciseDetail(aliases: ["背部下拉", "下拉"], secondaryMuscles: ["肱二头肌", "肩后束"], movementPattern: "垂直拉", difficulty: "基础", commonMistakes: ["拉到颈后或强拉至疼痛范围。", "用身体猛然后仰借力。"], alternativeIDs: ["builtin.assisted-pull-up", "builtin.band-pulldown"], progressionIDs: [], media: nil),
        "builtin.goblet-squat": ExerciseDetail(aliases: ["杯式深蹲", "抱铃深蹲"], secondaryMuscles: ["臀部", "核心"], movementPattern: "蹲", difficulty: "基础", commonMistakes: ["脚跟离地或膝盖失控内扣。", "为追求深度而腰背明显塌陷。"], alternativeIDs: ["builtin.bodyweight-squat", "builtin.leg-press"], progressionIDs: ["builtin.barbell-back-squat"], media: nil),
        "builtin.dumbbell-rdl": ExerciseDetail(aliases: ["哑铃RDL", "直腿硬拉（微屈膝）"], secondaryMuscles: ["竖脊肌", "核心"], movementPattern: "髋铰链", difficulty: "基础", commonMistakes: ["把髋铰链做成下蹲。", "圆背、耸肩或哑铃远离身体。"], alternativeIDs: ["builtin.barbell-rdl", "builtin.glute-bridge"], progressionIDs: [], media: nil),
        "builtin.dumbbell-curl": ExerciseDetail(aliases: ["哑铃二头弯举"], secondaryMuscles: ["前臂"], movementPattern: "肘屈", difficulty: "基础", commonMistakes: ["甩腰借力。", "肘部大幅前移、手腕过屈。"], alternativeIDs: ["builtin.hammer-curl", "builtin.barbell-curl"], progressionIDs: [], media: ExerciseMediaDescriptor(kind: .video, fileName: "dumbbell-curl.mp4", posterFileName: "dumbbell-curl-poster.jpg", previewGIFFileName: "dumbbell-curl.gif", sourceURL: "https://wger.de/media/exercise-video/92/8bfb917c-3d0d-49b9-8073-5d7e01c1b894.MOV", author: "Goulart", licenseName: "CC-BY-SA 4", licenseURL: "https://creativecommons.org/licenses/by-sa/4.0/deed.en", changes: "Re-encoded to 480px H.264 MP4 without audio; poster extracted from the source. The derivative is licensed under the same CC BY-SA 4.0. A centered continuous segment up to 6 seconds is converted to a 160px/6fps looping GIF preview; poster extracted from the midpoint.", durationSeconds: 10.94)),
        "builtin.assisted-pull-up": ExerciseDetail(aliases: ["助力引体", "器械引体"], secondaryMuscles: ["肱二头肌", "核心"], movementPattern: "垂直拉", difficulty: "基础", commonMistakes: ["突然离开支撑垫。", "摆动借力或误把辅助重量当成外加负重。"], alternativeIDs: ["builtin.lat-pulldown", "builtin.band-pulldown"], progressionIDs: ["builtin.pull-up"], media: nil),
        "builtin.push-up": ExerciseDetail(aliases: ["伏地挺身"], secondaryMuscles: ["肱三头肌", "核心"], movementPattern: "水平推", difficulty: "基础", commonMistakes: ["塌腰或头部前探。", "肘部完全向侧面张开。"], alternativeIDs: ["builtin.incline-push-up", "builtin.knee-push-up"], progressionIDs: ["builtin.diamond-push-up"], media: nil),
        "builtin.bodyweight-squat": ExerciseDetail(aliases: ["自重深蹲"], secondaryMuscles: ["臀部", "核心"], movementPattern: "蹲", difficulty: "基础", commonMistakes: ["为追求深度而失去足底支撑。", "膝盖突然内扣。"], alternativeIDs: ["builtin.box-squat", "builtin.goblet-squat"], progressionIDs: ["builtin.goblet-squat"], media: nil),
        "builtin.plank": ExerciseDetail(aliases: ["肘撑平板"], secondaryMuscles: ["肩部", "臀部"], movementPattern: "抗伸展", difficulty: "基础", commonMistakes: ["憋气或腰部持续下塌。", "只追求更长时间而忽略姿势。"], alternativeIDs: ["builtin.dead-bug", "builtin.bird-dog"], progressionIDs: ["builtin.side-plank"], media: nil),
        "builtin.walking": ExerciseDetail(aliases: ["快走", "走路"], secondaryMuscles: ["腿部"], movementPattern: "步行", difficulty: "基础", commonMistakes: ["突然大幅增加距离。", "疼痛时继续加速。"], alternativeIDs: ["builtin.stationary-cycling", "builtin.elliptical"], progressionIDs: [], media: nil),
        "builtin.running": ExerciseDetail(aliases: ["慢跑", "户外跑", "跑步机"], secondaryMuscles: ["腿部", "核心"], movementPattern: "跑", difficulty: "基础", commonMistakes: ["一开始就冲刺。", "疲劳或疼痛时勉强保持速度。"], alternativeIDs: ["builtin.walking", "builtin.stationary-cycling"], progressionIDs: [], media: nil),
        "builtin.cycling": ExerciseDetail(aliases: ["自行车", "单车"], secondaryMuscles: ["心肺"], movementPattern: "骑行", difficulty: "基础", commonMistakes: ["车座设置导致明显不适仍继续。", "在疲劳时使用过大阻力。"], alternativeIDs: ["builtin.stationary-cycling", "builtin.walking"], progressionIDs: [], media: nil),
        "builtin.barbell-bench-press": ExerciseDetail(aliases: ["平板杠铃卧推", "卧推"], secondaryMuscles: ["肱三头肌", "肩前束"], movementPattern: "水平推", difficulty: "基础", commonMistakes: ["无保护尝试无法控制的重量。", "杠铃弹胸或臀部明显离凳。"], alternativeIDs: ["builtin.dumbbell-bench-press", "builtin.push-up"], progressionIDs: [], media: ExerciseMediaDescriptor(kind: .video, fileName: "barbell-bench-press.mp4", posterFileName: "barbell-bench-press-poster.jpg", previewGIFFileName: "barbell-bench-press.gif", sourceURL: "https://wger.de/media/exercise-video/73/2bdb390c-312c-4497-a722-5eed2c823e5a.MOV", author: "Goulart", licenseName: "CC-BY-SA 4", licenseURL: "https://creativecommons.org/licenses/by-sa/4.0/deed.en", changes: "Re-encoded to 480px H.264 MP4 without audio; poster extracted from the source. The derivative is licensed under the same CC BY-SA 4.0. A centered continuous segment up to 6 seconds is converted to a 160px/6fps looping GIF preview; poster extracted from the midpoint.", durationSeconds: 15.93)),
        "builtin.incline-barbell-press": ExerciseDetail(aliases: [], secondaryMuscles: ["肩前束", "肱三头肌"], movementPattern: "斜向推", difficulty: "基础", commonMistakes: ["缺少保护却接近失控。", "下放位置过高导致肩部不适。"], alternativeIDs: ["builtin.incline-dumbbell-press", "builtin.barbell-bench-press"], progressionIDs: [], media: nil),
        "builtin.machine-chest-press": ExerciseDetail(aliases: ["坐姿推胸"], secondaryMuscles: ["肱三头肌", "肩前束"], movementPattern: "水平推", difficulty: "基础", commonMistakes: ["座高不合适仍强行推。", "耸肩、伸颈或弹动配重。"], alternativeIDs: ["builtin.dumbbell-bench-press", "builtin.incline-push-up"], progressionIDs: [], media: nil),
        "builtin.dumbbell-fly": ExerciseDetail(aliases: [], secondaryMuscles: ["肩前束"], movementPattern: "肩水平内收", difficulty: "进阶", commonMistakes: ["手臂完全锁死。", "过重或下放过深造成肩部牵扯。"], alternativeIDs: ["builtin.cable-chest-fly", "builtin.machine-chest-press"], progressionIDs: [], media: nil),
        "builtin.cable-chest-fly": ExerciseDetail(aliases: ["龙门架夹胸"], secondaryMuscles: ["肩前束"], movementPattern: "肩水平内收", difficulty: "基础", commonMistakes: ["靠大幅前倾和摆动带动配重。", "为增加幅度而让肩部失去稳定。"], alternativeIDs: ["builtin.dumbbell-fly", "builtin.machine-chest-press"], progressionIDs: [], media: nil),
        "builtin.incline-push-up": ExerciseDetail(aliases: ["高位俯卧撑"], secondaryMuscles: ["肱三头肌", "核心"], movementPattern: "水平推", difficulty: "基础", commonMistakes: ["使用会滑动的椅子。", "腰部下塌或只伸缩头部。"], alternativeIDs: ["builtin.knee-push-up", "builtin.machine-chest-press"], progressionIDs: ["builtin.push-up"], media: nil),
        "builtin.knee-push-up": ExerciseDetail(aliases: ["膝撑俯卧撑"], secondaryMuscles: ["肱三头肌", "核心"], movementPattern: "水平推", difficulty: "基础", commonMistakes: ["髋部明显后坐。", "腰部先上抬、胸部没有移动。"], alternativeIDs: ["builtin.incline-push-up", "builtin.machine-chest-press"], progressionIDs: ["builtin.push-up"], media: nil),
        "builtin.diamond-push-up": ExerciseDetail(aliases: ["钻石俯卧撑"], secondaryMuscles: ["胸部", "核心"], movementPattern: "水平推", difficulty: "进阶", commonMistakes: ["强迫双手拼成菱形却造成手腕疼痛。", "耸肩或塌腰。"], alternativeIDs: ["builtin.push-up", "builtin.incline-push-up"], progressionIDs: [], media: nil),
        "builtin.seated-cable-row": ExerciseDetail(aliases: ["坐姿划船", "低位划船"], secondaryMuscles: ["肱二头肌", "肩后束"], movementPattern: "水平拉", difficulty: "基础", commonMistakes: ["大幅后仰甩动配重。", "只弯肘而上臂几乎不后移。"], alternativeIDs: ["builtin.dumbbell-row", "builtin.chest-supported-row"], progressionIDs: [], media: nil),
        "builtin.barbell-row": ExerciseDetail(aliases: ["俯身杠铃划船"], secondaryMuscles: ["肱二头肌", "核心", "竖脊肌"], movementPattern: "水平拉", difficulty: "进阶", commonMistakes: ["依靠腰部起伏甩杠。", "圆背或膝盖反复大幅伸屈。"], alternativeIDs: ["builtin.chest-supported-row", "builtin.seated-cable-row"], progressionIDs: [], media: nil),
        "builtin.chest-supported-row": ExerciseDetail(aliases: ["胸支撑划船"], secondaryMuscles: ["肱二头肌", "肩后束"], movementPattern: "水平拉", difficulty: "基础", commonMistakes: ["胸部反复离开靠垫。", "耸肩或头部后仰。"], alternativeIDs: ["builtin.dumbbell-row", "builtin.seated-cable-row"], progressionIDs: [], media: nil),
        "builtin.pull-up": ExerciseDetail(aliases: ["正手引体"], secondaryMuscles: ["肱二头肌", "核心"], movementPattern: "垂直拉", difficulty: "进阶", commonMistakes: ["无法控制下落。", "强行抬头够杠或大幅摆动。"], alternativeIDs: ["builtin.assisted-pull-up", "builtin.lat-pulldown"], progressionIDs: [], media: nil),
        "builtin.band-pulldown": ExerciseDetail(aliases: ["弹力带下拉"], secondaryMuscles: ["肱二头肌"], movementPattern: "垂直拉", difficulty: "基础", commonMistakes: ["使用破损弹力带。", "固定点松动或回弹朝向面部。"], alternativeIDs: ["builtin.lat-pulldown", "builtin.assisted-pull-up"], progressionIDs: [], media: nil),
        "builtin.face-pull": ExerciseDetail(aliases: ["绳索面拉"], secondaryMuscles: ["背部", "肩外旋肌"], movementPattern: "水平拉", difficulty: "基础", commonMistakes: ["重量过大导致后仰。", "肩部不适仍强行外旋。"], alternativeIDs: ["builtin.reverse-fly", "builtin.band-pull-apart"], progressionIDs: [], media: ExerciseMediaDescriptor(kind: .video, fileName: "face-pull.mp4", posterFileName: "face-pull-poster.jpg", previewGIFFileName: "face-pull.gif", sourceURL: "https://wger.de/media/exercise-video/222/eea93fcc-6a3c-4783-8f70-0234c791a001.MOV", author: "Goulart", licenseName: "CC-BY-SA 4", licenseURL: "https://creativecommons.org/licenses/by-sa/4.0/deed.en", changes: "Re-encoded to 480px H.264 MP4 without audio; poster extracted from the source. The derivative is licensed under the same CC BY-SA 4.0. A centered continuous segment up to 6 seconds is converted to a 160px/6fps looping GIF preview; poster extracted from the midpoint.", durationSeconds: 8.57)),
        "builtin.reverse-fly": ExerciseDetail(aliases: ["俯身飞鸟", "反向飞鸟"], secondaryMuscles: ["背部"], movementPattern: "肩水平外展", difficulty: "基础", commonMistakes: ["耸肩甩动。", "重量太大而失去动作控制。"], alternativeIDs: ["builtin.face-pull", "builtin.band-pull-apart"], progressionIDs: [], media: nil),
        "builtin.band-pull-apart": ExerciseDetail(aliases: ["弹力带扩胸"], secondaryMuscles: ["背部"], movementPattern: "肩水平外展", difficulty: "基础", commonMistakes: ["耸肩或腰部后仰。", "使用损坏或过紧的弹力带。"], alternativeIDs: ["builtin.reverse-fly", "builtin.face-pull"], progressionIDs: [], media: nil),
        "builtin.lateral-raise": ExerciseDetail(aliases: ["侧平举"], secondaryMuscles: ["斜方肌"], movementPattern: "肩外展", difficulty: "基础", commonMistakes: ["用摆腰甩起重量。", "肩部明显不适仍硬抬。"], alternativeIDs: ["builtin.cable-lateral-raise", "builtin.machine-shoulder-press"], progressionIDs: [], media: ExerciseMediaDescriptor(kind: .video, fileName: "lateral-raise.mp4", posterFileName: "lateral-raise-poster.jpg", previewGIFFileName: "lateral-raise.gif", sourceURL: "https://wger.de/media/exercise-video/348/de69928a-8a35-4096-821c-1f46de5e0e03.MOV", author: "Goulart", licenseName: "CC-BY-SA 4", licenseURL: "https://creativecommons.org/licenses/by-sa/4.0/deed.en", changes: "Re-encoded to 480px H.264 MP4 without audio; poster extracted from the source. The derivative is licensed under the same CC BY-SA 4.0. A centered continuous segment up to 6 seconds is converted to a 160px/6fps looping GIF preview; poster extracted from the midpoint.", durationSeconds: 18.26)),
        "builtin.cable-lateral-raise": ExerciseDetail(aliases: ["单臂绳索侧平举"], secondaryMuscles: ["斜方肌"], movementPattern: "肩外展", difficulty: "基础", commonMistakes: ["身体侧摆。", "借助耸肩完成大部分动作。"], alternativeIDs: ["builtin.lateral-raise", "builtin.machine-shoulder-press"], progressionIDs: [], media: nil),
        "builtin.machine-shoulder-press": ExerciseDetail(aliases: ["器械推肩", "坐姿推肩"], secondaryMuscles: ["肱三头肌"], movementPattern: "垂直推", difficulty: "基础", commonMistakes: ["座椅高度不合适。", "靠腰部后仰完成推举。"], alternativeIDs: ["builtin.dumbbell-shoulder-press", "builtin.incline-push-up"], progressionIDs: [], media: nil),
        "builtin.barbell-back-squat": ExerciseDetail(aliases: ["杠铃深蹲", "后蹲"], secondaryMuscles: ["臀部", "核心"], movementPattern: "蹲", difficulty: "进阶", commonMistakes: ["未设置保护尝试失控重量。", "膝盖失控内扣或腰背明显塌陷。"], alternativeIDs: ["builtin.goblet-squat", "builtin.leg-press"], progressionIDs: [], media: nil),
        "builtin.barbell-front-squat": ExerciseDetail(aliases: ["前蹲"], secondaryMuscles: ["臀部", "核心", "上背"], movementPattern: "蹲", difficulty: "进阶", commonMistakes: ["手腕疼痛仍强行前架。", "肘部掉落导致杠铃前滚。"], alternativeIDs: ["builtin.goblet-squat", "builtin.barbell-back-squat"], progressionIDs: [], media: nil),
        "builtin.box-squat": ExerciseDetail(aliases: ["坐凳深蹲"], secondaryMuscles: ["臀部", "核心"], movementPattern: "蹲", difficulty: "基础", commonMistakes: ["箱子滑动或倾倒。", "用身体猛撞箱面。"], alternativeIDs: ["builtin.bodyweight-squat", "builtin.goblet-squat"], progressionIDs: ["builtin.bodyweight-squat"], media: nil),
        "builtin.leg-press": ExerciseDetail(aliases: ["倒蹬", "坐姿蹬腿"], secondaryMuscles: ["臀部"], movementPattern: "蹲", difficulty: "基础", commonMistakes: ["屈膝过深导致腰部卷起。", "脚跟离板或突然锁膝。"], alternativeIDs: ["builtin.goblet-squat", "builtin.bodyweight-squat"], progressionIDs: [], media: nil),
        "builtin.leg-extension": ExerciseDetail(aliases: ["腿伸展", "伸腿"], secondaryMuscles: ["腿部"], movementPattern: "膝伸", difficulty: "基础", commonMistakes: ["转轴和膝盖位置不合适。", "弹动、猛踢或疼痛时继续。"], alternativeIDs: ["builtin.bodyweight-squat", "builtin.leg-press"], progressionIDs: [], media: nil),
        "builtin.lying-leg-curl": ExerciseDetail(aliases: ["俯卧腿屈曲"], secondaryMuscles: ["小腿"], movementPattern: "膝屈", difficulty: "基础", commonMistakes: ["臀部明显抬离垫面。", "快速弹起配重。"], alternativeIDs: ["builtin.seated-leg-curl", "builtin.glute-bridge"], progressionIDs: [], media: ExerciseMediaDescriptor(kind: .video, fileName: "lying-leg-curl.mp4", posterFileName: "lying-leg-curl-poster.jpg", previewGIFFileName: "lying-leg-curl.gif", sourceURL: "https://wger.de/media/exercise-video/365/becaf013-5044-40d0-bae9-7ed60c973737.MOV", author: "Goulart", licenseName: "CC-BY-SA 4", licenseURL: "https://creativecommons.org/licenses/by-sa/4.0/deed.en", changes: "Re-encoded to 480px H.264 MP4 without audio; poster extracted from the source. The derivative is licensed under the same CC BY-SA 4.0. A centered continuous segment up to 6 seconds is converted to a 160px/6fps looping GIF preview; poster extracted from the midpoint.", durationSeconds: 15.06)),
        "builtin.seated-leg-curl": ExerciseDetail(aliases: ["坐姿腿屈曲"], secondaryMuscles: ["小腿"], movementPattern: "膝屈", difficulty: "基础", commonMistakes: ["座椅或固定垫未调好。", "以躯干晃动拉动配重。"], alternativeIDs: ["builtin.lying-leg-curl", "builtin.glute-bridge"], progressionIDs: [], media: nil),
        "builtin.barbell-rdl": ExerciseDetail(aliases: ["杠铃RDL", "罗马尼亚硬拉"], secondaryMuscles: ["竖脊肌", "核心"], movementPattern: "髋铰链", difficulty: "进阶", commonMistakes: ["把下放深度当作唯一目标。", "杠铃远离身体、腰背失稳。"], alternativeIDs: ["builtin.dumbbell-rdl", "builtin.glute-bridge"], progressionIDs: [], media: nil),
        "builtin.conventional-deadlift": ExerciseDetail(aliases: ["杠铃硬拉", "标准硬拉"], secondaryMuscles: ["背部", "核心"], movementPattern: "髋铰链", difficulty: "进阶", commonMistakes: ["猛拽起杠或腰背明显弯曲。", "杠铃绕膝远离身体。"], alternativeIDs: ["builtin.barbell-rdl", "builtin.dumbbell-rdl"], progressionIDs: [], media: nil),
        "builtin.glute-bridge": ExerciseDetail(aliases: ["双腿臀桥"], secondaryMuscles: ["腘绳肌", "核心"], movementPattern: "髋伸", difficulty: "基础", commonMistakes: ["靠腰部反弓代替髋伸。", "双脚滑动或膝盖失控内扣。"], alternativeIDs: ["builtin.hip-thrust", "builtin.bird-dog"], progressionIDs: ["builtin.hip-thrust"], media: nil),
        "builtin.hip-thrust": ExerciseDetail(aliases: ["臀推", "负重臀桥"], secondaryMuscles: ["腘绳肌", "核心"], movementPattern: "髋伸", difficulty: "进阶", commonMistakes: ["训练凳滑动。", "在顶端过度腰椎伸展。"], alternativeIDs: ["builtin.glute-bridge", "builtin.dumbbell-rdl"], progressionIDs: [], media: nil),
        "builtin.reverse-lunge": ExerciseDetail(aliases: ["后撤箭步蹲"], secondaryMuscles: ["臀部", "核心"], movementPattern: "弓步", difficulty: "基础", commonMistakes: ["步幅不合适导致失衡。", "前脚脚跟抬起或膝盖内扣。"], alternativeIDs: ["builtin.split-squat", "builtin.bodyweight-squat"], progressionIDs: ["builtin.dumbbell-lunge"], media: nil),
        "builtin.dumbbell-lunge": ExerciseDetail(aliases: ["哑铃箭步蹲"], secondaryMuscles: ["臀部", "核心"], movementPattern: "弓步", difficulty: "基础", commonMistakes: ["双脚像走钢丝一样过窄。", "负重过大导致明显失衡。"], alternativeIDs: ["builtin.reverse-lunge", "builtin.split-squat"], progressionIDs: [], media: nil),
        "builtin.split-squat": ExerciseDetail(aliases: ["静态弓步蹲"], secondaryMuscles: ["臀部", "核心"], movementPattern: "弓步", difficulty: "基础", commonMistakes: ["站距过窄导致左右摇晃。", "失去平衡仍继续下降。"], alternativeIDs: ["builtin.reverse-lunge", "builtin.bodyweight-squat"], progressionIDs: ["builtin.dumbbell-lunge"], media: nil),
        "builtin.standing-calf-raise": ExerciseDetail(aliases: ["提踵", "踮脚"], secondaryMuscles: ["足踝稳定肌"], movementPattern: "踝跖屈", difficulty: "基础", commonMistakes: ["向外或向内翻踝。", "快速弹跳而不是控制抬落。"], alternativeIDs: ["builtin.seated-calf-raise", "builtin.walking"], progressionIDs: [], media: nil),
        "builtin.seated-calf-raise": ExerciseDetail(aliases: [], secondaryMuscles: ["足踝稳定肌"], movementPattern: "踝跖屈", difficulty: "基础", commonMistakes: ["压垫设置不稳。", "踝关节向侧面歪斜。"], alternativeIDs: ["builtin.standing-calf-raise", "builtin.walking"], progressionIDs: [], media: nil),
        "builtin.hammer-curl": ExerciseDetail(aliases: ["锤式弯举"], secondaryMuscles: ["肱二头肌", "前臂"], movementPattern: "肘屈", difficulty: "基础", commonMistakes: ["旋转手腕或甩动身体。", "手肘大幅向前移动。"], alternativeIDs: ["builtin.dumbbell-curl", "builtin.barbell-curl"], progressionIDs: [], media: nil),
        "builtin.barbell-curl": ExerciseDetail(aliases: ["二头杠铃弯举"], secondaryMuscles: ["前臂"], movementPattern: "肘屈", difficulty: "基础", commonMistakes: ["抬髋摆腰借力。", "手腕过度后折。"], alternativeIDs: ["builtin.dumbbell-curl", "builtin.hammer-curl"], progressionIDs: [], media: nil),
        "builtin.cable-curl": ExerciseDetail(aliases: ["拉力器弯举"], secondaryMuscles: ["前臂"], movementPattern: "肘屈", difficulty: "基础", commonMistakes: ["靠身体后仰拉配重。", "回落太快或手腕受力失稳。"], alternativeIDs: ["builtin.dumbbell-curl", "builtin.barbell-curl"], progressionIDs: [], media: nil),
        "builtin.triceps-pushdown": ExerciseDetail(aliases: ["三头下压", "肱三头肌下压"], secondaryMuscles: ["前臂"], movementPattern: "肘伸", difficulty: "基础", commonMistakes: ["躯干大幅前后摆动。", "肩部发力把上臂向后甩。"], alternativeIDs: ["builtin.overhead-triceps-extension", "builtin.triceps-kickback"], progressionIDs: [], media: nil),
        "builtin.cable-overhead-triceps-extension": ExerciseDetail(aliases: ["绳索头后臂屈伸", "绳索过头臂屈伸"], secondaryMuscles: ["核心", "肩部稳定肌"], movementPattern: "肘伸", difficulty: "基础", commonMistakes: ["用腰部前后摇摆代替肘部伸展。", "上臂位置不稳或肩部不适时强行继续。"], alternativeIDs: ["builtin.triceps-pushdown", "builtin.overhead-triceps-extension"], progressionIDs: [], media: ExerciseMediaDescriptor(kind: .video, fileName: "cable-overhead-triceps-extension.mp4", posterFileName: "cable-overhead-triceps-extension-poster.jpg", previewGIFFileName: "cable-overhead-triceps-extension.gif", sourceURL: "https://wger.de/media/exercise-video/659/1f2eb3b6-3185-429f-8330-26dc88f39aff.MOV", author: "Goulart", licenseName: "CC-BY-SA 4", licenseURL: "https://creativecommons.org/licenses/by-sa/4.0/deed.en", changes: "Re-encoded to 480px H.264 MP4 without audio; poster extracted from the source. The derivative is licensed under the same CC BY-SA 4.0. A centered continuous segment up to 6 seconds is converted to a 160px/6fps looping GIF preview; poster extracted from the midpoint.", durationSeconds: 15.09)),
        "builtin.overhead-triceps-extension": ExerciseDetail(aliases: ["过头臂屈伸"], secondaryMuscles: ["核心"], movementPattern: "肘伸", difficulty: "基础", commonMistakes: ["腰部后仰或哑铃握持不稳。", "强行让双肘过度内夹。"], alternativeIDs: ["builtin.triceps-pushdown", "builtin.triceps-kickback"], progressionIDs: [], media: nil),
        "builtin.triceps-kickback": ExerciseDetail(aliases: ["哑铃后踢"], secondaryMuscles: ["肩后束"], movementPattern: "肘伸", difficulty: "基础", commonMistakes: ["上臂不停前后摆。", "使用过重重量导致腰背起伏。"], alternativeIDs: ["builtin.triceps-pushdown", "builtin.overhead-triceps-extension"], progressionIDs: [], media: ExerciseMediaDescriptor(kind: .video, fileName: "triceps-kickback.mp4", posterFileName: "triceps-kickback-poster.jpg", previewGIFFileName: "triceps-kickback.gif", sourceURL: "https://wger.de/media/exercise-video/655/2d88a05b-bde3-4026-bfbf-524c11068dc5.MOV", author: "Goulart", licenseName: "CC-BY-SA 4", licenseURL: "https://creativecommons.org/licenses/by-sa/4.0/deed.en", changes: "Re-encoded to 480px H.264 MP4 without audio; poster extracted from the source. The derivative is licensed under the same CC BY-SA 4.0. A centered continuous segment up to 6 seconds is converted to a 160px/6fps looping GIF preview; poster extracted from the midpoint.", durationSeconds: 10.26)),
        "builtin.ez-skullcrusher": ExerciseDetail(aliases: ["仰卧臂屈伸", "碎颅者"], secondaryMuscles: ["肩部稳定肌"], movementPattern: "肘伸", difficulty: "进阶", commonMistakes: ["在头部上方使用失控重量。", "下放过快或手腕明显后折。"], alternativeIDs: ["builtin.triceps-pushdown", "builtin.overhead-triceps-extension"], progressionIDs: [], media: ExerciseMediaDescriptor(kind: .video, fileName: "ez-skullcrusher.mp4", posterFileName: "ez-skullcrusher-poster.jpg", previewGIFFileName: "ez-skullcrusher.gif", sourceURL: "https://wger.de/media/exercise-video/246/2a194d11-ff5d-4bdf-849e-1c441cf7b0b1.MOV", author: "Goulart", licenseName: "CC-BY-SA 4", licenseURL: "https://creativecommons.org/licenses/by-sa/4.0/deed.en", changes: "Re-encoded to 480px H.264 MP4 without audio; poster extracted from the source. The derivative is licensed under the same CC BY-SA 4.0. A centered continuous segment up to 6 seconds is converted to a 160px/6fps looping GIF preview; poster extracted from the midpoint.", durationSeconds: 10.91)),
        "builtin.dead-bug": ExerciseDetail(aliases: ["死虫"], secondaryMuscles: ["髋屈肌"], movementPattern: "抗伸展", difficulty: "基础", commonMistakes: ["手脚伸得过低导致腰部失控拱起。", "憋气或追求速度。"], alternativeIDs: ["builtin.bird-dog", "builtin.plank"], progressionIDs: [], media: nil),
        "builtin.bird-dog": ExerciseDetail(aliases: ["鸟犬式", "四点支撑伸展"], secondaryMuscles: ["臀部", "背部"], movementPattern: "抗旋转", difficulty: "基础", commonMistakes: ["抬腿过高导致塌腰。", "骨盆左右翻转。"], alternativeIDs: ["builtin.dead-bug", "builtin.plank"], progressionIDs: [], media: nil),
        "builtin.side-plank": ExerciseDetail(aliases: ["侧桥"], secondaryMuscles: ["臀中肌", "肩部"], movementPattern: "抗侧屈", difficulty: "进阶", commonMistakes: ["肩部塌陷或骨盆向前后翻。", "疼痛时继续硬撑。"], alternativeIDs: ["builtin.plank", "builtin.bird-dog"], progressionIDs: [], media: nil),
        "builtin.crunch": ExerciseDetail(aliases: ["腹部卷起"], secondaryMuscles: ["腹斜肌"], movementPattern: "躯干屈曲", difficulty: "基础", commonMistakes: ["双手猛拉颈部。", "靠快速甩动做成全程起坐。"], alternativeIDs: ["builtin.dead-bug", "builtin.plank"], progressionIDs: [], media: nil),
        "builtin.mountain-climber": ExerciseDetail(aliases: ["登山者"], secondaryMuscles: ["肩部", "腿部"], movementPattern: "交替屈髋", difficulty: "基础", commonMistakes: ["髋部大幅抬起或腰部塌陷。", "追求速度导致手腕支撑失稳。"], alternativeIDs: ["builtin.dead-bug", "builtin.walking"], progressionIDs: [], media: nil),
        "builtin.stationary-cycling": ExerciseDetail(aliases: ["室内单车", "动感单车"], secondaryMuscles: ["心肺"], movementPattern: "骑行", difficulty: "基础", commonMistakes: ["阻力过大导致踩踏断续。", "座高导致髋膝明显不适。"], alternativeIDs: ["builtin.walking", "builtin.elliptical"], progressionIDs: [], media: nil),
        "builtin.elliptical": ExerciseDetail(aliases: ["太空漫步机"], secondaryMuscles: ["腿部", "心肺"], movementPattern: "周期有氧", difficulty: "基础", commonMistakes: ["身体过度倚靠把手。", "阻力过大而动作失控。"], alternativeIDs: ["builtin.walking", "builtin.stationary-cycling"], progressionIDs: [], media: nil),
        "builtin.rowing-ergometer": ExerciseDetail(aliases: ["测功仪划船"], secondaryMuscles: ["腿部", "背部", "心肺"], movementPattern: "划船有氧", difficulty: "进阶", commonMistakes: ["手臂先拉而腿部未发力。", "圆背猛拽或回程撞膝。"], alternativeIDs: ["builtin.stationary-cycling", "builtin.walking"], progressionIDs: [], media: nil),
    ]
}
