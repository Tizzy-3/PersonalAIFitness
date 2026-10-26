import Foundation
@preconcurrency import HealthKit
import FitnessCore

/// Reads immutable HealthKit identities into a local sample ledger. The ledger and its per-type
/// anchor are returned together and are persisted by TrainingStore in one transaction.
actor HealthImporter {
    struct Outcome: Sendable {
        let snapshot: HealthSnapshot
        let notes: [String]
    }
    private struct Delta: Sendable {
        let added: [HealthSampleRecord]
        let deletedIDs: Set<UUID>
        let anchor: Data?
    }
    private let store = HKHealthStore()

    static var readTypes: Set<HKObjectType> {
        Set([HKQuantityType(.stepCount), HKQuantityType(.restingHeartRate),
             HKQuantityType(.heartRateVariabilitySDNN), HKQuantityType(.activeEnergyBurned),
             HKQuantityType(.bodyMass), HKQuantityType(.vo2Max), HKCategoryType(.sleepAnalysis),
             HKObjectType.workoutType()])
    }
    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func importAll(existingAnchors: [HealthMetric: Data] = [:], existingSnapshot: HealthSnapshot? = nil,
                   now: Date = Date()) async -> Outcome {
        var notes: [String] = []
        var cache = existingSnapshot?.cachedSamples ?? []
        var metrics: [HealthMetricSnapshot] = []
        if isAvailable {
            do { try await store.requestAuthorization(toShare: [], read: Self.readTypes) }
            catch { notes.append("授权请求未完成；空结果不能证明拒绝读权限。") }
        }
        for metric in HealthMetric.allCases {
            let previous = existingSnapshot?.snapshot(for: metric)
            // 0.4 saved anchors but no sample ledger. Reusing those anchors loses all earlier data.
            let canResume = existingSnapshot?.cachedSamples != nil && previous?.queryStartDate != nil
            let bytes = canResume ? (existingAnchors[metric] ?? previous?.anchor) : nil
            let decodedAnchor = anchorObject(bytes)
            let start = decodedAnchor == nil
                ? HealthSampleMerger.retentionStart(for: metric, now: now)
                : (previous?.queryStartDate ?? HealthSampleMerger.retentionStart(for: metric, now: now))
            do {
                guard isAvailable else { throw ImportFailure.unavailable }
                let delta = try await read(metric, anchor: decodedAnchor, start: start)
                let prior = decodedAnchor == nil ? [] : cache.filter { $0.metric == metric }
                let merged = try HealthSampleMerger.merge(existing: prior, added: delta.added,
                                                         deletedIDs: delta.deletedIDs, metric: metric, now: now)
                let other = cache.filter { $0.metric != metric }
                guard other.count + merged.count <= HealthSampleMerger.maximumCachedSamples else {
                    throw ImportFailure.tooManySamples
                }
                let summary = HealthSampleMerger.summarize(metric: metric, samples: merged,
                                                           anchor: delta.anchor, queryStartDate: start, now: now)
                try summary.validate()
                cache = other + merged
                metrics.append(summary)
            } catch {
                let nsError = error as NSError
                // Do not advance the anchor or erase prior samples when a query failed. The failure
                // state suppresses these historical values from today's recovery assessment.
                metrics.append(HealthMetricSnapshot(metric: metric, state: .unreadable, syncedAt: now,
                                                     anchor: canResume ? previous?.anchor : nil,
                                                     failureReason: String("\(nsError.domain) / \(nsError.code)".prefix(500)),
                                                     queryStartDate: canResume ? previous?.queryStartDate : nil))
                notes.append("\(metric.title)本次读取失败，已保留本地历史和上次查询位置；不代表没有数据或拒绝授权。")
            }
        }
        notes.append("睡眠按单夜区间并集统计；步数、活动能量和运动分钟采用明确标注的单一来源，可能少于 Apple 健康的合并结果。")
        return Outcome(snapshot: HealthSnapshot(capturedAt: now, metrics: metrics, cachedSamples: cache), notes: notes)
    }

    private enum ImportFailure: Error { case unavailable, tooManySamples }
    private func anchorObject(_ data: Data?) -> HKQueryAnchor? {
        guard let data else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }
    private func anchorData(_ anchor: HKQueryAnchor) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
    }
    private func record(_ sample: HKSample, metric: HealthMetric, value: Double,
                        category: Int? = nil) -> HealthSampleRecord {
        HealthSampleRecord(id: sample.uuid, metric: metric, startDate: sample.startDate, endDate: sample.endDate,
                           value: value, sourceName: String(sample.sourceRevision.source.name.prefix(200)),
                           sourceBundleIdentifier: String(sample.sourceRevision.source.bundleIdentifier.prefix(300)),
                           sleepCategory: category)
    }
    private func read(_ metric: HealthMetric, anchor: HKQueryAnchor?, start: Date) async throws -> Delta {
        // Keep this predicate's lower bound fixed while an anchor is in use. Old cached records
        // outside the rolling display window are pruned separately by the pure merger.
        let predicate = HKQuery.predicateForSamples(withStart: start, end: nil, options: [])
        switch metric {
        case .sleepAnalysis:
            let descriptor = HKAnchoredObjectQueryDescriptor(
                predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: predicate)], anchor: anchor)
            let page = try await descriptor.result(for: store)
            let added = page.addedSamples.map { record($0, metric: metric, value: 0, category: $0.value) }
            return Delta(added: added, deletedIDs: Set(page.deletedObjects.map(\.uuid)),
                         anchor: try anchorData(page.newAnchor))
        case .workoutDuration:
            let descriptor = HKAnchoredObjectQueryDescriptor(predicates: [.workout(predicate)], anchor: anchor)
            let page = try await descriptor.result(for: store)
            let added = page.addedSamples.map { record($0, metric: metric, value: $0.duration / 60) }
            return Delta(added: added, deletedIDs: Set(page.deletedObjects.map(\.uuid)),
                         anchor: try anchorData(page.newAnchor))
        default:
            guard let type = quantityType(for: metric), let unit = unit(for: metric) else {
                throw ImportFailure.unavailable
            }
            let descriptor = HKAnchoredObjectQueryDescriptor(
                predicates: [.quantitySample(type: type, predicate: predicate)], anchor: anchor)
            let page = try await descriptor.result(for: store)
            let added = page.addedSamples.map { record($0, metric: metric, value: $0.quantity.doubleValue(for: unit)) }
            return Delta(added: added, deletedIDs: Set(page.deletedObjects.map(\.uuid)),
                         anchor: try anchorData(page.newAnchor))
        }
    }
    private func unit(for metric: HealthMetric) -> HKUnit? {
        switch metric {
        case .stepCount: return .count()
        case .restingHeartRate: return HKUnit.count().unitDivided(by: .minute())
        case .heartRateVariabilitySDNN: return HKUnit.secondUnit(with: .milli)
        case .activeEnergy: return .kilocalorie()
        case .bodyMass: return .gramUnit(with: .kilo)
        case .cardioFitness:
            return HKUnit.literUnit(with: .milli).unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))
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
}
