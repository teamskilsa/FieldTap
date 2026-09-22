import SwiftUI
import FTApp
import FTModel
import FTPhy

/// What is not possible on this iPhone and what is not decoded yet, each with its reason and log codes, so an
/// empty chart is never a mystery; then the decoder self-checks and any record versions that were skipped.
struct UnavailableSection: View {
    @Bindable var session: CaptureSession

    private var phy: PhyCapture { session.analysis.phy }

    var body: some View {
        let entries = phy.availability.isEmpty ? PhyCatalog.entries : phy.availability
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Not available", source: "What this iPhone's modem does not log in plain form, what FieldTap does not decode yet, and decoder health",
                          session: session) { _ in Self.health(phy) }
            list("Not possible on this iPhone", "nosign", entries.filter { PhyCatalog.notPossibleIds.contains($0.id) })
            list("Not decoded yet", "hourglass", entries.filter { !PhyCatalog.notPossibleIds.contains($0.id) })
            DecoderHealthView(phy: phy)
        }
    }

    /// The decoder-health summary shown on top: self-checks, skipped versions, encrypted records.
    static func health(_ phy: PhyCapture) -> [Readout] {
        let passed = phy.checks.filter(\.passed).count
        var out = [Readout(label: "Self-checks", value: "\(passed) of \(phy.checks.count) pass"),
                   Readout(label: "Versions skipped", value: RadioFormat.count(phy.versionMisses.values.reduce(0, +))),
                   phy.summary.encrypted.records > 0
                       ? Readout(label: "Encrypted", value: RadioFormat.count(phy.summary.encrypted.records))
                       : Readout(label: "Encrypted", value: "not counted", stale: true)]
        if !LteTbs.isAvailable { out.append(Readout(label: "TBS checks", value: "not run", stale: true)) }
        return out
    }

    private func list(_ title: String, _ symbol: String, _ items: [Availability]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.headline)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(items) { a in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(a.title).font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(statusText(a.status)).font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(a.reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if !a.codes.isEmpty {
                            Text(a.codes.map(RadioFormat.hex).joined(separator: " · "))
                                .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(10)
                    .accessibilityElement(children: .combine)
                    if a.id != items.last?.id { Divider().padding(.leading, 10) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
        }
    }

    private func statusText(_ s: AvailabilityStatus) -> String {
        switch s {
        case .available: "available"
        case .notDecodedYet: "not decoded yet"
        case .notFoundInPlainLogs: "not in plain logs"
        case .encryptedByModem: "encrypted by the modem"
        case .notOnIPhone: "not on iPhone"
        }
    }
}

/// Decoder health: every self-check with what it measured, and the record versions that were not decoded.
struct DecoderHealthView: View {
    var phy: PhyCapture

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Decoder health", systemImage: "stethoscope").font(.headline)
            VStack(alignment: .leading, spacing: 0) {
                if phy.checks.isEmpty {
                    Text("No self-check could run: this capture has none of the PHY records they test.")
                        .font(.caption).foregroundStyle(.secondary).padding(10)
                }
                ForEach(phy.checks) { c in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: c.passed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(c.passed ? Theme.accent : Theme.severity(.warning))
                            .accessibilityLabel(c.passed ? "passed" : "failed")
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(c.id).font(.caption.monospaced().weight(.semibold))
                                Spacer()
                                Text(RadioFormat.hex(c.code)).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                            }
                            Text(c.expectation).font(.caption).foregroundStyle(.secondary)
                            Text(c.measured).font(.caption.monospacedDigit()).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(10)
                    .accessibilityElement(children: .combine)
                    if c.id != phy.checks.last?.id { Divider().padding(.leading, 10) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
            versions
        }
    }

    private var versions: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Record versions").font(.subheadline.weight(.semibold))
            if phy.versionMisses.isEmpty {
                Text("Every PHY record had a version the decoders were validated on; none was skipped.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(phy.versionMisses.keys.sorted(), id: \.self) { k in
                    Label("\(k): \(RadioFormat.count(phy.versionMisses[k] ?? 0)) records not decodable (version not validated)",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Theme.severity(.warning))
                }
            }
            if phy.summary.encrypted.records > 0 {
                Text("\(RadioFormat.count(phy.summary.encrypted.records)) records in \(phy.summary.encrypted.codes) codes arrived encrypted by the modem; they are counted, never decoded.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
