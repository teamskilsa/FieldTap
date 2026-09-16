package com.fieldtap.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.fieldtap.ui.theme.FieldTapDesign
import com.fieldtap.ui.theme.FieldTapIcons
import com.fieldtap.ui.theme.ShapeRoles
import com.fieldtap.ui.theme.Sizes
import com.fieldtap.ui.theme.Spacing
import com.fieldtap.ui.theme.StatusTone

/** Where a runtime permission stands. */
enum class PermissionStatus {
    /** Not asked yet: the action asks Android. */
    NOT_REQUESTED,

    GRANTED,

    /** Refused once; asking again is still possible. */
    DENIED,

    /** Android will not ask again: the action opens the app's settings. */
    DENIED_PERMANENTLY,
}

/**
 * One permission on the Permissions screen (and in Settings for "Instant cell updates"): what it is,
 * one sentence on why FieldTap needs it, where it stands, and the button that fixes it.
 *
 * - NOT_REQUESTED: a tonal button, for example "Allow" (the accent filled button when [emphasizeAction]).
 * - DENIED: an outlined button, for example "Ask again" (the accent filled button when [emphasizeAction]).
 * - DENIED_PERMANENTLY: an outlined button with the open-in-new icon, for example "Open app settings"
 *   (the accent filled button, icon kept, when [emphasizeAction]).
 * - GRANTED: no button; the status line says so with a check.
 *
 * @param tagText "Required" or "Optional".
 * @param statusText "Allowed", "Not allowed yet", "Refused".
 * @param tagTone the tone of the [tagText] pill: NEUTRAL by default; pass WARNING so a mandatory,
 *   not-yet-satisfied permission's "Required" badge reads as an attention tag.
 * @param emphasizeAction promotes the fix button to the screen's one accent filled primary (design §3),
 *   for the blocking permission that gates the flow. The optional permission stays a tonal button.
 */
@Composable
fun PermissionRationale(
    icon: ImageVector,
    title: String,
    reason: String,
    status: PermissionStatus,
    statusText: String,
    modifier: Modifier = Modifier,
    tagText: String? = null,
    tagTone: StatusTone = StatusTone.NEUTRAL,
    actionLabel: String? = null,
    onAction: (() -> Unit)? = null,
    emphasizeAction: Boolean = false,
) {
    val colors = FieldTapDesign.colors
    val tagColors = colors.status(tagTone)
    val (statusIcon, statusColor) = when (status) {
        PermissionStatus.GRANTED -> FieldTapIcons.CheckCircle to colors.success.color
        PermissionStatus.NOT_REQUESTED -> FieldTapIcons.Info to MaterialTheme.colorScheme.onSurfaceVariant
        PermissionStatus.DENIED, PermissionStatus.DENIED_PERMANENTLY -> FieldTapIcons.Warning to colors.warning.color
    }
    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = ShapeRoles.Card,
        color = MaterialTheme.colorScheme.surfaceContainerLow,
        shadowElevation = cardShadowElevation(),
        border = cardHairline(),
    ) {
        Row(
            modifier = Modifier.padding(Spacing.CardPadding),
            horizontalArrangement = Arrangement.spacedBy(Spacing.Lg),
        ) {
            Surface(
                // A neutral tonal circle, not an accent-tinted one: the accent stays on the fix button.
                shape = CircleShape,
                color = MaterialTheme.colorScheme.secondaryContainer,
                contentColor = MaterialTheme.colorScheme.onSecondaryContainer,
            ) {
                Box(modifier = Modifier.size(Sizes.IconContainer), contentAlignment = Alignment.Center) {
                    Icon(imageVector = icon, contentDescription = null, modifier = Modifier.size(Sizes.Icon))
                }
            }
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(Spacing.Sm),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Spacing.Sm)) {
                    Text(
                        text = title,
                        style = MaterialTheme.typography.titleMedium,
                        color = MaterialTheme.colorScheme.onSurface,
                        modifier = Modifier
                            .weight(1f, fill = false)
                            .semantics { heading() },
                    )
                    if (tagText != null) {
                        Surface(shape = ShapeRoles.Pill, color = tagColors.container, contentColor = tagColors.onContainer) {
                            Text(
                                text = tagText,
                                style = MaterialTheme.typography.labelSmall,
                                modifier = Modifier.padding(horizontal = Spacing.Sm, vertical = Spacing.Xxs),
                            )
                        }
                    }
                }
                Text(text = reason, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Row(
                    modifier = Modifier.semantics(mergeDescendants = true) {},
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(Spacing.Xs + Spacing.Xxs),
                ) {
                    Icon(imageVector = statusIcon, contentDescription = null, tint = statusColor, modifier = Modifier.size(Sizes.IconSmall))
                    Text(text = statusText, style = MaterialTheme.typography.labelLarge, color = statusColor)
                }
                if (status != PermissionStatus.GRANTED && actionLabel != null && onAction != null) {
                    val buttonModifier = Modifier
                        .padding(top = Spacing.Xs)
                        .heightIn(min = Sizes.MinTouchTarget)
                    val showOpenIcon = status == PermissionStatus.DENIED_PERMANENTLY
                    when {
                        // The blocking permission's fix is the one accent filled primary, so the eye lands on it.
                        emphasizeAction -> Button(
                            onClick = onAction,
                            shape = ShapeRoles.Control,
                            modifier = buttonModifier,
                            contentPadding = if (showOpenIcon) ButtonDefaults.ButtonWithIconContentPadding else ButtonDefaults.ContentPadding,
                        ) {
                            if (showOpenIcon) {
                                Icon(
                                    imageVector = FieldTapIcons.OpenInNew,
                                    contentDescription = null,
                                    modifier = Modifier.size(ButtonDefaults.IconSize),
                                )
                                Box(modifier = Modifier.size(ButtonDefaults.IconSpacing))
                            }
                            Text(text = actionLabel)
                        }
                        status == PermissionStatus.NOT_REQUESTED -> FilledTonalButton(onClick = onAction, shape = ShapeRoles.Control, modifier = buttonModifier) {
                            Text(text = actionLabel)
                        }
                        else -> OutlinedButton(
                            onClick = onAction,
                            shape = ShapeRoles.Control,
                            modifier = buttonModifier,
                            border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline),
                            contentPadding = ButtonDefaults.ButtonWithIconContentPadding,
                        ) {
                            if (showOpenIcon) {
                                Icon(
                                    imageVector = FieldTapIcons.OpenInNew,
                                    contentDescription = null,
                                    modifier = Modifier.size(ButtonDefaults.IconSize),
                                )
                                Box(modifier = Modifier.size(ButtonDefaults.IconSpacing))
                            }
                            Text(text = actionLabel)
                        }
                    }
                }
            }
        }
    }
}

/**
 * The limits statement, word for word: what FieldTap reads and what it does not. Pass
 * `stringResource(R.string.limits_statement)` as [statement] unchanged; the card never truncates it.
 * Shown on the disclosure, About and the Live screen's first-run state.
 */
@Composable
fun LimitsStatementCard(
    title: String,
    statement: String,
    modifier: Modifier = Modifier,
) {
    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = ShapeRoles.Card,
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
    ) {
        Row(
            modifier = Modifier.padding(Spacing.CardPadding),
            horizontalArrangement = Arrangement.spacedBy(Spacing.Md),
        ) {
            Icon(
                imageVector = FieldTapIcons.Info,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(Sizes.Icon),
            )
            Column(verticalArrangement = Arrangement.spacedBy(Spacing.Xs)) {
                Text(
                    text = title,
                    style = MaterialTheme.typography.titleSmall,
                    color = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.semantics { heading() },
                )
                Text(text = statement, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurface)
            }
        }
    }
}

@FieldTapPreviews
@Composable
private fun PermissionRationalePreview() {
    PreviewSurface {
        PermissionRationale(
            icon = FieldTapIcons.Location,
            title = "Precise location",
            reason = "Android returns no cell information without it. Approximate location is not enough.",
            status = PermissionStatus.NOT_REQUESTED,
            statusText = "Not allowed yet",
            tagText = "Required",
            tagTone = StatusTone.WARNING,
            actionLabel = "Allow",
            onAction = {},
            emphasizeAction = true,
        )
        PermissionRationale(
            icon = FieldTapIcons.Notifications,
            title = "Notifications",
            reason = "Shows Stop and Mark while a session runs.",
            status = PermissionStatus.DENIED_PERMANENTLY,
            statusText = "Refused",
            tagText = "Recommended",
            actionLabel = "Open app settings",
            onAction = {},
        )
        PermissionRationale(
            icon = FieldTapIcons.Phone,
            title = "Phone",
            reason = "Lets Android push cell updates as they happen.",
            status = PermissionStatus.GRANTED,
            statusText = "Allowed",
            tagText = "Optional",
        )
        LimitsStatementCard(
            title = "What FieldTap reads",
            statement = "Reads what Android exposes: cell identity, RSRP/RSRQ/SINR, band, ARFCN, service state, plus ping and download tests. That needs no root, and it is all this app does until you turn on signalling capture. Signalling capture reads RRC and NAS from the modem itself and needs a rooted phone; it is off unless you switch it on. Neither mode can lock bands or cells or scan operators.",
        )
    }
}
