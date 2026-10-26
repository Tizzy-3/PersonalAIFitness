import SwiftUI
import UIKit
import FitnessCore

@MainActor
struct ProfileView: View {
    let store: TrainingStore
    @State private var profile: PersonalProfile
    @State private var birthYear: String
    @State private var height: String
    @State private var weight: String
    @State private var days: String
    @State private var minutes: String
    @State private var issue: String?
    @State private var saved = false

    init(store: TrainingStore) {
        self.store = store
        let value = store.profile
        _profile = State(initialValue: value)
        _birthYear = State(initialValue: value.birthYear.map(String.init) ?? "")
        _height = State(initialValue: UIInput.number(value.heightCM))
        _weight = State(initialValue: UIInput.number(value.weightKG))
        _days = State(initialValue: value.weeklyDays.map(String.init) ?? "")
        _minutes = State(initialValue: value.minutesPerSession.map(String.init) ?? "")
    }

    var body: some View {
        Form {
            Section {
                Text("空白表示未知，不会补成平均值或“无运动限制”。这些资料只保存在本地。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("基本资料") {
                numeric("出生年份", text: $birthYear, unit: "年", integer: true)
                numeric("身高", text: $height, unit: "cm")
                numeric("体重", text: $weight, unit: "kg")
            }
            Section("训练安排") {
                TextField("主要目标（未知可留空）", text: $profile.goal)
                TextField("训练经验与当前能力", text: $profile.experience, axis: .vertical)
                numeric("每周可训练", text: $days, unit: "天", integer: true)
                numeric("每次可训练", text: $minutes, unit: "分钟", integer: true)
                TextField("场地、器械和重量档位", text: $profile.equipmentNotes, axis: .vertical)
            }
            Section("运动限制与注意事项") {
                TextField("伤病、疼痛、医生限制或明确填写“无已知限制”", text: $profile.restrictions, axis: .vertical)
                    .lineLimit(3...7)
                Text("自动制定计划会另行确认安全信息、器械和时间。已有伤病限制不会由 AI 自行推断适配，本批会阻止自动制定，请按专业建议手动编辑。档案修订的完整时间线尚未实现。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section { Button("保存档案") { save() }.frame(maxWidth: .infinity) }
        }
        .navigationTitle("个人档案").navigationBarTitleDisplayMode(.inline)
        .fitnessError($issue)
        .alert("档案已保存", isPresented: $saved) { Button("知道了", role: .cancel) { } }
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("收起键盘") { hideKeyboard() } } }
    }

    private func numeric(_ title: String, text: Binding<String>, unit: String, integer: Bool = false) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("未知", text: text).multilineTextAlignment(.trailing).keyboardType(integer ? .numberPad : .decimalPad)
                .frame(minWidth: 70, maxWidth: 115).accessibilityLabel(title)
            Text(unit).foregroundStyle(.secondary)
        }
    }

    private func save() {
        do {
            var value = profile
            value.birthYear = try UIInput.integer(birthYear, label: "出生年份")
            value.heightCM = try UIInput.double(height, label: "身高")
            value.weightKG = try UIInput.double(weight, label: "体重")
            value.weeklyDays = try UIInput.integer(days, label: "每周天数")
            value.minutesPerSession = try UIInput.integer(minutes, label: "每次分钟数")
            try store.saveProfile(value)
            profile = value
            saved = true
        } catch { issue = error.localizedDescription }
    }
}

@MainActor
func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}
