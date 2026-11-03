import Foundation

/// Reads planning facts straight out of what the person typed, without asking the model.
///
/// This exists because a structured extraction request is the one thing a general-purpose chat
/// endpoint often cannot do: it answers in prose, the JSON parse fails, and the profile stays empty
/// forever — which reads to the person as "the coach keeps asking and never gives me a plan".
///
/// Anything recognised here is marked `stated` only for facts that are unambiguous in the sentence
/// ("家里有哑铃和壶铃"). Everything else stays unknown, so this can fill a profile but never invent
/// one: a sentence that does not mention pain does not become "no pain".
public enum LocalFactExtractor {

    /// Equipment, matched by the words people actually use, including common variants.
    public static let equipmentAliases: [PlanningEquipment: [String]] = [
        .dumbbells: ["哑铃", "哑铃片", "可调节哑铃", "dumbbell", "dumbbells"],
        .kettlebells: ["壶铃", "kettlebell", "kettlebells"],
        .barbell: ["杠铃", "奥杆", "barbell"],
        .bench: ["卧推凳", "平板凳", "训练凳", "哑铃凳", "bench"],
        .adjustableBench: ["可调凳", "可调节训练凳", "调节凳"],
        .squatRack: ["深蹲架", "架子", "龙门架", "squat rack"],
        .cableMachine: ["绳索", "龙门", "拉力器", "cable"],
        .latPulldown: ["高位下拉", "下拉器"],
        .legPress: ["腿举", "倒蹬"],
        .legCurl: ["腿弯举"],
        .pullupBar: ["单杠", "引体向上架", "pull up"],
        .stationaryBike: ["动感单车", "固定单车", "单车", "健身车"],
        .rowingErgometer: ["划船机", "rowing"],
        .elliptical: ["椭圆机"],
        .resistanceBand: ["弹力带", "阻力带", "橡皮筋"],
        // 「家里」 alone is a place, not equipment; only an explicit walking/space phrase counts.
        .walkingSpace: ["走路", "步行空间", "小区", "客厅空间"],
        .runningSpace: ["跑步", "跑步机"]
    ]

    /// Weekday names as written in Chinese.
    public static let weekdayAliases: [Int: [String]] = [
        1: ["周一", "星期一", "礼拜一", "周1"],
        2: ["周二", "星期二", "礼拜二", "周2"],
        3: ["周三", "星期三", "礼拜三", "周3"],
        4: ["周四", "星期四", "礼拜四", "周4"],
        5: ["周五", "星期五", "礼拜五", "周5"],
        6: ["周六", "星期六", "礼拜六", "周6"],
        7: ["周日", "周天", "星期日", "星期天", "礼拜日", "周7"]
    ]

    /// Equipment mentioned in the text. Empty when nothing matches.
    public static func equipment(in text: String) -> Set<PlanningEquipment> {
        let lower = text.lowercased()
        var found: Set<PlanningEquipment> = []
        for (equipment, aliases) in equipmentAliases where aliases.contains(where: { lower.contains($0.lowercased()) }) {
            found.insert(equipment)
        }
        // "在家练" / "徒手" with no named tool still means bodyweight work is possible. This runs
        // only when nothing else matched, so naming real equipment is not overridden.
        if found.isEmpty,
           lower.contains("居家") || lower.contains("在家") || lower.contains("徒手") || lower.contains("家里练") {
            found.insert(.bodyweight)
        }
        return found
    }

    /// Weekdays the person says they can train. Handles 「周一周三周五」 and 「周二、周四」.
    public static func weekdays(in text: String) -> [Int] {
        let lower = text.lowercased()
        var found: Set<Int> = []
        for (weekday, aliases) in weekdayAliases where aliases.contains(where: { lower.contains($0) }) {
            found.insert(weekday)
        }
        return found.sorted()
    }

    /// A per-session minute budget. Only the number attached to a time unit is taken.
    public static func minutesPerSession(in text: String) -> Int? {
        // 30分钟 / 每次30分 / 40 min
        for pattern in [#"(\d{1,3})\s*分钟"#, #"(\d{1,3})\s*分(?!钟)"#, #"(\d{1,3})\s*(?:min|minutes)"#] {
            if let match = firstMatch(pattern, in: text), let value = Int(match), (15...120).contains(value) {
                return value
            }
        }
        return nil
    }

    /// Explicit goal wording. Only clear statements are taken.
    public static func goal(in text: String) -> PlanningGoal? {
        let lower = text.lowercased()
        if ["减脂", "减肥", "瘦", "掉秤", "降低体重"].contains(where: { lower.contains($0) }) { return .fatLoss }
        if ["增肌", "长肌肉", "变壮"].contains(where: { lower.contains($0) }) { return .muscleGain }
        if ["力量", "力气", "变强"].contains(where: { lower.contains($0) }) { return .strength }
        if ["耐力", "心肺", "体能"].contains(where: { lower.contains($0) }) { return .endurance }
        if ["通用", "健康", "保持", "活动"].contains(where: { lower.contains($0) }) { return .generalFitness }
        return nil
    }

    /// Experience wording, only when unambiguous.
    public static func experience(in text: String) -> PlanningExperience? {
        let lower = text.lowercased()
        if ["没练过", "零基础", "从没", "没有经验", "完全新手"].contains(where: { lower.contains($0) }) { return .beginner }
        // A hedge such as 「不知道算不算有经验」 must not be read as a claim of experience.
        let hedged = ["不知道", "算不算", "说不清", "不确定"].contains { lower.contains($0) }
        if !hedged, ["练了几年", "老手", "有经验", "练过一阵", "经常练"].contains(where: { lower.contains($0) }) {
            return .regular
        }
        if ["练过一点", "有点经验", "不多", "偶尔练", "初中级"].contains(where: { lower.contains($0) }) { return .beginner }
        return nil
    }

    /// Whether the person explicitly said there is no pain right now.
    ///
    /// Only an explicit denial counts. Silence is not "no pain", and a sentence mentioning pain is not
    /// a denial — that distinction is why this cannot simply look for the word 疼痛.
    public static func deniesPainNow(in text: String) -> Bool {
        let lower = text.lowercased()
        let denials = ["没有疼痛", "无疼痛", "不疼", "没有不适", "无不适", "没有不舒服", "没啥不适", "没有任何不适"]
        let hasDenial = denials.contains { lower.contains($0) }
        guard hasDenial else { return false }
        // 「之前疼，现在不疼了」 describes the past; only the present statement counts as today's answer,
        // and the model must not be tricked into confirming safety from history.
        let pastMarkers = ["之前", "以前", "上周", "上次", "昨天", "曾经"]
        let hasPast = pastMarkers.contains { lower.contains($0) }
        return !hasPast || lower.contains("现在")
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
