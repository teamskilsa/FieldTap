package com.fieldtap

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.fieldtap.app.appGraph
import com.fieldtap.ui.FieldTapTheme
import com.fieldtap.ui.nav.FieldTapNavHost

/**
 * The only visible activity, and the launcher entry point. It draws edge to edge in the FieldTap theme and
 * hosts the whole navigation graph; sessions are started from its Live screen while it is visible, which is
 * what lets the location foreground service start.
 *
 * Owner: workstream `ui-session`.
 */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val graph = appGraph
        setContent {
            // Always the instrument panel, whatever the phone is set to: the values are the product,
            // and they read best as the brightest thing on a dark ground.
            FieldTapTheme(darkTheme = true) {
                FieldTapNavHost(graph = graph)
            }
        }
    }
}
