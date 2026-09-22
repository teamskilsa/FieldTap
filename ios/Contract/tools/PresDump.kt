package com.fieldtap.ui.signalling

import com.fieldtap.diag.CallFlow
import com.fieldtap.diag.q
import com.fieldtap.diag.scrub
import java.io.File

// Golden for android/app/.../ui/signalling/CallFlowPresentation.kt over a .qmdl: ladder rows per filter, procedure
// groups, lanes and the formatted strings the ladder shows. Scrubbed like GoldenDump (no field values at all here).
fun main(args: Array<String>) {
    val flow = CallFlow.read(File(args[0]).readBytes())
    val sb = StringBuilder("{\n")
    for (filter in FlowFilter.values()) {
        val rows = CallFlowPresentation.rows(flow, filter)
        sb.append("\"rows${filter}\":[\n")
        sb.append(rows.joinToString(",\n") { r ->
            when (r) {
                is LadderRow.Move -> "{\"type\":\"move\",\"key\":${q(r.key)},\"move\":\"${r.step.move}\",\"to\":${q(CallFlowPresentation.shortCell(r.step.to))},\"band\":${q(CallFlowPresentation.band(r.step.to))},\"downlink\":${q(CallFlowPresentation.downlinkMhz(r.step.to))}}"
                is LadderRow.ProcedureStart -> "{\"type\":\"procedure\",\"key\":${q(r.key)},\"name\":${q(r.procedure.name)},\"outcome\":\"${r.procedure.outcome}\",\"duration\":${q(CallFlowPresentation.duration(r.procedure.durationMs))}}"
                is LadderRow.Message -> "{\"type\":\"message\",\"key\":${q(r.key)},\"name\":${q(r.event.name)},\"count\":${r.count},\"mixed\":${r.mixed},\"cells\":${q(CallFlowPresentation.cellsOf(r))},\"cellCount\":${CallFlowPresentation.cellCount(r)},\"since\":${q(CallFlowPresentation.sinceStart(r.event.sinceStartMs))},\"gap\":${CallFlowPresentation.gap(flow.events, r.event.index)?.let { q(CallFlowPresentation.duration(it)) } ?: "null"}}"
            }
        })
        sb.append("\n],\n")
    }
    val lanes = CallFlowPresentation.lanes(flow)
    sb.append("\"lanes\":{\"phone\":${q(lanes.phone)},\"ran\":${q(lanes.ran)},\"core\":${q(lanes.core)}},\n")
    sb.append("\"procedureGroups\":[\n" + CallFlowPresentation.procedureGroups(flow).joinToString(",\n") { g ->
        "{\"name\":${q(g.name)},\"layer\":\"${g.layer}\",\"n\":${g.items.size},\"succeeded\":${g.succeeded},\"failed\":${g.failed},\"unanswered\":${g.unanswered},\"median\":${g.medianMs?.let { q(CallFlowPresentation.duration(it)) } ?: "null"}}"
    } + "\n]\n}\n")
    File(args[1]).writeText(sb.toString())
    println("rows ALL=${CallFlowPresentation.rows(flow, FlowFilter.ALL).size} RRC=${CallFlowPresentation.rows(flow, FlowFilter.RRC).size} NAS=${CallFlowPresentation.rows(flow, FlowFilter.NAS).size} groups=${CallFlowPresentation.procedureGroups(flow).size} lanes=$lanes")
}
