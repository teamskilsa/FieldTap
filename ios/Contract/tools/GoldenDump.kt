package com.fieldtap.diag

import java.io.File

// Golden fixtures for a Swift port: runs FieldTap's Kotlin decoders (android/diag, plus the v30 LTE / v26 NR
// header layouts) over a recovered iPhone .qmdl and writes scrubbed JSON. Nothing is printed except counts and
// field *labels*; values that can identify the subscriber or the handset are replaced with "<masked>".
//
// usage: GoldenDumpKt <in.qmdl> <outDir> [--census]

private val IDENTITY_LABEL = Regex(
    "(?i)(^identity$|imsi|imei|tmsi|guti|suci|supi|msisdn|mobile identity|ue identity|i-rnti|s-tmsi|random ?value|" +
        "address|\\bip\\b|ipv4|ipv6|dns|p-cscf|pcscf|interface identifier|cell identity|\\bnci\\b|\\beci\\b)"
)
private val DIGITS = Regex("\\+?\\d[\\d ]{8,}\\d")                       // IMSI / IMEI / MSISDN-like runs
private val IPV4 = Regex("\\b\\d{1,3}(\\.\\d{1,3}){3}\\b")
private val IPV6 = Regex("(?i)\\b([0-9a-f]{1,4}:){2,7}[0-9a-f:]{1,4}\\b|::[0-9a-f]{1,4}")
private val HEX_ID = Regex("(?i)0x[0-9a-f]{8,}")                         // TMSI / 5G-S-TMSI / identities printed as hex

val maskedByLabel = sortedMapOf<String, Int>()
var scrubbedStrings = 0

fun scrub(s: String?): String? {
    if (s == null) return null
    var t = s
    for (r in listOf(IPV6, IPV4, DIGITS, HEX_ID)) t = r.replace(t!!, "<masked>")
    if (t != s) scrubbedStrings++
    return t
}

fun maskField(parentMasked: Boolean, f: Field): Triple<String, String, List<Any>> {
    val masked = parentMasked || IDENTITY_LABEL.containsMatchIn(f.label)
    if (masked) maskedByLabel[f.label] = (maskedByLabel[f.label] ?: 0) + 1
    val value = if (masked && f.children.isEmpty()) "<masked>" else scrub(f.value)!!
    return Triple(f.label, value, f.children.map { maskField(masked, it) })
}

fun q(s: String?): String = if (s == null) "null" else buildString {
    append('"')
    for (c in s) when (c) {
        '"' -> append("\\\""); '\\' -> append("\\\\"); '\n' -> append("\\n"); '\r' -> append("\\r"); '\t' -> append("\\t")
        else -> if (c < ' ') append("\\u%04x".format(c.code)) else append(c)
    }
    append('"')
}

fun num(d: Double) = "%.3f".format(java.util.Locale.ROOT, d)

fun fieldJson(t: Triple<String, String, List<Any>>): String {
    @Suppress("UNCHECKED_CAST")
    val kids = (t.third as List<Triple<String, String, List<Any>>>)
    return "{\"label\":${q(t.first)},\"value\":${q(t.second)}" + (if (kids.isEmpty()) "" else ",\"children\":[" + kids.joinToString(",") { fieldJson(it) } + "]") + "}"
}

fun cellJson(c: CallFlow.Cell?): String = if (c == null) "null" else "{\"earfcn\":${c.earfcn},\"pci\":${c.pci},\"nr\":${c.nr}}"

fun main(args: Array<String>) {
    val bytes = File(args[0]).readBytes()
    val out = File(args[1]).apply { mkdirs() }
    val census = args.contains("--census")

    // Parse-level golden: record count per log code, via Unframer + Protocol, exactly as CallFlow.read sees them.
    val u = Unframer()
    val perCode = sortedMapOf<Int, Int>()
    var records = 0; var badPackets = 0; var frames = 0
    for (f in u.feed(bytes)) {
        frames++
        for (p in Protocol.logPacketsOf(f)) {
            val r = try { Protocol.parseLogPacket(p) } catch (e: IllegalArgumentException) { badPackets++; continue }
            records++; perCode[r.code] = (perCode[r.code] ?: 0) + 1
        }
    }

    val t0 = System.nanoTime()
    val flow = CallFlow.read(bytes)
    val readMs = (System.nanoTime() - t0) / 1e6

    if (census) {
        val labels = sortedMapOf<String, Int>()
        fun walk(f: Field, depth: Int) { labels["  ".repeat(depth) + f.label] = (labels["  ".repeat(depth) + f.label] ?: 0) + 1; f.children.forEach { walk(it, depth + 1) } }
        flow.events.forEach { e -> e.fields.forEach { walk(it, 0) } }
        println("field labels (label -> occurrences):"); labels.forEach { (k, v) -> println("  $k  x$v") }
        return
    }

    val sb = StringBuilder()
    sb.append("{\n\"source\":{\"file\":\"iphone-recovered.qmdl\",\"bytes\":${bytes.size},\"hdlcFrames\":$frames,\"crcErrors\":${u.crcErrors},\"logRecords\":$records,\"badPackets\":$badPackets},\n")
    sb.append("\"decoder\":\"FieldTap android/diag (Kotlin) + LteRrc v30 layout E + NrRrc v26 layout E (see lterrc_v30.diff, nrrrc_v26.diff)\",\n")
    sb.append("\"masking\":\"field values whose label matches IDENTITY_LABEL (and all their children) -> <masked>; in every other string, IPv4/IPv6, 10+ digit runs and 0x-hex of 8+ digits -> <masked>. pdu bytes are omitted (pduLength only).\",\n")
    sb.append("\"flow\":{\"records\":${flow.records},\"undecoded\":${flow.undecoded},\"crcErrors\":${flow.crcErrors},\"durationMs\":${num(flow.durationMs)},\"startUtcKnown\":${flow.startUtcMs != null},\"failures\":${flow.failures}},\n")
    sb.append("\"events\":[\n")
    sb.append(flow.events.joinToString(",\n") { e ->
        val fields = e.fields.map { maskField(false, it) }.joinToString(",") { fieldJson(it) }
        val prot = e.protection?.let { "{\"headerType\":${it.headerType},\"headerName\":${q(it.headerName)},\"sequence\":${it.sequence}}" } ?: "null"
        "{\"index\":${e.index},\"record\":${e.record},\"logCode\":\"0x%04X\",".format(e.logCode) +
            "\"timestampRaw\":${e.timestampRaw},\"sinceStartMs\":${num(e.sinceStartMs)},\"layer\":\"${e.layer}\",\"rat\":${q(e.rat)},\"uplink\":${e.uplink}," +
            "\"channel\":${q(e.channel)},\"key\":${q(e.key)},\"name\":${q(e.name)},\"summary\":${q(scrub(e.summary))},\"cell\":${cellJson(e.cell)}," +
            "\"cause\":${e.cause},\"causeName\":${q(e.causeName)},\"protection\":$prot,\"ciphered\":${e.ciphered},\"isFailure\":${e.isFailure}," +
            "\"isHandoverCommand\":${e.isHandoverCommand},\"carrier\":${q(e.carrier)},\"pduLength\":${e.pdu.size},\"fields\":[$fields]}"
    })
    sb.append("\n],\n\"procedures\":[\n")
    sb.append(flow.procedures.joinToString(",\n") { p ->
        "{\"name\":${q(p.name)},\"layer\":\"${p.layer}\",\"detail\":${q(scrub(p.detail))},\"first\":${p.first},\"last\":${p.last},\"outcome\":\"${p.outcome}\",\"durationMs\":${num(p.durationMs)},\"refusal\":${q(scrub(p.refusal))}}"
    })
    sb.append("\n],\n\"journey\":[\n")
    sb.append(flow.journey.joinToString(",\n") { s -> "{\"move\":\"${s.move}\",\"from\":${cellJson(s.from)},\"to\":${cellJson(s.to)},\"event\":${s.event},\"sinceStartMs\":${num(s.sinceStartMs)}}" })
    sb.append("\n],\n\"searched\":[" + flow.searched.joinToString(",") { cellJson(it) } + "],\n")
    sb.append("\"connections\":[\n")
    sb.append(flow.connections.joinToString(",\n") { c ->
        "{\"first\":${c.first},\"last\":${c.last},\"establishmentCause\":${q(c.establishmentCause)},\"releaseCause\":${q(c.releaseCause)},\"outcome\":\"${c.outcome}\",\"startMs\":${num(c.startMs)},\"endMs\":${c.endMs?.let { num(it) }},\"established\":${c.established}}"
    })
    sb.append("\n],\n\"cellDetails\":[\n")
    sb.append(flow.cellDetails.entries.joinToString(",\n") { (cell, s) ->
        "{\"cell\":${cellJson(cell)},\"pci\":${s.pci},\"downlinkEarfcn\":${s.downlinkEarfcn},\"uplinkEarfcn\":${s.uplinkEarfcn},\"band\":${s.band},\"plmn\":${q(s.plmn)},\"tac\":${s.tac},\"cellIdentity\":\"<masked>\",\"bandwidthMhz\":${s.bandwidthMhz}}"
    })
    sb.append("\n],\n\"recordsPerCode\":{" + perCode.entries.joinToString(",") { "\"0x%04X\":%d".format(it.key, it.value) } + "}\n}\n")
    File(out, "callflow-golden.json").writeText(sb.toString())

    println("readMs=${"%.0f".format(readMs)} frames=$frames crcErrors=${u.crcErrors} records=$records badPackets=$badPackets distinctCodes=${perCode.size}")
    println("events=${flow.events.size} procedures=${flow.procedures.size} journey=${flow.journey.size} searched=${flow.searched.size} connections=${flow.connections.size} cellDetails=${flow.cellDetails.size} undecoded=${flow.undecoded}")
    println("byLayerRatDir=" + flow.events.groupingBy { "${it.layer}/${it.rat}/${if (it.uplink) "UL" else "DL"}" }.eachCount().toSortedMap())
    println("maskedByLabel=$maskedByLabel scrubbedStrings=$scrubbedStrings")
}
