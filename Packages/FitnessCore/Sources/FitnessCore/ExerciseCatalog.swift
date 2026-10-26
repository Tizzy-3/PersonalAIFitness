import Foundation

/// General movement identifiers, not a generated personal plan or licensed teaching-media catalog.
public enum ExerciseCatalog {
    public static let exercises: [Exercise] = [
        Exercise(id: "builtin.dumbbell-bench-press", name: "哑铃卧推", englishName: "Dumbbell Bench Press", kind: .strength, metric: .repetitions, equipment: "哑铃、平板训练凳", muscle: "胸部", loadConvention: .perHand),
        Exercise(id: "builtin.incline-dumbbell-press", name: "上斜哑铃卧推", englishName: "Incline Dumbbell Press", kind: .strength, metric: .repetitions, equipment: "哑铃、可调训练凳", muscle: "胸部", loadConvention: .perHand),
        Exercise(id: "builtin.dumbbell-shoulder-press", name: "哑铃肩上推举", englishName: "Dumbbell Shoulder Press", kind: .strength, metric: .repetitions, equipment: "哑铃", muscle: "肩部", loadConvention: .perHand),
        Exercise(id: "builtin.dumbbell-row", name: "单臂哑铃划船", englishName: "Single-arm Dumbbell Row", kind: .strength, metric: .repetitions, equipment: "哑铃、支撑凳", muscle: "背部", loadConvention: .perHand,
                 instructions: ["左右侧分别记录次数；本版本可通过备注说明每侧结果。"]),
        Exercise(id: "builtin.lat-pulldown", name: "高位下拉", englishName: "Lat Pulldown", kind: .strength, metric: .repetitions, equipment: "高位下拉器械", muscle: "背部", loadConvention: .total),
        Exercise(id: "builtin.goblet-squat", name: "高脚杯深蹲", englishName: "Goblet Squat", kind: .strength, metric: .repetitions, equipment: "哑铃或壶铃", muscle: "腿部", loadConvention: .total),
        Exercise(id: "builtin.dumbbell-rdl", name: "哑铃罗马尼亚硬拉", englishName: "Dumbbell Romanian Deadlift", kind: .strength, metric: .repetitions, equipment: "哑铃", muscle: "臀腿", loadConvention: .perHand),
        Exercise(id: "builtin.dumbbell-curl", name: "哑铃弯举", englishName: "Dumbbell Curl", kind: .strength, metric: .repetitions, equipment: "哑铃", muscle: "肱二头肌", loadConvention: .perHand),
        Exercise(id: "builtin.assisted-pull-up", name: "辅助引体向上", englishName: "Assisted Pull-up", kind: .strength, metric: .repetitions, equipment: "辅助引体器械", muscle: "背部", loadConvention: .assistance,
                 instructions: ["这里记录器械提供的辅助重量，不是外加负重；更大的辅助数值不代表力量增加。"]),
        Exercise(id: "builtin.push-up", name: "俯卧撑", englishName: "Push-up", kind: .bodyweight, metric: .repetitions, equipment: "徒手", muscle: "胸部", loadConvention: .bodyweight),
        Exercise(id: "builtin.bodyweight-squat", name: "徒手深蹲", englishName: "Bodyweight Squat", kind: .bodyweight, metric: .repetitions, equipment: "徒手", muscle: "腿部", loadConvention: .bodyweight),
        Exercise(id: "builtin.plank", name: "平板支撑", englishName: "Plank", kind: .bodyweight, metric: .duration, equipment: "垫子（可选）", muscle: "核心", loadConvention: .bodyweight),
        Exercise(id: "builtin.walking", name: "步行", englishName: "Walking", kind: .cardio, metric: .cardio, equipment: "无需专用器械", muscle: "全身", loadConvention: .bodyweight),
        Exercise(id: "builtin.running", name: "跑步", englishName: "Running", kind: .cardio, metric: .cardio, equipment: "跑道、道路或跑步机", muscle: "全身", loadConvention: .bodyweight),
        Exercise(id: "builtin.cycling", name: "骑行", englishName: "Cycling", kind: .cardio, metric: .cardio, equipment: "自行车或固定单车", muscle: "腿部", loadConvention: .bodyweight)
    ]

    public static func exercise(id: String) -> Exercise? { exercises.first { $0.id == id } }
}
