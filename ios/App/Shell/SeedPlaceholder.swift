import SwiftUI

/// What a seeded view shows until its owner lands it: the view's name and owner, in the space it will take,
/// so a screenshot of the shell shows the layout.
struct SeedPlaceholder: View {
    var title: String
    var owner: String
    var systemImage: String = "square.dashed"
    var height: CGFloat?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(owner).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .foregroundStyle(.tertiary))
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
