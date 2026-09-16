package com.fieldtap.ui.components

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import com.fieldtap.ui.theme.ShapeRoles
import com.fieldtap.ui.theme.Sizes
import com.fieldtap.ui.theme.Spacing

/**
 * A row of equal-width segments that picks which view of one screen is shown: "Signal · Cell · Around me"
 * on Live. The chosen segment wears the indigo `primaryContainer` pill, the same mark the bottom bar puts
 * under the chosen tab, so "where am I" reads the same way at both levels.
 *
 * It switches between views of one subject. It is not navigation (that is the bottom bar) and not a filter
 * over a list (that is a row of chips). Three or four segments at most: past that the labels stop fitting
 * and a list with headings is the honest shape.
 *
 * Every segment is at least [Sizes.MinTouchTarget] tall and announces itself to TalkBack as a tab with its
 * selected state ([Role.Tab] inside a [selectableGroup]), so a screen reader hears "Signal, tab, 1 of 3,
 * selected" rather than three unrelated buttons.
 *
 * Owner: workstream `ui-session`.
 */
@Composable
fun <T> ViewSwitcher(
    options: List<T>,
    selected: T,
    label: @Composable (T) -> String,
    onSelect: (T) -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = ShapeRoles.Pill,
        color = MaterialTheme.colorScheme.surfaceContainerHighest,
    ) {
        Row(
            modifier = Modifier
                .padding(Spacing.Xxs)
                .selectableGroup(),
        ) {
            options.forEach { option ->
                val isSelected = option == selected
                Surface(
                    modifier = Modifier
                        .weight(1f)
                        .selectable(
                            selected = isSelected,
                            role = Role.Tab,
                            onClick = { if (!isSelected) onSelect(option) },
                        ),
                    shape = ShapeRoles.Pill,
                    // The unselected segments are the track showing through, not their own surfaces.
                    color = if (isSelected) {
                        MaterialTheme.colorScheme.primaryContainer
                    } else {
                        androidx.compose.ui.graphics.Color.Transparent
                    },
                    contentColor = if (isSelected) {
                        MaterialTheme.colorScheme.onPrimaryContainer
                    } else {
                        MaterialTheme.colorScheme.onSurfaceVariant
                    },
                ) {
                    Box(
                        modifier = Modifier
                            .heightIn(min = Sizes.MinTouchTarget - Spacing.Xxs * 2)
                            .padding(horizontal = Spacing.Sm),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            text = label(option),
                            style = MaterialTheme.typography.labelLarge,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            textAlign = TextAlign.Center,
                        )
                    }
                }
            }
        }
    }
}
