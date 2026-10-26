import Foundation
@preconcurrency import HealthKit
import Observation

/// P0 capability check only. No background import, personal baselines or readiness verdicts.
@MainActor
@Observable
final class HealthReader {
    struct Reading: Identifiable {
        let id: String
        let title: String
        var value: String?
        var measuredAt: Date?
        var source: String?
    }

    private let healthStore = HKHealthStore()
    private(set) var readings: [Reading] = [
        Reading(id: "steps", title: "今日步数"),
        Reading(id: "resting", title: "最近静息心率"),
        Reading(id: "weight", title: "最近体重")
    ]
    private(set) var isLoading = false
    private(set) var lastAttempt: Date?
    private(set) var lastSuccess: Date?
    private(set) var message: String?
    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAndRead() async {
        guard !isLoading else { return }
        guard isAvailable else { message = "当前设备不提供 HealthKit。训练记录仍可使用。"; return }
        isLoading = true
        lastAttempt = Date()
        message = nil
        defer { isLoading = false }
        let types: Set<HKObjectType> = [
            HKQuantityType(.stepCount), HKQuantityType(.restingHeartRate), HKQuantityType(.bodyMass)
        ]
        do {
            try await healthStore.requestAuthorization(toShare: [], read: types)
            let steps = try await todaySteps()
            let resting = try await latest(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()))
            let weight = try await latest(.bodyMass, unit: .gramUnit(with: .kilo))
            readings = [
                Reading(id: "steps", title: "今日步数", value: steps.map { Int($0).formatted() }, measuredAt: steps == nil ? nil : Date(), source: steps == nil ? nil : "HealthKit 统计查询 · 今日截至查询时刻"),
                Reading(id: "resting", title: "最近静息心率", value: resting.map { "\(Int($0.value.rounded())) 次/分" }, measuredAt: resting?.date, source: resting?.source),
                Reading(id: "weight", title: "最近体重", value: weight.map { String(format: "%.1f kg", $0.value) }, measuredAt: weight?.date, source: weight?.source)
            ]
            lastSuccess = Date()
            message = readings.contains(where: { $0.value != nil })
                ? "基础查询已完成。这里不判断恢复情况，也不代表全量健康同步已完成。"
                : "暂未读取到数据，可能未记录、未同步、超出可读范围或未允许读取。系统不提供每项读权限是否被拒绝的状态。"
        } catch {
            let nsError = error as NSError
            message = "本次读取未完成（\(nsError.domain) / \(nsError.code)）。请检查健康设置和最终签名的 HealthKit 能力；也可能是设备暂不可读。\n\(error.localizedDescription)"
        }
    }

    private func todaySteps() async throws -> Double? {
        let start = Calendar.current.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: HKQuantityType(.stepCount), quantitySamplePredicate: predicate, options: .cumulativeSum) { _, result, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: result?.sumQuantity()?.doubleValue(for: .count())) }
            }
            healthStore.execute(query)
        }
    }

    private func latest(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit) async throws -> HealthQuantityValue? {
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: HKQuantityType(identifier), predicate: nil, limit: 1, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                guard let sample = samples?.first as? HKQuantitySample else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: HealthQuantityValue(value: sample.quantity.doubleValue(for: unit), date: sample.endDate, source: sample.sourceRevision.source.name))
            }
            healthStore.execute(query)
        }
    }
}

private struct HealthQuantityValue: Sendable {
    let value: Double
    let date: Date
    let source: String
}
