import SwiftUI

struct HealthDiagnosticsView: View {
    @State private var reader = HealthReader()

    var body: some View {
        List {
            Section {
                Label("基础读取验证", systemImage: "heart.text.clipboard")
                Text("只在你点按后请求读取。不会向 Apple 健康写入训练，也不会将数据发送到 AI。")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button {
                    Task { await reader.requestAndRead() }
                } label: {
                    if reader.isLoading { ProgressView("正在读取…") }
                    else { Text("请求权限并读取") }
                }
                .disabled(reader.isLoading || !reader.isAvailable)
            }
            Section("可读数据") {
                ForEach(reader.readings) { reading in
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent(reading.title, value: reading.value ?? "暂未读到")
                        if let measuredAt = reading.measuredAt {
                            Text("\(reading.id == "steps" ? "统计截至" : "测量时间")：\(measuredAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let source = reading.source {
                            Text("来源：\(source)").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 4)
                }
            }
            if let message = reader.message {
                Section("本次查询") { Text(message).font(.subheadline).textSelection(.enabled) }
            }
            Section("更新信息") {
                if let attempt = reader.lastAttempt { LabeledContent("最近尝试", value: attempt.formatted(date: .abbreviated, time: .shortened)) }
                if let success = reader.lastSuccess { LabeledContent("最近完成", value: success.formatted(date: .abbreviated, time: .shortened)) }
                Text("读取请求成功不代表每项权限已开启；空数据不能直接判断为拒绝授权。界面显示真实测量日期，旧测量不作为今日身体结论。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("后续阶段，尚未实现") {
                Text("睡眠、HRV、运动心率、有氧适能、历史批量导入、增量同步、多来源处理、个人基线与身体状态评估。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Apple 健康")
        .navigationBarTitleDisplayMode(.inline)
    }
}
