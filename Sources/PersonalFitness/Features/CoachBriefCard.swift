import SwiftUI
import FitnessCore

/// The coach's line at the top of Today. It is one sentence plus at most two supporting lines, and
/// its colour follows the tone: a safety or caution brief never uses the encouraging accent.
/// The evidence sits one tap further, so checking the facts never turns the sentence into a dashboard.
struct CoachBriefCard: View {
    let brief: DailyCoachBrief
    /// Set when a plan is scheduled for today: the check-in is then offered right here, so answering
    /// the coach's question never requires hunting for another screen.
    var onCheckIn: (() -> Void)? = nil
    let openCoach: () -> Void
    @State private var showingEvidence = false

    private var tint: Color {
        switch brief.tone {
        case .safety, .caution: return FitnessTheme.orange
        case .rest: return FitnessTheme.teal
        case .welcome: return FitnessTheme.violet
        case .plan, .done: return FitnessTheme.accent
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                FitnessIconBadge(symbol: brief.tone.symbol, color: tint)
                VStack(alignment: .leading, spacing: 6) {
                    Text(brief.headline)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(FitnessTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(brief.details.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.subheadline)
                            .foregroundStyle(FitnessTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 16) {
                if !brief.evidence.isEmpty {
                    Button(showingEvidence ? "收起依据" : "依据") { showingEvidence.toggle() }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(FitnessTheme.muted)
                        .frame(minHeight: 44)
                        .accessibilityHint("查看这句话用的是哪些已保存记录")
                }
                Spacer()
                if brief.needsPainAnswer, let onCheckIn {
                    Button("记一下今天的状态", action: onCheckIn)
                        .font(.caption.weight(.semibold)).foregroundStyle(tint).frame(minHeight: 44)
                } else {
                    Button("和教练聊聊", action: openCoach)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                        .frame(minHeight: 44)
                }
            }
            if showingEvidence {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(brief.evidence.enumerated()), id: \.offset) { _, line in
                        Text("· " + line).font(.caption).foregroundStyle(FitnessTheme.muted)
                    }
                    Text("这句话只用了上面这些已保存记录；没有的数据不会被补成“正常”。")
                        .font(.caption2).foregroundStyle(FitnessTheme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(FitnessTheme.canvas, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FitnessTheme.surface, in: RoundedRectangle(cornerRadius: 17))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(tint)
                .frame(width: 3)
                .padding(.vertical, 16)
                .padding(.leading, 1)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
    }
}

/// A pending adjustment, surfaced on Today instead of hidden two screens deep in the coach tab.
/// It only opens the full review screen; accepting or rejecting still happens there, so a one-tap
/// card on the home screen can never change a plan by accident.
struct PendingAdjustmentCard<Destination: View>: View {
    let proposal: AdjustmentProposal
    let isStale: Bool
    private let destination: () -> Destination

    init(proposal: AdjustmentProposal, isStale: Bool, @ViewBuilder destination: @escaping () -> Destination) {
        self.proposal = proposal
        self.isStale = isStale
        self.destination = destination
    }

    var body: some View {
        NavigationLink { destination() } label: {
            HStack(alignment: .top, spacing: 12) {
                FitnessIconBadge(symbol: "arrow.triangle.2.circlepath", color: FitnessTheme.violet)
                VStack(alignment: .leading, spacing: 5) {
                    Text(proposal.kind == .keep ? "教练的建议：保持原计划" : "教练想调整今天的安排")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(FitnessTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(proposal.summary)
                        .font(.caption).foregroundStyle(FitnessTheme.muted)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    Text(isStale
                         ? "依据已经变化，打开后需要重新生成，不会自动套用。"
                         : "只有你在详情里确认后才会改变今天；拒绝则原计划不变。")
                        .font(.caption2).foregroundStyle(isStale ? FitnessTheme.orange : FitnessTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FitnessTheme.surface, in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(FitnessTheme.violet.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityHint("打开建议详情，查看依据后再决定")
    }
}
