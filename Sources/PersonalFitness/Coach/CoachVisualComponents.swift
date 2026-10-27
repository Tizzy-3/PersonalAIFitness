import SwiftUI

/// Shared presentation primitives for the coach's real workflows; no example data is inserted.
struct CoachPanel<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(FitnessTheme.surface, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct CoachIconBadge: View {
    let symbol: String
    var color: Color = FitnessTheme.accent
    var body: some View {
        Image(systemName: symbol)
            .font(.title3.weight(.medium))
            .foregroundStyle(color)
            .frame(width: 44, height: 44)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityHidden(true)
    }
}

struct CoachStatusPill: View {
    let text: String
    var color: Color = FitnessTheme.accent
    var body: some View {
        Text(text).font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct CoachNavigationLabel: View {
    let title: String
    let subtitle: String
    let symbol: String
    var color: Color = FitnessTheme.accent
    var body: some View {
        HStack(spacing: 12) {
            CoachIconBadge(symbol: symbol, color: color)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary).accessibilityHidden(true)
        }.frame(minHeight: 48).contentShape(Rectangle())
    }
}

struct CoachSectionHeading: View {
    let title: String
    var detail: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
            Spacer(minLength: 8)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }.accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
    }
}
