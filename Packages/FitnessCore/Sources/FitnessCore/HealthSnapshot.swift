import Foundation

/// The Health types the app reads. Kept small and explicit so the UI can state exactly what it asked
/// for, and so an unread type is never reported as "you have none".
public enum HealthMetric: String, Codable, Equatable, CaseIterable, Sendable {
    case stepCount, restingHeartRate, heartRateVariabilitySDNN, sleepAnalysis
    case activeEnergy, bodyMass, workoutDuration, cardioFitness

    public var title: String {
        switch self {
        case .stepCount: return "步数"
        case .restingHeartRate: return "静息心率"
        case .heartRateVariabilitySDNN: return "心率变异性 SDNN"
        case .sleepAnalysis: return "睡眠"
        case .activeEnergy: return "活动能量"
        case .bodyMass: return "体重"
        case .workoutDuration: return "运动时长"
        case .cardioFitness: return "心肺适能"
        }
    }

    /// The label used everywhere the app shows HRV, so SDNN is never presented as RMSSD.
    public var measurementNote: String? {
        self == .heartRateVariabilitySDNN ? "此处为 SDNN，不是 RMSSD，不能互相套用结论。" : nil
    }

    /// Beyond this age a reading is shown as stale rather than current.
    public var staleAfter: TimeInterval {
        switch self {
        case .stepCount: return 2 * 86_400
        case .restingHeartRate, .heartRateVariabilitySDNN: return 7 * 86_400
        case .sleepAnalysis: return 3 * 86_400
        case .activeEnergy: return 2 * 86_400
        case .bodyMass: return 30 * 86_400
        case .workoutDuration: return 14 * 86_400
        case .cardioFitness: return 180 * 86_400
        }
    }
}

/// Why a metric does or does not have a value. `noSamples` is deliberately distinct from
/// `unreadable`: HealthKit does not tell an app whether the user denied read access.
public enum HealthMetricState: String, Codable, Equatable, Sendable {
    case available, noSamples, stale, unreadable

    public var title: String {
        switch self {
        case .available: return "已读取"
        case .noSamples: return "暂无样本"
        case .stale: return "数据过期"
        case .unreadable: return "本次无法读取"
        }
    }

    /// Historical values remain displayable when stale, but do not support a current verdict.
    public var isUsable: Bool { self == .available }
}

/// One metric's latest known value, with the sample time and sync time kept separate.
public struct HealthMetricSnapshot: Codable, Equatable, Sendable {
    public var metric: HealthMetric
    public var state: HealthMetricState
    public var sampleCountInWindow: Int
    public var latestValue: Double?
    public var latestSampleAt: Date?
    public var syncedAt: Date?
    public var sourceName: String?
    /// Per-metric opaque anchored-query token. Stored with the batch so an incremental read resumes
    /// exactly where it stopped instead of re-reading or guessing.
    public var anchor: Data?
    public var failureReason: String?
    /// Kept fixed across anchored reads. Moving a query predicate while reusing its anchor can
    /// silently change which historical samples were ever imported.
    public var queryStartDate: Date?

    public init(metric: HealthMetric, state: HealthMetricState = .noSamples,
                sampleCountInWindow: Int = 0, latestValue: Double? = nil,
                latestSampleAt: Date? = nil, syncedAt: Date? = nil, sourceName: String? = nil,
                anchor: Data? = nil, failureReason: String? = nil, queryStartDate: Date? = nil) {
        self.metric = metric; self.state = state
        self.sampleCountInWindow = sampleCountInWindow; self.latestValue = latestValue
        self.latestSampleAt = latestSampleAt; self.syncedAt = syncedAt
        self.sourceName = sourceName; self.anchor = anchor; self.failureReason = failureReason
        self.queryStartDate = queryStartDate
    }

    public func effectiveState(at now: Date) -> HealthMetricState {
        guard state == .available || state == .stale, let sampleAt = latestSampleAt else { return state }
        let age = now.timeIntervalSince(sampleAt)
        return age >= -300 && age <= metric.staleAfter ? state : .stale
    }

    public func isCurrent(at now: Date) -> Bool { effectiveState(at: now) == .available }

    public func validate() throws {
        guard sampleCountInWindow >= 0, sampleCountInWindow <= 10_000_000 else {
            throw CoreError.invalidInput("健康样本数量超出支持范围。")
        }
        if let latestValue {
            guard latestValue.isFinite else { throw CoreError.invalidInput("健康数值不是有效数字。") }
        }
        if let latestSampleAt { try CoreValidation.date(latestSampleAt, name: "样本时间") }
        if let syncedAt { try CoreValidation.date(syncedAt, name: "同步时间") }
        if let queryStartDate { try CoreValidation.date(queryStartDate, name: "健康查询起点") }
        guard (sourceName?.count ?? 0) <= 200, (failureReason?.count ?? 0) <= 500 else {
            throw CoreError.invalidInput("健康数据说明过长。")
        }
        switch state {
        case .available, .stale:
            guard latestValue != nil, latestSampleAt != nil, syncedAt != nil, failureReason == nil else {
                throw CoreError.invalidInput("\(metric.title)标记为已读取，却缺少数值、样本时间或同步时间。")
            }
        case .noSamples:
            guard latestValue == nil, latestSampleAt == nil else {
                throw CoreError.invalidInput("\(metric.title)没有样本，却带有数值或样本时间。")
            }
        case .unreadable:
            guard latestValue == nil, failureReason != nil else {
                throw CoreError.invalidInput("\(metric.title)读取失败时必须说明原因且不带数值。")
            }
        }
    }
}

/// The whole local health picture as of one read, plus the raw note shown to the user.
public struct HealthSnapshot: Codable, Equatable, Sendable {
    public var capturedAt: Date
    public var metrics: [HealthMetricSnapshot]
    /// nil identifies 0.4 snapshots that stored anchors without the samples they summarize.
    /// Those anchors must not be reused until a full window has been rebuilt.
    public var cachedSamples: [HealthSampleRecord]?

    public init(capturedAt: Date = Date(), metrics: [HealthMetricSnapshot] = [],
                cachedSamples: [HealthSampleRecord]? = nil) {
        self.capturedAt = capturedAt
        self.metrics = metrics
        self.cachedSamples = cachedSamples
    }

    public func snapshot(for metric: HealthMetric) -> HealthMetricSnapshot? {
        metrics.first { $0.metric == metric }
    }

    public var usableMetrics: [HealthMetricSnapshot] {
        metrics.filter { $0.state.isUsable && $0.latestValue != nil }
    }

    public func validate() throws {
        try CoreValidation.date(capturedAt, name: "健康读取时间")
        try CoreValidation.unique(metrics.map(\.metric), name: "健康数据类型")
        for metric in metrics { try metric.validate() }
        if let cachedSamples {
            guard cachedSamples.count <= HealthSampleMerger.maximumCachedSamples else {
                throw CoreError.invalidInput("健康样本缓存超过当前支持范围，未保存本次读取。")
            }
            try CoreValidation.unique(cachedSamples.map(\.id), name: "健康样本 UUID")
            for sample in cachedSamples { try sample.validate() }
        }
    }

    /// The sentence the UI must show. It never claims permission was denied, because HealthKit does
    /// not report read authorization per type.
    public var userFacingSummary: String {
        guard !metrics.isEmpty else { return "还没有读取过 Apple 健康数据。" }
        let noSamples = metrics.filter { $0.state == .noSamples }.map(\.metric.title)
        let unreadable = metrics.filter { $0.state == .unreadable }.map(\.metric.title)
        var parts: [String] = []
        let available = metrics.filter { $0.state == .available }.count
        if available > 0 { parts.append("本次读取到 \(available) 项数据") }
        if !noSamples.isEmpty {
            parts.append("\(noSamples.joined(separator: "、"))暂无样本（可能是未记录、未同步或未授权，系统不单独告知读权限是否被拒绝）")
        }
        if !unreadable.isEmpty {
            parts.append("\(unreadable.joined(separator: "、"))本次读取失败")
        }
        return parts.isEmpty ? "本次读取没有获得任何数据。" : parts.joined(separator: "；") + "。"
    }
}

/// A small local sample ledger. UUID is the HealthKit object identity, not a generated import id.
/// Sleep category values are preserved; only asleep categories enter the overnight union.
public struct HealthSampleRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var metric: HealthMetric
    public var startDate: Date
    public var endDate: Date
    public var value: Double
    public var sourceName: String
    public var sourceBundleIdentifier: String
    public var sleepCategory: Int?

    public init(id: UUID, metric: HealthMetric, startDate: Date, endDate: Date, value: Double,
                sourceName: String, sourceBundleIdentifier: String, sleepCategory: Int? = nil) {
        self.id = id; self.metric = metric; self.startDate = startDate; self.endDate = endDate
        self.value = value; self.sourceName = sourceName; self.sourceBundleIdentifier = sourceBundleIdentifier
        self.sleepCategory = sleepCategory
    }

    public func validate() throws {
        try CoreValidation.date(startDate, name: "健康样本开始时间")
        try CoreValidation.date(endDate, name: "健康样本结束时间")
        guard endDate >= startDate, value.isFinite, value >= 0,
              sourceName.count <= 200, sourceBundleIdentifier.count <= 300 else {
            throw CoreError.invalidInput("健康样本内容无效。")
        }
        if metric == .sleepAnalysis, sleepCategory == nil {
            throw CoreError.invalidInput("睡眠样本缺少分类。")
        }
    }
}

/// Deterministic delta application and summaries, isolated from HealthKit for regression tests.
public enum HealthSampleMerger {
    public static let maximumCachedSamples = 100_000
    public static let asleepCategoryValues: Set<Int> = [1, 3, 4, 5]

    public static func retentionStart(for metric: HealthMetric, now: Date) -> Date {
        now.addingTimeInterval(-max(30 * 86_400, metric.staleAfter))
    }

    public static func merge(existing: [HealthSampleRecord], added: [HealthSampleRecord],
                             deletedIDs: Set<UUID>, metric: HealthMetric, now: Date) throws -> [HealthSampleRecord] {
        let start = retentionStart(for: metric, now: now)
        var byID: [UUID: HealthSampleRecord] = [:]
        for sample in existing + added {
            try sample.validate()
            guard sample.metric == metric else { throw CoreError.invalidInput("增量批次混入其他健康类型。") }
            if sample.endDate >= start && sample.startDate <= now && !deletedIDs.contains(sample.id) {
                byID[sample.id] = sample
            }
        }
        guard byID.count <= maximumCachedSamples else {
            throw CoreError.invalidInput("健康样本数量超出支持范围，查询锚点未推进。")
        }
        return byID.values.sorted {
            $0.endDate == $1.endDate ? $0.id.uuidString < $1.id.uuidString : $0.endDate < $1.endDate
        }
    }

    /// Sleep uses the 24-hour local window ending at the latest observed sleep's next noon. This
    /// includes one night across midnight, never yesterday's and today's nights together.
    public static func sleepWindow(endingAt latest: Date, calendar: Calendar) -> DateInterval? {
        let day = calendar.startOfDay(for: latest)
        guard var end = calendar.date(byAdding: .hour, value: 12, to: day) else { return nil }
        if latest > end {
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: end) else { return nil }
            end = tomorrow
        }
        guard let start = calendar.date(byAdding: .day, value: -1, to: end) else { return nil }
        return DateInterval(start: start, end: end)
    }

    public static func unionDuration(_ samples: [HealthSampleRecord], within window: DateInterval) -> TimeInterval {
        let intervals = samples.compactMap { sample -> DateInterval? in
            let start = max(sample.startDate, window.start), end = min(sample.endDate, window.end)
            return end > start ? DateInterval(start: start, end: end) : nil
        }.sorted { $0.start < $1.start }
        guard var current = intervals.first else { return 0 }
        var total: TimeInterval = 0
        for interval in intervals.dropFirst() {
            if interval.start <= current.end {
                current = DateInterval(start: current.start, end: max(current.end, interval.end))
            } else { total += current.duration; current = interval }
        }
        return total + current.duration
    }

    public static func summarize(metric: HealthMetric, samples: [HealthSampleRecord], anchor: Data?,
                                 queryStartDate: Date?, now: Date, calendar: Calendar = .current) -> HealthMetricSnapshot {
        let windowStart = retentionStart(for: metric, now: now)
        let visible = samples.filter { $0.metric == metric && $0.endDate >= windowStart && $0.endDate <= now }
            .sorted { $0.endDate == $1.endDate ? $0.id.uuidString < $1.id.uuidString : $0.endDate < $1.endDate }
        var relevant = visible
        var value: Double?
        var sampleAt: Date?
        var source: String?
        if metric == .sleepAnalysis {
            let asleep = visible.filter { asleepCategoryValues.contains($0.sleepCategory ?? -1) }
            // At 20:00 a short afternoon nap must not replace last night's total. Use the latest
            // window no later than today's noon; preserve older nights as explicitly stale data.
            let today = calendar.startOfDay(for: now)
            let noon = calendar.date(byAdding: .hour, value: 12, to: today) ?? now
            if let latest = asleep.last(where: { $0.startDate < noon }),
               let window = sleepWindow(endingAt: min(latest.endDate, noon), calendar: calendar) {
                relevant = asleep.filter { $0.endDate > window.start && $0.startDate < window.end }
                let seconds = unionDuration(relevant, within: window)
                if seconds > 0 { value = seconds / 3_600; sampleAt = min(latest.endDate, window.end) }
                let names = Set(relevant.map(\.sourceName)).sorted().joined(separator: "、")
                source = String((names + " · 睡眠区间并集").prefix(200))
            }
        } else if metric == .stepCount || metric == .activeEnergy || metric == .workoutDuration {
            // Raw samples from phone and Watch may overlap. Until a user-defined source priority
            // exists, use one deterministic source rather than adding all sources twice. The
            // label makes this narrower summary explicit; it is not Apple's merged Health total.
            if metric != .workoutDuration {
                let start = calendar.startOfDay(for: now)
                relevant = visible.filter { $0.endDate > start }
            }
            let grouped = Dictionary(grouping: relevant, by: \.sourceBundleIdentifier)
            let chosen = grouped.keys.sorted().max { lhs, rhs in
                let l = grouped[lhs, default: []].reduce(0.0) { $0 + $1.value }
                let r = grouped[rhs, default: []].reduce(0.0) { $0 + $1.value }
                return l == r ? lhs > rhs : l < r
            }
            if let chosen, let selected = grouped[chosen], let latest = selected.last {
                relevant = selected
                value = selected.reduce(0) { $0 + $1.value }
                sampleAt = latest.endDate
                source = String((latest.sourceName + " · 单一来源" + (metric == .workoutDuration ? "窗口分钟" : "当日合计")).prefix(200))
            }
        } else if let latest = visible.last {
            value = latest.value; sampleAt = latest.endDate; source = latest.sourceName
        }
        guard let value, let sampleAt else {
            return HealthMetricSnapshot(metric: metric, state: .noSamples, syncedAt: now,
                                        anchor: anchor, queryStartDate: queryStartDate)
        }
        return HealthMetricSnapshot(metric: metric,
                                    state: now.timeIntervalSince(sampleAt) > metric.staleAfter ? .stale : .available,
                                    sampleCountInWindow: visible.count, latestValue: value, latestSampleAt: sampleAt,
                                    syncedAt: now, sourceName: source, anchor: anchor, queryStartDate: queryStartDate)
    }
}
