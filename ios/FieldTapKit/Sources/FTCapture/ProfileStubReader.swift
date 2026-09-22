import Foundation
import FTModel

/// Reads Apple's Baseband logging profile stub (logs/MCState/Shared/profile-*.stub) from an archive.
public enum ProfileStubReader {
    public static let basebandIdentifier = "com.apple.basebandlogging"

    /// The profile state, or nil when `plist` is not a stub for com.apple.basebandlogging (an archive carries
    /// stubs for every installed profile, a carrier's among them). Dates come from the stub, never from a
    /// constant: 7 days now, 21 days in 2025 copies.
    public static func read(_ plist: Data, observedAt: Date?) -> ProfileState? {
        guard let d = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let identifier = d["PayloadIdentifier"] as? String, identifier == basebandIdentifier else { return nil }
        let install = d["InstallDate"] as? Date
        let removal = d["RemovalDate"] as? Date
        let lifetime = install.flatMap { i in removal.map { $0.timeIntervalSince(i) / 86_400 } }
        var consentText = d["ConsentText"] as? String
        if let texts = d["ConsentText"] as? [String: Any] {
            consentText = (texts["default"] ?? texts["en"] ?? texts.values.first) as? String
        }
        let consentDays = consentText.flatMap { $0.firstMatch(of: /expire after ([0-9]+) days/) }.flatMap { Int($0.1) }
        var state = ProfileState(identifier: identifier, displayName: d["PayloadDisplayName"] as? String,
                                 installDate: install, removalDate: removal, lifetimeDays: lifetime,
                                 consentDays: consentDays, status: .unknown, observedAt: observedAt)
        state.status = observedAt.map { state.status(at: $0) } ?? (removal == nil ? .unknown : .active)
        return state
    }

    /// The newest Baseband profile event in MCProfileEvents.plist ("install" or "remove", and when), for an
    /// archive whose stub is gone because iOS already removed the profile.
    public static func lastBasebandEvent(_ plist: Data) -> (removed: Bool, at: Date)? {
        guard let d = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let events = d["ProfileEvents"] as? [[String: Any]] else { return nil }
        var newest: (removed: Bool, at: Date)?
        for event in events {
            for (key, value) in event where key.hasPrefix(basebandIdentifier) {
                guard let v = value as? [String: Any], let at = v["Timestamp"] as? Date else { continue }
                let operation = (v["Operation"] as? String)?.lowercased() ?? ""
                if newest == nil || at >= newest!.at { newest = (operation.contains("remov"), at) }
            }
        }
        return newest
    }
}
