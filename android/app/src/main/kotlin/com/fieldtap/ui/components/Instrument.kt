package com.fieldtap.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.fieldtap.ui.theme.tabular
import java.util.Locale

/**
 * The container of the instrument screens (Signal, the call flow): a flat dark panel with a hairline and a
 * small uppercase title. No shadow — on a near-black ground a shadow is invisible and a hairline is what
 * separates things.
 *
 * Owner: workstream `ui-session`.
 */
@Composable
fun InstrumentPanel(
    modifier: Modifier = Modifier,
    title: String? = null,
    count: Int? = null,
    accent: Color? = null,
    trailing: (@Composable () -> Unit)? = null,
    content: @Composable () -> Unit,
) {
    Surface(
        shape = RoundedCornerShape(14.dp),
        color = MaterialTheme.colorScheme.surfaceContainerLow,
        border = BorderStroke(1.dp, accent?.copy(alpha = 0.45f) ?: MaterialTheme.colorScheme.outlineVariant),
        modifier = modifier.fillMaxWidth(),
    ) {
        Column(modifier = Modifier.padding(horizontal = 14.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            if (title != null) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        title.uppercase(Locale.ROOT),
                        style = MaterialTheme.typography.labelMedium.copy(letterSpacing = 1.2.sp, fontWeight = FontWeight.SemiBold),
                        color = accent ?: MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    if (count != null) {
                        Text(
                            "  $count",
                            style = MaterialTheme.typography.labelMedium.tabular(),
                            color = MaterialTheme.colorScheme.outline,
                        )
                    }
                    if (trailing != null) {
                        Spacer(Modifier.weight(1f))
                        trailing()
                    }
                }
            }
            content()
        }
    }
}

/** A small tinted label: "LTE", "B3", "UL-DCCH". */
@Composable
fun InstrumentTag(text: String, color: Color, modifier: Modifier = Modifier) {
    Surface(shape = RoundedCornerShape(6.dp), color = color.copy(alpha = 0.14f), modifier = modifier) {
        Text(
            text,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp),
            style = MaterialTheme.typography.labelLarge.copy(fontWeight = FontWeight.Bold),
            color = color,
        )
    }
}
