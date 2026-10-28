import Foundation
import CoreFoundation
import FitnessCore

/// Unambiguous representation changes only. Free narrative is never guessed into a constraint.
enum InterviewExtractionCodec {
    static func canonicalValue(_ raw: Any?, topic: InterviewTopic) throws -> String {
        func scalar(_ value: Any) throws -> String {
            if let text = value as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite {
                return value.doubleValue == value.doubleValue.rounded() ? String(format: "%.0f", value.doubleValue) : String(value.doubleValue)
            }
            throw CoreError.invalidInput("抽取值需要明确表示。")
        }
        guard let raw, !(raw is NSNull) else { throw CoreError.invalidInput("抽取值缺失。") }
        let listTopics: Set<InterviewTopic> = [.equipment, .schedule, .secondaryGoals, .preferences, .exclusions]
        var pieces: [String]
        if let values = raw as? [Any], listTopics.contains(topic) { pieces = try values.map(scalar) }
        else {
            let text = try scalar(raw)
            if listTopics.contains(topic), text.hasPrefix("["),
               let values = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any] { pieces = try values.map(scalar) }
            else { pieces = listTopics.contains(topic) ? text.replacingOccurrences(of: "，", with: ",").replacingOccurrences(of: "、", with: ",").components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } : [text] }
        }
        func mapped<T: RawRepresentable>(_ value: String, values: [T], title: (T) -> String) -> String where T.RawValue == String {
            values.first { $0.rawValue == value || title($0) == value }.map(\.rawValue) ?? value
        }
        switch topic {
        case .equipment:
            pieces = pieces.map { value in
                if ["kettlebell", "壶铃"].contains(value) { return PlanningEquipment.kettlebells.rawValue }
                return mapped(value, values: PlanningEquipment.allCases, title: { $0.title })
            }
        case .primaryGoal, .secondaryGoals:
            let aliases = ["减脂": "fatLoss", "增肌": "muscleGain", "力量": "strength", "耐力": "endurance"]
            pieces = pieces.map { mapped(aliases[$0] ?? $0, values: PlanningGoal.allCases, title: { $0.title }) }
        case .experience: pieces = pieces.map { mapped($0, values: PlanningExperience.allCases, title: { $0.title }) }
        case .schedule:
            let names = ["一", "二", "三", "四", "五", "六", "日"]
            pieces = pieces.map { value in
                if let index = names.firstIndex(where: { value == "周" + $0 || value == "星期" + $0 }) { return String(index + 1) }
                return value == "周天" || value == "星期天" ? "7" : value
            }
        case .preferences, .exclusions:
            pieces = pieces.map { value in
                if ExerciseCatalog.exercise(id: value) != nil { return value }
                let matches = ExerciseCatalog.exercises.filter { $0.name == value || $0.englishName.caseInsensitiveCompare(value) == .orderedSame || (ExerciseDetails.details(for: $0.id)?.aliases.contains(value) ?? false) }
                return matches.count == 1 ? matches[0].id : value
            }
        case .age, .height, .weight, .minutes:
            let suffixes: [String]
            switch topic {
            case .age: suffixes = ["years", "year", "岁"]
            case .height: suffixes = ["cm", "厘米", "公分"]
            case .weight: suffixes = ["kg", "公斤", "千克"]
            default: suffixes = ["minutes", "分钟", "min", "分"]
            }
            var value = pieces[0]
            for suffix in suffixes where value.lowercased().hasSuffix(suffix) {
                value = String(value.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
            pieces = [value]
        default: break
        }
        return pieces.joined(separator: ",")
    }
}
