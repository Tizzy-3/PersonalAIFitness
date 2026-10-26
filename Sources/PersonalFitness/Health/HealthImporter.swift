import Foundation
@preconcurrency import HealthKit
import FitnessCore

/// Reads the health metrics this app actually supports, with incremental anchors and explicit
/// per-metric states.
///
/// Two rules drive the whole file:
/// 1. HealthKit never says whether *read* permission was granted, so an empty result is reported as
///    "no samples", never as "denied".
/// 2. Nothing is estimated. A metric without a real sample stays without a value.
actor HealthImporter {
    struct Outcome: Sendable {
        let snapshot: HealthSnapshot
        let notes: [String]
    }

    private let store = HKHealthStore()
    private let windowDays = 30

    static var readTypes: Set<HKObjectType> {
        Set([
            HKQuantityType(.stepCount),
            HKQuantityType(.restingHeartRate),
            HKQuantityType(.heartRateVariabilitySDNN),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.bodyMass),
            HKQuantityType(.vo2Max),
            HKCategoryType(.sleepAnalysis),
            HKObjectType.workoutType()
        ])
    }

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// Requests read access once, then reads every metric. An anchor from a previous read makes this
    /// an incremental query; without one it reads the whole window.
    func importAll(existingAnchors: [HealthMetric: Data] = [:], now: Date = Date()) async -> Outcome {
        var notes: [String] = []
        guard isAvailable else {
            let snapshot = HealthSnapshot(capturedAt: now, metrics: HealthMetric.allCases.map { metric in
                HealthMetricSnapshot(metric: metric, state: .unreadable, failureReason: "当前设备不提供 HealthKit。")
            })
            return Outcome(snapshot: snapshot, notes: ["当前设备不提供 HealthKit；训练记录仍可正常使用。"])
        }
        do {
            try await store.requestAuthorization(toShare: [], read: Self.readTypes)
        } catch {
            notes.append("授权请求未完成：\(error.localizedDescription)。这不代表你拒绝了读取。")
        }
        var metrics: [HealthMetricSnapshot] = []
        for metric in HealthMetric.allCases {
            let result = await read(metric, anchor: existingAnchors[metric], now: now)
            metrics.append(result.snapshot)
            if let note = result.note { notes.append(note) }
        }
        let snapshot = HealthSnapshot(capturedAt: now, metrics: metrics)
        return Outcome(snapshot: snapshot, notes: notes)
    }

    private struct MetricResult: Sendable {
        let snapshot: HealthMetricSnapshot
        let note: String?
    }

    /// Stored anchors are opaque bytes in the snapshot; HealthKit wants its own anchor object.
    private func anchorObject(_ data: Data?) -> HKQueryAnchor? {
        guard let data else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    private func anchorData(_ anchor: HKQueryAnchor?) -> Data? {
        guard let anchor else { return nil }
        return try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
    }

    private func read(_ metric: HealthMetric, anchor: Data?, now: Date) async -> MetricResult {
        do {
            switch metric {
            case .sleepAnalysis:
                return try await readSleep(anchor: anchor, now: now)
            case .workoutDuration:
                return try await readWorkoutDuration(anchor: anchor, now: now)
            default:
                return try await readQuantity(metric, anchor: anchor, now: now)
            }
        } catch {
            let nsError = error as NSError
            return MetricResult(
                snapshot: HealthMetricSnapshot(metric: metric, state: .unreadable,
                                               syncedAt: now,
                                               failureReason: "\(nsError.domain) / \(nsError.code)"),
                note: "\(metric.title)本次读取失败（\(nsError.domain) / \(nsError.code)），不代表没有这项数据。")
        }
    }

    private func unit(for metric: HealthMetric) -> HKUnit? {
        switch metric {
        case .stepCount: return .count()
        case .restingHeartRate: return HKUnit.count().unitDivided(by: .minute())
        case .heartRateVariabilitySDNN: return HKUnit.secondUnit(with: .milli)
        case .activeEnergy: return .kilocalorie()
        case .bodyMass: return .gramUnit(with: .kilo)
        case .cardioFitness: return HKUnit.literUnit(with: .milli).unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))
        case .sleepAnalysis, .workoutDuration: return nil
        }
    }

    private func quantityType(for metric: HealthMetric) -> HKQuantityType? {
        switch metric {
        case .stepCount: return HKQuantityType(.stepCount)
        case .restingHeartRate: return HKQuantityType(.restingHeartRate)
        case .heartRateVariabilitySDNN: return HKQuantityType(.heartRateVariabilitySDNN)
        case .activeEnergy: return HKQuantityType(.activeEnergyBurned)
        case .bodyMass: return HKQuantityType(.bodyMass)
        case .cardioFitness: return HKQuantityType(.vo2Max)
        case .sleepAnalysis, .workoutDuration: return nil
        }
    }

    private func readQuantity(_ metric: HealthMetric, anchor: Data?, now: Date) async throws -> MetricResult {
        guard let type = quantityType(for: metric), let unit = unit(for: metric) else {
            return MetricResult(snapshot: HealthMetricSnapshot(metric: metric, state: .noSamples, syncedAt: now),
                                note: nil)
        }
        let start = now.addingTimeInterval(-Double(windowDays) * 86_400)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now, options: .strictStartDate)
        let descriptor = HKAnchoredObjectQueryDescriptor(
            predicates: [.quantitySample(type: type, predicate: predicate)],
            anchor: anchorObject(anchor))
        let page = try await descriptor.result(for: store)
        let samples = page.addedSamples.compactMap { $0 as? HKQuantitySample }
        guard let latest = samples.max(by: { $0.endDate < $1.endDate }) else {
            // No new samples since the anchor. That is reported as its own state, never as a value.
            return MetricResult(snapshot: HealthMetricSnapshot(metric: metric, state: .noSamples,
                                                               sampleCountInWindow: 0,
                                                               syncedAt: now,
                                                               anchor: anchorData(page.newAnchor)),
                                note: nil)
        }
        let value = latest.quantity.doubleValue(for: unit)
        let freshness = now.timeIntervalSince(latest.endDate)
        let snapshot = HealthMetricSnapshot(
            metric: metric,
            state: freshness > metric.staleAfter ? .stale : .available,
            sampleCountInWindow: samples.count,
            latestValue: value,
            latestSampleAt: latest.endDate,
            syncedAt: now,
            sourceName: latest.sourceRevision.source.name,
            anchor: anchorData(page.newAnchor))
        return MetricResult(snapshot: snapshot, note: nil)
    }

    /// Sleep is a category type, so it is summed per night rather than sampled at a point in time.
    private func readSleep(anchor: Data?, now: Date) async throws -> MetricResult {
        let start = now.addingTimeInterval(-Double(windowDays) * 86_400)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now, options: .strictStartDate)
        let descriptor = HKAnchoredObjectQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: predicate)],
            anchor: anchorObject(anchor))
        let page = try await descriptor.result(for: store)
        let samples = page.addedSamples.compactMap { $0 as? HKCategorySample }
        let asleepValues: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue
        ]
        let asleep = samples.filter { asleepValues.contains($0.value) }
        guard let lastNightStart = Calendar.current.dateInterval(of: .day, for: now)?.start
            .addingTimeInterval(-86_400) else {
            return MetricResult(snapshot: HealthMetricSnapshot(metric: .sleepAnalysis, state: .noSamples,
                                                               syncedAt: now, anchor: anchorData(page.newAnchor)), note: nil)
        }
        let nightTotal = asleep.filter { $0.endDate > lastNightStart }
            .reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
        guard nightTotal > 0, let latest = asleep.max(by: { $0.endDate < $1.endDate }) else {
            return MetricResult(snapshot: HealthMetricSnapshot(metric: .sleepAnalysis, state: .noSamples,
                                                               syncedAt: now, anchor: anchorData(page.newAnchor)), note: nil)
        }
        let hours = nightTotal / 3_600
        let freshness = now.timeIntervalSince(latest.endDate)
        return MetricResult(snapshot: HealthMetricSnapshot(
            metric: .sleepAnalysis,
            state: freshness > HealthMetric.sleepAnalysis.staleAfter ? .stale : .available,
            sampleCountInWindow: asleep.count,
            latestValue: hours,
            latestSampleAt: latest.endDate,
            syncedAt: now,
            sourceName: latest.sourceRevision.source.name,
            anchor: anchorData(page.newAnchor)), note: nil)
    }

    /// Total workout minutes in the window, derived from real workout objects.
    private func readWorkoutDuration(anchor: Data?, now: Date) async throws -> MetricResult {
        let start = now.addingTimeInterval(-Double(windowDays) * 86_400)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now, options: .strictStartDate)
        let descriptor = HKAnchoredObjectQueryDescriptor(
            predicates: [.workout(predicate)],
            anchor: anchorObject(anchor))
        let page = try await descriptor.result(for: store)
        let workouts = page.addedSamples
        guard let latest = workouts.max(by: { $0.endDate < $1.endDate }) else {
            return MetricResult(snapshot: HealthMetricSnapshot(metric: .workoutDuration, state: .noSamples,
                                                               syncedAt: now, anchor: anchorData(page.newAnchor)), note: nil)
        }
        let minutes = workouts.reduce(0.0) { $0 + $1.duration } / 60
        let freshness = now.timeIntervalSince(latest.endDate)
        return MetricResult(snapshot: HealthMetricSnapshot(
            metric: .workoutDuration,
            state: freshness > HealthMetric.workoutDuration.staleAfter ? .stale : .available,
            sampleCountInWindow: workouts.count,
            latestValue: minutes,
            latestSampleAt: latest.endDate,
            syncedAt: now,
            sourceName: latest.sourceRevision.source.name,
            anchor: anchorData(page.newAnchor)), note: nil)
    }
}
