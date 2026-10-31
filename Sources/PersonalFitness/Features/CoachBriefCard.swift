import SwiftUI
import FitnessCore

/// The coach's line at the top of Today, in the companion voice: an avatar, a speech bubble, and a
/// quiet "why" underneath.
///
/// The tone still drives the colour — a safety or caution brief never wears the encouraging
/// terracotta — but the shape is a person talking, not a status card.
struct CoachBriefCard: View {
    let brief: DailyCoachBrief
    var onCheckIn: (() -> Void)? = nil
    let openCoach: () -> Void
    @State private var showingEvidence = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color {
        switch brief.tone {
        case .safety, .caution: return FitnessTheme.orange
        case .rest: return FitnessTheme.teal
        case .welcome: return FitnessTheme.violet
        case .plan, .done: return FitnessTheme.accent
        }
    }

    /// The avatar face follows the tone too: a smiling figure for a normal day, a concerned one for
    /// safety. It is one character throughout, so the coach keeps an identity.
    private var avatarSymbol: String {
        switch brief.tone {
        case .safety: return "hand.raised.fill"
        case .caution: return "exclamationmark.bubble.fill"
        case .rest: return "moon.stars.fill"
        case .done: return "checkmark.seal.fill"
        case .welcome: return "sparkles"
        case .plan: return "figure.strengthtraining.functional"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 11) {
                avatar
                bubble
            }
            footerRow
        }
        .accessibilityElement(children: .contain)
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [tint.opacity(0.55), tint],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 44, height: 44)
                .shadow(color: tint.opacity(0.28), radius: 8, y: 3)
            Image(systemName: avatarSymbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
        }
        .accessibilityHidden(true)
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(brief.headline)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(FitnessTheme.ink)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            if !brief.details.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(brief.details.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 13.5, design: .rounded))
                            .foregroundStyle(FitnessTheme.muted)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if showingEvidence, !brief.evidence.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Divider().overlay(FitnessTheme.line)
                    ForEach(Array(brief.evidence.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 11.5, design: .rounded))
                            .foregroundStyle(FitnessTheme.faint)
                    }
                    Text("只用了这些已保存记录；没有的数据不会被补成“正常”。")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(FitnessTheme.faint)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 15).padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 20,
                                   bottomTrailingRadius: 20, topTrailingRadius: 20,
                                   style: .continuous)
                // A safety or caution brief gets its own warm wash so it cannot be mistaken for
                // ordinary encouragement at a glance.
                .fill(brief.tone == .safety || brief.tone == .caution
                      ? FitnessTheme.orangeTint : FitnessTheme.surface)
                .shadow(color: FitnessTheme.cardShadow, radius: 10, y: 4)
        )
    }

    private var footerRow: some View {
        HStack(spacing: 14) {
            if !brief.evidence.isEmpty {
                Button { withAnimation(FitnessTheme.Motion.state) { showingEvidence.toggle() } } label: {
                    Text(showingEvidence ? "收起依据" : "依据")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(FitnessTheme.faint)
                }
                .frame(minHeight: 44)
                .accessibilityHint("查看这句话用了哪些已保存记录")
            }
            Spacer(minLength: 0)
            if brief.needsPainAnswer, let onCheckIn {
                Button(action: onCheckIn) {
                    HStack(spacing: 5) {
                        Image(systemName: "checklist").font(.system(size: 11, weight: .semibold))
                        Text("记一下今天的状态").font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(tint)
                }
                .frame(minHeight: 44)
            } else {
                Button(action: openCoach) {
                    Text("和教练聊聊")
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(tint)
                }
                .frame(minHeight: 44)
            }
        }
        .padding(.leading, 55)
    }
}

/// A pending adjustment, surfaced on Today. It only opens the full review screen; accepting or
/// rejecting still happens there, so a card on the home screen can never change a plan by accident.
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
                ZStack {
                    Circle().fill(FitnessTheme.violetTint).frame(width: 40, height: 40)
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(FitnessTheme.violet)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(proposal.kind == .keep ? "教练的建议：保持原计划" : "教练想调整今天的安排")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(FitnessTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(proposal.summary)
                        .font(.system(size: 12.5, design: .rounded))
                        .foregroundStyle(FitnessTheme.muted)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    Text(isStale
                         ? "依据已经变化，打开后需要重新生成，不会自动套用。"
                         : "你在详情里确认后才会改变今天；拒绝则原计划不变。")
                        .font(.system(size: 11.5, design: .rounded))
                        .foregroundStyle(isStale ? FitnessTheme.orange : FitnessTheme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FitnessTheme.faint)
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: FitnessTheme.Radius.card, style: .continuous)
                    .fill(FitnessTheme.violetTint.opacity(0.5))
                    .overlay(RoundedRectangle(cornerRadius: FitnessTheme.Radius.card, style: .continuous)
                        .stroke(FitnessTheme.violet.opacity(0.28), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint("打开建议详情，查看依据后再决定")
    }
}
