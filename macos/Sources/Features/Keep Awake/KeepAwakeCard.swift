import SwiftUI

/// Keep Mac Awake in the menu bar item's menu: a cup, whether it's keeping
/// the Mac awake, and what for. Sized like the agents' cards above it.
struct KeepAwakeCard: View {
    let headline: String
    let detail: String?
    let holding: Bool
    let stopped: Bool

    private var tint: Color {
        if stopped { return .orange }
        return holding ? Color(nsColor: .systemBrown) : .secondary
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(tint.opacity(holding || stopped ? 0.18 : 0.1))
                Image(systemName: holding ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(tint)
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 15)
        .frame(width: 320, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
