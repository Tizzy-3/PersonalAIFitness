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

    public var isUsable: Bool { self == .available || self == .stale }
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

    public init(metric: HealthMetric, state: HealthMetricState = .noSamples,
                sampleCountInWindow: Int = 0, latestValue: Double? = nil,
                latestSampleAt: Date? = nil, syncedAt: Date? = nil, sourceName: String? = nil,
                anchor: Data? = nil, failureReason: String? = nil) {
        self.metric = metric; self.state = state
        self.sampleCountInWindow = sampleCountInWindow; self.latestValue = latestValue
        self.latestSampleAt = latestSampleAt; self.syncedAt = syncedAt
        self.sourceName = sourceName; self.anchor = anchor; self.failureReason = failureReason
    }

    public func validate() throws {
        guard sampleCountInWindow >= 0, sampleCountInWindow <= 10_000_000 else {
            throw CoreError.invalidInput("健康样本数量超出支持范围。")
        }
        if let latestValue {
            guard latestValue.isFinite else { throw CoreError.invalidInput("健康数值不是有效数字。") }
        }
        if let latestSampleAt { try CoreValidation.date(latestSampleAt, name: "样本时间") }
        if let syncedAt { try CoreValidation.date(syncedAt, name: "同步时间") }
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

    public init(capturedAt: Date = Date(), metrics: [HealthMetricSnapshot] = []) {
        self.capturedAt = capturedAt
        self.metrics = metrics
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
