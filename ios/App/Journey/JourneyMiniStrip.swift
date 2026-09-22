import SwiftUI
import FTJourney
import FTModel

/// The capture card's 24 pt PCell lane: bands in their app-wide colours over the whole trace, a "5G" tick when
/// the capture had an NR leg, and a failure badge. The collapsed journey strip reuses it at 16 pt.
struct JourneyMiniStrip: View {
    var preview: JourneyPreview
    /// The trace length the lane spans; the last segment's end when not given (the card has only the preview).
    var durationMs: Double? = nil
    var height: CGFloat = 24
    @Environment(\.self) private var env

    var body: some View {
        let total = max(durationMs ?? preview.segments.map(\.endMs).max() ?? 1, 1)
        HStack(spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: height / 3).fill(Color.secondary.opacity(0.12))
                    ForEach(Array(preview.segments.enumerated()), id: \.offset) { _, s in
                        let x = s.startMs / total * w
                        let width = max(1.5, (s.endMs - s.startMs) / total * w)
                        RoundedRectangle(cornerRadius: min(4, height / 4))
                            .fill(Theme.bandColor(s.band))
                            .frame(width: width, height: height)
                            .overlay {
                                if height >= 20, Double(s.band.count) * 6.4 + 6 <= width {
                                    Text(s.band)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(JourneyStyle.ink(on: Theme.bandColor(s.band), in: env))
                                        .lineLimit(1)
                                        .fixedSize()
                                }
                            }
                            .offset(x: x)
                    }
                }
            }
            .frame(height: height)
            if preview.nr {
                Text("5G")
                    .font(.system(size: height >= 20 ? 10 : 9, weight: .bold))
                    .padding(.horizontal, 4)
                    .frame(height: min(height, 18))
                    .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary, lineWidth: 1))
                    .foregroundStyle(.secondary)
            }
            if preview.failures > 0 {
                Label("\(preview.failures)", systemImage: "xmark.octagon.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.severity(.failure))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private var spoken: String {
        var bands: [String] = []
        for s in preview.segments where bands.last != s.band { bands.append(s.band) }
        var parts = [bands.isEmpty ? "No serving cell" : "Cells " + bands.joined(separator: ", then ")]
        if preview.nr { parts.append("with a 5G NR leg") }
        parts.append(preview.failures == 1 ? "1 failure" : "\(preview.failures) failures")
        return parts.joined(separator: ", ")
    }
}
