package com.fieldtap.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import com.fieldtap.ui.theme.FieldTapDesign
import com.fieldtap.ui.theme.FieldTapIcons
import com.fieldtap.ui.theme.ShapeRoles
import com.fieldtap.ui.theme.SignalQuality
import com.fieldtap.ui.theme.Sizes
import com.fieldtap.ui.theme.Spacing
import com.fieldtap.ui.theme.StatusColors
import com.fieldtap.ui.theme.tabular

/** What a [SessionListRow]'s leading badge says about the session. */
enum class SessionRowStatus {
    /** Stopped by the user or by an app stop (storage full, permission revoked). */
    COMPLETED,

    /** The running session. */
    RECORDING,

    /** Closed by launch recovery after Android stopped the app. */
    INTERRUPTED,

    /** session.json could not be read; the row can still be opened and deleted. */
    UNREADABLE,
}

/**
 * One session in the Sessions list, one 72 dp touch target that opens it: the status badge; the name on one line, with
 * [trailing] beside it (the session's signal as a [SignalQualityChip], "Good -92", or [RecordingChip]); then one
 * secondary line of when it started, how long it ran and its size, joined by [separator]. On an INTERRUPTED or UNREADABLE
 * session a short [statusText] in the status colour takes the size's place. Both lines end in an ellipsis instead of
 * wrapping. The badge icon differs per status, so the status is not told by colour alone.
 *
 * TalkBack reads [contentDescription] for the row when it is given: pass the full status ("Interrupted by Android: low
 * memory") and the signal in words there. The row's texts stay in its semantics, so it can still be found by its name.
 *
 * @param startedText when it started, for example "Today 6:19 PM" or "Sep 9".
 * @param durationText [com.fieldtap.ui.theme.Formats.elapsed], for example "12:34".
 * @param sizeText [com.fieldtap.ui.theme.Formats.decimalBytes], for example "4.2 MB".
 */
@Composable
fun SessionListRow(
    title: String,
    startedText: String,
    separator: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    status: SessionRowStatus = SessionRowStatus.COMPLETED,
    durationText: String? = null,
    sizeText: String? = null,
    statusText: String? = null,
    contentDescription: String? = null,
    /** Overrides the badge icon, for a row that is not a drive: a signalling capture's waveform. */
    icon: ImageVector? = null,
    trailing: (@Composable () -> Unit)? = null,
) {
    val colors = FieldTapDesign.colors
    val (family: StatusColors, statusIcon: ImageVector) = when (status) {
        SessionRowStatus.COMPLETED -> colors.neutral to FieldTapIcons.File
        SessionRowStatus.RECORDING -> colors.recording to FieldTapIcons.Play
        SessionRowStatus.INTERRUPTED -> colors.warning to FieldTapIcons.Warning
        SessionRowStatus.UNREADABLE -> colors.error to FieldTapIcons.Error
    }
    val badgeIcon = icon ?: statusIcon
    val showStatus = statusText != null && (status == SessionRowStatus.INTERRUPTED || status == SessionRowStatus.UNREADABLE)
    val secondary = buildAnnotatedString {
        append(listOfNotNull(startedText, durationText).joinToString(separator))
        val tail = if (showStatus) statusText else sizeText
        if (tail != null) {
            append(separator)
            if (showStatus) withStyle(SpanStyle(color = family.color)) { append(tail) } else append(tail)
        }
    }
    Surface(
        onClick = onClick,
        modifier = modifier
            .fillMaxWidth()
            .semantics(mergeDescendants = true) { if (contentDescription != null) this.contentDescription = contentDescription },
        shape = ShapeRoles.Tile,
        color = MaterialTheme.colorScheme.surfaceContainerLow,
        shadowElevation = cardShadowElevation(),
        border = cardHairline(),
    ) {
        Row(
            modifier = Modifier
                .heightIn(min = Sizes.ListRowMinHeight)
                .padding(start = Spacing.Lg, end = Spacing.Md, top = Spacing.Md, bottom = Spacing.Md),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Spacing.Md),
        ) {
            Surface(shape = CircleShape, color = family.container, contentColor = family.onContainer) {
                Box(modifier = Modifier.size(Sizes.IconContainer), contentAlignment = Alignment.Center) {
                    Icon(imageVector = badgeIcon, contentDescription = null, modifier = Modifier.size(Sizes.IconSmall + Spacing.Xxs))
                }
            }
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(Spacing.Xxs),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Spacing.Sm)) {
                    Text(
                        text = title,
                        style = MaterialTheme.typography.titleMedium,
                        color = MaterialTheme.colorScheme.onSurface,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                    trailing?.invoke()
                }
                Text(
                    text = secondary,
                    style = MaterialTheme.typography.bodyMedium.tabular(),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Icon(
                imageVector = FieldTapIcons.ChevronRight,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(Sizes.IconSmall + Spacing.Xxs),
            )
        }
    }
}

/** "Recording" beside a pulsing dot, in the recording colour: the running session's chip in the Sessions list. */
@Composable
fun RecordingChip(label: String, modifier: Modifier = Modifier) {
    val family = FieldTapDesign.colors.recording
    Surface(modifier = modifier, shape = ShapeRoles.Pill, color = family.container, contentColor = family.onContainer) {
        Row(
            modifier = Modifier
                .heightIn(min = Sizes.BadgeMinHeight)
                .padding(start = Spacing.Sm, end = Spacing.Sm + Spacing.Xxs),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Spacing.Xs + Spacing.Xxs),
        ) {
            RecordingDot(color = family.onContainer, size = Sizes.Swatch)
            Text(text = label, style = MaterialTheme.typography.labelMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

@FieldTapPreviews
@Composable
private fun SessionListRowPreview() {
    PreviewSurface {
        SessionListRow(
            title = "Mall walk (north path)",
            startedText = "Today 2:30 PM",
            separator = " · ",
            status = SessionRowStatus.RECORDING,
            sizeText = "812 kB",
            onClick = {},
            trailing = { RecordingChip("Recording") },
        )
        SessionListRow(
            title = "Office to station",
            startedText = "Yesterday 9:12 AM",
            separator = " · ",
            durationText = "41:07",
            sizeText = "4.2 MB",
            onClick = {},
            trailing = { SignalQualityChip(SignalQuality.GOOD, "Good -92") },
        )
        SessionListRow(
            title = "Basement car park",
            startedText = "Wed 6:02 PM",
            separator = " · ",
            status = SessionRowStatus.INTERRUPTED,
            statusText = "Interrupted",
            durationText = "6:10",
            sizeText = "812 kB",
            onClick = {},
            trailing = { SignalQualityChip(SignalQuality.POOR, "Poor -112") },
        )
        SessionListRow(
            title = "20260908-101500_Test",
            startedText = "Sep 8",
            separator = " · ",
            status = SessionRowStatus.UNREADABLE,
            statusText = "Unreadable",
            sizeText = "96 kB",
            onClick = {},
            trailing = { SignalQualityChip(null, "No signal") },
        )
    }
}
