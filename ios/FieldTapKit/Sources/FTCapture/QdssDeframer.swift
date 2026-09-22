// A streaming Swift port of qdss_deframe.py with its default, verified rules (demux by channel, reversed last
// words, gather by kind, one stream across chunks). Every detail below drives md5 parity with the Python's
// .qmdl, so the comments name the Python function each part mirrors.

import Foundation
import FTModel

/// One encrypted ("secure") QDSS packet: counted by code, never decoded.
public struct SecureRecord: Hashable, Sendable {
    public var code: UInt16
    public var timestampRaw: UInt64

    public init(code: UInt16, timestampRaw: UInt64) {
        self.code = code
        self.timestampRaw = timestampRaw
    }
}

public struct DeframeOutput: Hashable, Sendable {
    /// In effective-timestamp order, which is qdss_deframe.py's .qmdl order.
    public var records: [LogRecord]
    public var secure: [SecureRecord]
    public var stats: DeframeStats

    public init(records: [LogRecord], secure: [SecureRecord], stats: DeframeStats) {
        self.records = records
        self.secure = secure
        self.stats = stats
    }

    /// The secure packets per code, for the capture summary ("23,764 records across 61 codes").
    public var census: EncryptedCensus {
        var byCode: [String: Int] = [:]
        for s in secure { byCode[Fmt4.hex(s.code), default: 0] += 1 }
        return EncryptedCensus(records: secure.count, codes: byCode.count, byCode: byCode)
    }
}

/// Streaming Swift port of qdss_deframe.py (default verified rules).
///
/// Feed each chunk's bytes in ascending chunk-name order, in any split (`feed`), and call `endChunk()` after
/// each chunk: layer 1's 16-byte frames are aligned to the start of every chunk, so a chunk's tail shorter than
/// 16 bytes is dropped there. `feedChunk` does both for a whole chunk. `finish()` once at the end. The output
/// does not depend on how a chunk is split into `feed` calls.
///
/// Memory stays bounded by the open fragments, the first 320,031 stream bytes (until the phase is known) and
/// the records themselves; the 124 MB layer-1 stream of a full capture is never held.
public struct QdssDeframer: Sendable {
    /// The trace ID the DIAG traffic uses.
    static let diagAtid = 0x32
    /// find_phase's sample: units over the first 320,000 bytes.
    static let phaseSample = 320_000
    /// find_phase scans i in [p, min(len - 16, p + 320_000)) for every p < 16; with this many bytes buffered
    /// the bound no longer depends on the length, so the phase equals the Python's on the whole stream.
    static let phaseBytes = phaseSample + 31

    // Layer 1.
    private var frame: [UInt8] = []
    /// The formatter's current ATID; -1 before the first ID byte (the Python's None).
    private var currentId = -1
    private var chunkCount = 0
    private var chunkOpen = false
    private var streamBytes = 0
    private var layer1Out: [UInt8] = []

    // Layer 2.
    private var phase: Int?
    private var head: [UInt8] = []
    private var unit: [UInt8] = []
    private var skip = 0
    /// Lane (u0 >> 5) -> bound channel; -1 is unbound (the Python's key None).
    private var lanes = [Int32](repeating: -1, count: 8)
    private var open: [Int32: OpenFragment] = [:]
    private var pending: [Int32: Pending] = [:]
    /// Insertion order for `open` and `pending`: the Python's dicts yield in insertion order, and a key that is
    /// popped and inserted again goes to the end.
    private var sequence = 0

    // Layer 3.
    private var records: [LogRecord] = []
    private var recordKeys: [Int32] = []
    private var incompleteRecords = 0
    private var secure: [SecureRecord] = []
    private var counts = Counts()

    private struct OpenFragment: Sendable {
        /// The start unit followed by its continuation units, 16 bytes each.
        var units: [UInt8]
        var order: Int
    }

    private struct Pending: Sendable {
        var data: [UInt8]
        var complete: Bool
        var order: Int
    }

    /// The Python's Counters. Fixed fields for the hot paths; `extra` for the rare dynamic names.
    private struct Counts: Sendable {
        var uFill = 0, uChan = 0, uStart = 0, uCont = 0, uContOrphan = 0, uBadType = 0, qshrinkF3 = 0
        var messages = 0, messagesUnterm = 0, messagesIncomplete = 0, gatherFlushed = 0, gatherLeftOpen = 0
        var extra: [String: Int] = [:]
        var fitsExact = 0, fitsShort = 0, fitsExtraUnits = 0, fitsCountMismatch = 0
        var kinds = [Int](repeating: 0, count: 16)
        /// Packet kind (`PacketKind.rawValue`) * 2 + 1 when the message was unterminated.
        var packets: [Int: Int] = [:]
        var codeCounts: [UInt16: Int] = [:]
        /// Codes in first-seen order: Counter.most_common breaks ties by insertion order.
        var codeOrder: [UInt16] = []
    }

    public init() {}

    // MARK: Input

    /// Bytes of the current chunk, in any split.
    public mutating func feed(_ bytes: UnsafeRawBufferPointer) {
        chunkOpen = true
        guard let raw = bytes.baseAddress, !bytes.isEmpty else { return }
        let p = raw.assumingMemoryBound(to: UInt8.self)
        let n = bytes.count
        layer1Out.removeAll(keepingCapacity: true)
        var i = 0
        if !frame.isEmpty {
            let take = min(16 - frame.count, n)
            frame.append(contentsOf: UnsafeBufferPointer(start: p, count: take))
            i = take
            if frame.count == 16 {
                let f = frame
                frame.removeAll(keepingCapacity: true)
                f.withUnsafeBufferPointer { deformat($0.baseAddress!) }
            }
        }
        while i + 16 <= n {
            deformat(p + i)
            i += 16
        }
        if i < n { frame.append(contentsOf: UnsafeBufferPointer(start: p + i, count: n - i)) }
        let out = layer1Out
        out.withUnsafeBufferPointer { stream($0) }
    }

    public mutating func feed(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { feed($0) }
    }

    /// Ends the current chunk: its tail shorter than one 16-byte frame is dropped. The formatter's ATID and the
    /// layer-2 stream carry on into the next chunk.
    public mutating func endChunk() {
        frame.removeAll(keepingCapacity: true)
        chunkCount += 1
        chunkOpen = false
    }

    /// One whole chunk: `feed` then `endChunk`.
    public mutating func feedChunk(_ bytes: UnsafeRawBufferPointer) {
        feed(bytes)
        endChunk()
    }

    // MARK: Layer 1 (deformat)

    @inline(__always)
    private mutating func deformat(_ f: UnsafePointer<UInt8>) {
        if f[0] == 0xFF && f[1] == 0xFF && f[2] == 0xFF && f[3] == 0x7F { return }      // sync frame
        let aux = f[15]
        if (f[0] | f[2] | f[4] | f[6] | f[8] | f[10] | f[12] | f[14]) & 1 == 0 {
            // No ID byte in this frame.
            guard currentId == Self.diagAtid else { return }
            let base = layer1Out.count
            layer1Out.append(contentsOf: UnsafeBufferPointer(start: f, count: 15))
            if aux != 0 {
                for i in 0..<8 where (aux >> UInt8(i)) & 1 != 0 { layer1Out[base + 2 * i] |= 1 }
            }
            return
        }
        for i in 0..<8 {
            let x = f[2 * i]
            let bit = (aux >> UInt8(i)) & 1
            if x & 1 != 0 {
                let id = Int(x >> 1)
                if i == 7 {
                    currentId = id
                } else if bit != 0 {
                    // The following byte still belongs to the old ID.
                    if currentId == Self.diagAtid { layer1Out.append(f[2 * i + 1]) }
                    currentId = id
                } else {
                    currentId = id
                    if currentId == Self.diagAtid { layer1Out.append(f[2 * i + 1]) }
                }
            } else if currentId == Self.diagAtid {
                layer1Out.append(x | bit)
                if i < 7 { layer1Out.append(f[2 * i + 1]) }
            }
        }
    }

    // MARK: Layer 2 (find_phase, iter_fragments, assemble)

    private mutating func stream(_ p: UnsafeBufferPointer<UInt8>) {
        guard !p.isEmpty else { return }
        streamBytes += p.count
        if phase == nil {
            head.append(contentsOf: p)
            if head.count >= Self.phaseBytes { decidePhase() }
            return
        }
        units(p)
    }

    private mutating func decidePhase() {
        let h = head
        head = []
        let p = h.withUnsafeBufferPointer { Self.findPhase($0) }
        phase = p
        skip = p
        h.withUnsafeBufferPointer { units($0) }
    }

    /// find_phase: the p in 0..<16 with the most plausible unit headers; the first maximum wins.
    static func findPhase(_ s: UnsafeBufferPointer<UInt8>) -> Int {
        var best = 0, bestGood = -1
        for p in 0..<16 {
            var good = 0
            var i = p
            let end = min(s.count - 16, p + phaseSample)
            while i < end {
                let t = s[i] & 0x1F
                if t == 0x03 || t == 0x13 {
                    good += 1
                } else if t == 0x00 || t == 0x02 {
                    var fill = true
                    for j in 5..<16 where s[i + j] != 0x01 { fill = false; break }
                    if fill { good += 1 }
                }
                i += 16
            }
            if good > bestGood {
                best = p
                bestGood = good
            }
        }
        return best
    }

    /// Units at phase + 16k while a full unit exists.
    private mutating func units(_ p: UnsafeBufferPointer<UInt8>) {
        guard let base = p.baseAddress else { return }
        var i = 0
        if skip > 0 {
            let d = min(skip, p.count)
            skip -= d
            i = d
        }
        if !unit.isEmpty && i < p.count {
            let take = min(16 - unit.count, p.count - i)
            unit.append(contentsOf: UnsafeBufferPointer(start: base + i, count: take))
            i += take
            if unit.count == 16 {
                let u = unit
                unit.removeAll(keepingCapacity: true)
                u.withUnsafeBufferPointer { handleUnit($0.baseAddress!) }
            }
        }
        while i + 16 <= p.count {
            handleUnit(base + i)
            i += 16
        }
        if i < p.count { unit.append(contentsOf: UnsafeBufferPointer(start: base + i, count: p.count - i)) }
    }

    private mutating func nextOrder() -> Int {
        sequence += 1
        return sequence
    }

    @inline(__always)
    private mutating func handleUnit(_ u: UnsafePointer<UInt8>) {
        let t = u[0] & 0x1F
        let lane = Int(u[0] >> 5)
        switch t {
        case 0x00:
            counts.uFill += 1
        case 0x02:
            counts.uChan += 1
            lanes[lane] = Int32(u[1]) | Int32(u[2]) << 8
        case 0x13:
            counts.uStart += 1
            let key = lanes[lane]
            if let f = open.removeValue(forKey: key) { close(f.units, key: key) }
            var units: [UInt8] = []
            units.reserveCapacity(64)
            units.append(contentsOf: UnsafeBufferPointer(start: u, count: 16))
            open[key] = OpenFragment(units: units, order: nextOrder())
        case 0x03:
            counts.uCont += 1
            if open[lanes[lane]]?.units.append(contentsOf: UnsafeBufferPointer(start: u, count: 16)) == nil {
                counts.uContOrphan += 1
            }
        default:
            counts.uBadType += 1
        }
    }

    /// expected_units: how many continuation units a fragment of `length` bytes should have.
    static func expectedUnits(length: Int, pad: Int) -> Int {
        let r = length - (8 - pad)
        if r <= 0 { return 0 }
        let bursts = r / 240
        return 16 * bursts + (r - 240 * bursts + 11) / 12
    }

    /// assemble() without the bytes: how many continuation units it consumes and whether the fragment is complete.
    static func consumption(length: Int, pad: Int, conts n: Int) -> (used: Int, complete: Bool) {
        var r = length - (8 - pad)
        var k = 0
        while r >= 240 && k + 16 <= n {
            k += 16
            r -= 240
        }
        if r >= 240 { return (k, false) }
        while r > 0 && k < n {
            k += 1
            r -= 12
        }
        return (k, r <= 0)
    }

    /// assemble(): the fragment's payload, truncated to its length field. `u` is the start unit followed by the
    /// continuation units.
    static func assemble(_ u: UnsafeBufferPointer<UInt8>) -> [UInt8] {
        let cls = u[1]
        let pad = Int((cls >> 4) & 7)
        let length = Int(u[2]) | Int(u[3]) << 8
        let n = (u.count - 16) / 16
        var out: [UInt8] = []
        out.reserveCapacity(max(length, 8))
        out.append(contentsOf: UnsafeBufferPointer(rebasing: u[(8 + pad)..<16]))
        var r = length - out.count
        var k = 0
        while r >= 240 && k + 16 <= n {
            // Units 0-14 carry bytes 1..15 of a 16-byte line whose byte 0 the tag overwrote; unit 15 carries
            // those 15 displaced bytes.
            let displaced = 16 + 16 * (k + 15)
            for j in 0..<15 {
                out.append(u[displaced + 1 + j])
                let line = 16 + 16 * (k + j)
                out.append(contentsOf: UnsafeBufferPointer(rebasing: u[(line + 1)..<(line + 16)]))
            }
            k += 16
            r -= 240
        }
        if r < 240 {
            while r > 0 && k < n {
                let w = 16 + 16 * k
                if r < 12 {
                    // The last word unit: its ceil(R/4) valid words arrive in reverse order.
                    let words = (r + 3) / 4
                    for word in stride(from: words - 1, through: 0, by: -1) {
                        out.append(contentsOf: UnsafeBufferPointer(rebasing: u[(w + 4 + 4 * word)..<(w + 8 + 4 * word)]))
                    }
                } else {
                    out.append(contentsOf: UnsafeBufferPointer(rebasing: u[(w + 4)..<(w + 16)]))
                }
                k += 1
                r -= 12
            }
        }
        if out.count > length { out.removeSubrange(length...) }
        return out
    }

    /// One closed fragment: fit counters, then gathering by kind (1 whole, 2 QShrink, 3 first, 4 middle, 5 last).
    private mutating func close(_ units: [UInt8], key: Int32) {
        let cls = units[1]
        let kind = Int(cls & 0xF)
        let pad = Int((cls >> 4) & 7)
        let length = Int(units[2]) | Int(units[3]) << 8
        let conts = (units.count - 16) / 16
        let (used, complete) = Self.consumption(length: length, pad: pad, conts: conts)
        if !complete {
            counts.fitsShort += 1
        } else if used < conts {
            counts.fitsExtraUnits += 1
        } else {
            counts.fitsExact += 1
        }
        if Self.expectedUnits(length: length, pad: pad) != conts { counts.fitsCountMismatch += 1 }
        counts.kinds[kind] += 1
        if kind == 2 {
            counts.qshrinkF3 += 1
            return
        }
        let data = units.withUnsafeBufferPointer { Self.assemble($0) }
        switch kind {
        case 1:
            flushPending(key)
            emit(data, complete: complete, key: key, unterminated: false)
        case 3:
            flushPending(key)
            pending[key] = Pending(data: data, complete: complete, order: nextOrder())
        case 4, 5:
            guard pending[key] != nil else {
                counts.extra["gather_orphan_kind\(kind)", default: 0] += 1
                return
            }
            pending[key]!.data.append(contentsOf: data)
            pending[key]!.complete = pending[key]!.complete && complete
            if kind == 5, let p = pending.removeValue(forKey: key) {
                emit(p.data, complete: p.complete, key: key, unterminated: false)
            }
        default:
            counts.extra["gather_unknown_kind_\(kind)", default: 0] += 1
        }
    }

    /// A new whole or first fragment while a first[+middle] run is open on the key: emit the run as it stands.
    private mutating func flushPending(_ key: Int32) {
        guard let p = pending.removeValue(forKey: key) else { return }
        counts.gatherFlushed += 1
        emit(p.data, complete: p.complete, key: key, unterminated: true)
    }

    // MARK: Layer 3 (split_packets, classify)

    enum PacketKind: Int, CaseIterable {
        case empty, log, logBad, secure, secureBad, extmsg, qsr4, event, cmd, bare
        // other_0xNN is 16 + NN.

        var name: String {
            switch self {
            case .empty: "empty"
            case .log: "log"
            case .logBad: "log_bad"
            case .secure: "secure"
            case .secureBad: "secure_bad"
            case .extmsg: "extmsg_0x79"
            case .qsr4: "qsr4_0x99"
            case .event: "event_0x60"
            case .cmd: "cmd_0x9d"
            case .bare: "bare"
            }
        }

        static func name(_ raw: Int) -> String {
            if let k = PacketKind(rawValue: raw) { return k.name }
            return String(format: "other_0x%02x", raw - 16)
        }
    }

    private mutating func emit(_ msg: [UInt8], complete: Bool, key: Int32, unterminated: Bool) {
        if unterminated { counts.messagesUnterm += 1 } else { counts.messages += 1 }
        if !complete { counts.messagesIncomplete += 1 }
        msg.withUnsafeBufferPointer { m in
            let n = m.count
            if n >= 8 && m[0] == 0x98 && m[1] == 0x01 && m[2] == 0x00 && m[3] == 0x00 {
                let count = Int(m[4]) | Int(m[5]) << 8 | Int(m[6]) << 16 | Int(m[7]) << 24
                var off = 8
                var seen = 0
                while off < n && (seen < count || count == 0) {
                    if m[off] == 0x10 && off + 16 <= n {
                        let length = Int(m[off + 2]) | Int(m[off + 3]) << 8
                        packet(m, off, min(off + 4 + length, n), key: key, complete: complete, unterminated: unterminated)
                        off += 4 + length
                    } else {
                        packet(m, off, n, key: key, complete: complete, unterminated: unterminated)
                        break
                    }
                    seen += 1
                }
                return
            }
            packet(m, 0, n, key: key, complete: complete, unterminated: unterminated)
        }
    }

    @inline(__always)
    private static func u16(_ m: UnsafeBufferPointer<UInt8>, _ at: Int) -> Int { Int(m[at]) | Int(m[at + 1]) << 8 }

    @inline(__always)
    private static func u64(_ m: UnsafeBufferPointer<UInt8>, _ at: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(m[at + i]) << (8 * UInt64(i)) }
        return v
    }

    /// classify() on m[lo..<hi], then keep log and bare records and the secure census.
    private mutating func packet(_ m: UnsafeBufferPointer<UInt8>, _ lo: Int, _ hi: Int, key: Int32, complete: Bool,
                                 unterminated: Bool) {
        let n = hi - lo
        var kind: Int
        var code: UInt16 = 0, ts: UInt64 = 0, bodyStart = 0
        if n == 0 {
            kind = PacketKind.empty.rawValue
        } else {
            let c = m[lo]
            kind = -1
            if c == 0x10 {
                kind = PacketKind.logBad.rawValue
                if n >= 16 {
                    let outer = Self.u16(m, lo + 2), inner = Self.u16(m, lo + 4)
                    if outer == inner && inner == n - 4 {
                        kind = PacketKind.log.rawValue
                        code = UInt16(Self.u16(m, lo + 6))
                        ts = Self.u64(m, lo + 8)
                        bodyStart = lo + 16
                    }
                }
            } else if c == 0x9E && n >= 32 && m[lo + 1] == 0x01 && m[lo + 2] == 0xC2 && m[lo + 3] == 0x00 {
                if Self.u16(m, lo + 20) == n - 20 {
                    kind = PacketKind.secure.rawValue
                    code = UInt16(Self.u16(m, lo + 22))
                    ts = Self.u64(m, lo + 24)
                } else {
                    kind = PacketKind.secureBad.rawValue
                }
            } else if let named = Self.named(c) {
                kind = named.rawValue
            }
            if kind < 0 {
                if n >= 12 && Self.u16(m, lo) == n && Self.u16(m, lo + 2) != 0 {
                    kind = PacketKind.bare.rawValue
                    code = UInt16(Self.u16(m, lo + 2))
                    ts = Self.u64(m, lo + 4)
                    bodyStart = lo + 12
                } else {
                    kind = 16 + Int(c)
                }
            }
        }
        counts.packets[kind * 2 + (unterminated ? 1 : 0), default: 0] += 1
        if kind == PacketKind.log.rawValue || kind == PacketKind.bare.rawValue {
            records.append(LogRecord(code: code, timestampRaw: ts,
                                     body: Array(UnsafeBufferPointer(rebasing: m[bodyStart..<hi])), more: 0))
            recordKeys.append(key)
            if !complete { incompleteRecords += 1 }
            if counts.codeCounts[code] == nil { counts.codeOrder.append(code) }
            counts.codeCounts[code, default: 0] += 1
        } else if kind == PacketKind.secure.rawValue {
            secure.append(SecureRecord(code: code, timestampRaw: ts))
        }
    }

    private static func named(_ c: UInt8) -> PacketKind? {
        switch c {
        case 0x79: .extmsg
        case 0x99: .qsr4
        case 0x60: .event
        case 0x9D: .cmd
        default: nil
        }
    }

    /// ts_ok: a timestamp in the modem's 2026 range.
    static func plausible(_ ts: UInt64) -> Bool {
        let hi = ts >> 32
        return hi >= 0x0112_0000 && hi <= 0x0113_FFFF
    }

    // MARK: Output

    /// Ends the stream: flushes the fragments still open (in insertion order), then the gathered runs left open,
    /// and returns the records in effective-timestamp order with the Python's stats. Call once.
    public mutating func finish() -> DeframeOutput {
        if chunkOpen { endChunk() }
        if phase == nil { decidePhase() }
        unit.removeAll()
        let stillOpen = open.sorted { $0.value.order < $1.value.order }
        open = [:]
        for (key, f) in stillOpen { close(f.units, key: key) }
        let leftOpen = pending.sorted { $0.value.order < $1.value.order }
        pending = [:]
        for (key, p) in leftOpen {
            counts.gatherLeftOpen += 1
            emit(p.data, complete: p.complete, key: key, unterminated: true)
        }

        // Timestamps are monotonic within a channel but channels interleave with a lag: sort by an effective
        // timestamp, where a record without a plausible one inherits the last plausible one on its channel.
        var last: [Int32: UInt64] = [:]
        var effective = [UInt64](repeating: 0, count: records.count)
        var tsCounts: [String: Int] = [:]
        for i in records.indices {
            let ts = records[i].timestampRaw
            if Self.plausible(ts) {
                last[recordKeys[i]] = ts
                effective[i] = ts
                tsCounts["2026", default: 0] += 1
            } else {
                effective[i] = last[recordKeys[i]] ?? 0
                tsCounts[ts == 0 ? "zero" : "other", default: 0] += 1
            }
        }
        let order = records.indices.sorted { effective[$0] != effective[$1] ? effective[$0] < effective[$1] : $0 < $1 }
        let sorted = order.map { records[$0] }
        return DeframeOutput(records: sorted, secure: secure, stats: stats(ts: tsCounts))
    }

    private func stats(ts: [String: Int]) -> DeframeStats {
        var s: [String: Int] = ["phase": phase ?? 0]
        func put(_ name: String, _ v: Int) { if v > 0 { s[name] = v } }
        put("u_fill", counts.uFill)
        put("u_chan", counts.uChan)
        put("u_start", counts.uStart)
        put("u_cont", counts.uCont)
        put("u_cont_orphan", counts.uContOrphan)
        put("u_badtype", counts.uBadType)
        put("qshrink_f3", counts.qshrinkF3)
        put("messages", counts.messages)
        put("messages_unterm", counts.messagesUnterm)
        put("messages_incomplete", counts.messagesIncomplete)
        put("gather_flushed_unterminated", counts.gatherFlushed)
        put("gather_left_open", counts.gatherLeftOpen)
        for (k, v) in counts.extra { put(k, v) }

        var fits: [String: Int] = [:]
        if counts.fitsExact > 0 { fits["exact"] = counts.fitsExact }
        if counts.fitsShort > 0 { fits["short"] = counts.fitsShort }
        if counts.fitsExtraUnits > 0 { fits["extra_units"] = counts.fitsExtraUnits }
        if counts.fitsCountMismatch > 0 { fits["count_mismatch"] = counts.fitsCountMismatch }

        var kinds: [String: Int] = [:]
        for (k, v) in counts.kinds.enumerated() where v > 0 { kinds[String(k)] = v }

        var packets: [String: Int] = [:]
        for (key, v) in counts.packets {
            packets[PacketKind.name(key / 2) + (key % 2 == 1 ? "_unterm" : "")] = v
        }

        let targets: [UInt16] = [0xB0C0, 0xB0C1, 0xB0C2, 0xB0E2, 0xB0E3, 0xB0EC, 0xB0ED, 0xB0E4, 0xB0E5, 0xB821,
                                 0xB825, 0xB826, 0xB80A, 0xB80B, 0xB80C]
        var targetCounts: [String: Int] = [:]
        for t in targets { targetCounts[Fmt4.hex(t)] = counts.codeCounts[t] ?? 0 }
        // most_common(15): by count, ties in first-seen order.
        let top = counts.codeOrder.enumerated()
            .sorted { a, b in
                let ca = counts.codeCounts[a.element] ?? 0, cb = counts.codeCounts[b.element] ?? 0
                return ca != cb ? ca > cb : a.offset < b.offset
            }
            .prefix(15)
            .map { DeframeStats.CodeCount(code: Fmt4.hex($0.element), count: counts.codeCounts[$0.element] ?? 0) }

        return DeframeStats(atid32Bytes: streamBytes, chunks: chunkCount, counters: s, fits: fits, fragmentKinds: kinds,
                            packets: packets, logRecords: records.count, distinctCodes: counts.codeCounts.count, ts: ts,
                            incompleteRecords: incompleteRecords, targets: targetCounts, topCodes: Array(top))
    }
}

/// "0xB0C0": the Python's '0x%04X'.
enum Fmt4 {
    static func hex(_ code: UInt16) -> String { String(format: "0x%04X", code) }
}
