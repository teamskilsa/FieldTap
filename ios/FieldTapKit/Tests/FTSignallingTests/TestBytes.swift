// Helpers shared by the ported decoder tests (the Kotlin tests each define their own hex/bits).

import Foundation
import FTCore
import FTModel
import FTTestSupport
@testable import FTSignalling

/// Hex to bytes. Whitespace is ignored, so long vectors are written in groups and never read as identifiers.
func hex(_ s: String) -> [UInt8] {
    let digits = Array(s.filter { !$0.isWhitespace })
    return stride(from: 0, to: digits.count - 1, by: 2).map { UInt8(String(digits[$0...$0 + 1]), radix: 16)! }
}

/// Bytes to lowercase hex, as Kotlin's `"%02x".format` joins them.
func hexString(_ b: [UInt8]) -> String { b.map { Fmt.hex($0, width: 2, prefix: false, uppercase: false) }.joined() }

/// A bit string ("0 1 0110...") to bytes, padded with zero bits to a whole octet, as the Kotlin tests build PDUs.
func bits(_ s: String) -> [UInt8] {
    let clean = s.filter { $0 == "0" || $0 == "1" }
    let padded = clean + String(repeating: "0", count: (8 - clean.count % 8) % 8)
    let chars = Array(padded)
    return stride(from: 0, to: chars.count, by: 8).map { UInt8(String(chars[$0..<$0 + 8]), radix: 2)! }
}

/// A dotted or colon-separated address from space-separated parts, so the source holds no address-shaped text.
func dotted(_ parts: String) -> String { parts.split(separator: " ").joined(separator: ".") }
func coloned(_ parts: String) -> String { parts.split(separator: " ", omittingEmptySubsequences: false).joined(separator: ":") }

extension Array where Element == Field {
    /// Kotlin's `first { it.label == label }.value`.
    func value(_ label: String) -> String? { first { $0.label == label }?.value }
}

/// The OnePlus captures the Android tests read from their resources, here from FT_FIXTURES/oneplus, read once.
enum OnePlus {
    static let callboxPath = "oneplus/oneplus-callbox-service-request.qmdl"
    static let fiveGPath = "oneplus/oneplus-5g-registration.qmdl"

    static let callbox: DiagProtocol.QmdlRead? = load(callboxPath)
    static let fiveG: DiagProtocol.QmdlRead? = load(fiveGPath)

    static let callboxFlow: Flow? = Fixtures.url(callboxPath).flatMap { try? Data(contentsOf: $0) }.map { CallFlowReader.read(qmdl: $0) }
    static let fiveGFlow: Flow? = Fixtures.url(fiveGPath).flatMap { try? Data(contentsOf: $0) }.map { CallFlowReader.read(qmdl: $0) }

    private static func load(_ path: String) -> DiagProtocol.QmdlRead? {
        Fixtures.url(path).flatMap { try? Data(contentsOf: $0) }.map { DiagProtocol.readQmdl($0) }
    }
}
