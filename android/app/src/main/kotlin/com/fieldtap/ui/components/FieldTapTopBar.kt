package com.fieldtap.ui.components

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.layout.RowScope
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.IconToggleButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.TopAppBarScrollBehavior
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import com.fieldtap.R
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextOverflow
import com.fieldtap.ui.theme.FieldTapIcons
import com.fieldtap.ui.theme.LocalReducedMotion
import com.fieldtap.ui.theme.Motion
import com.fieldtap.ui.theme.Sizes

/**
 * How a [FieldTapTopBar] follows the content scrolled under it: pinned, its container turns `surfaceContainer` once the
 * content has scrolled, so the bar and the cards moving beneath it stay apart. Create it with [rememberTopBarScroll],
 * pass it to the bar, and put `Modifier.nestedScroll(scroll.connection)` on the Scaffold.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Stable
class TopBarScroll internal constructor(internal val behavior: TopAppBarScrollBehavior) {
    /** For `Modifier.nestedScroll` on the screen's Scaffold. */
    val connection: NestedScrollConnection get() = behavior.nestedScrollConnection
}

/** A pinned [TopBarScroll], remembered across recompositions. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun rememberTopBarScroll(): TopBarScroll {
    val behavior = TopAppBarDefaults.pinnedScrollBehavior()
    return remember(behavior) { TopBarScroll(behavior) }
}

/**
 * The top app bar of every screen: title, an optional back arrow, and actions. It keeps Material's
 * experimental opt-in in one place, so screens need none. Pass it to `Scaffold(topBar = ...)`, with a
 * [TopBarScroll] when the content under it scrolls.
 *
 * The back arrow shows whenever [onNavigateUp] is given, described "Back" unless
 * [navigateUpContentDescription] says otherwise (a full-screen dialog passes "Cancel", with
 * [FieldTapIcons.Close] as [navigationIcon]). The description used to be required alongside the callback,
 * and a screen that passed only the callback silently lost its back arrow — a missing description is a
 * TalkBack bug, not a reason to strand the user. Use [TopBarAction] and [TopBarToggleAction] for actions,
 * at most three plus an overflow menu.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FieldTapTopBar(
    title: String,
    modifier: Modifier = Modifier,
    onNavigateUp: (() -> Unit)? = null,
    navigateUpContentDescription: String = stringResource(R.string.action_back),
    scroll: TopBarScroll? = null,
    navigationIcon: ImageVector = FieldTapIcons.ArrowBack,
    actions: @Composable RowScope.() -> Unit = {},
) {
    // The bar is the canvas ground; once content scrolls under it a 1 px hairline fades in to keep the
    // bar and the cards moving beneath it apart (a shadow does not read on the bright ground; the hairline does).
    val overlapped = (scroll?.behavior?.state?.overlappedFraction ?: 0f) > 0.01f
    val hairlineAlpha by animateFloatAsState(
        targetValue = if (overlapped) 1f else 0f,
        animationSpec = Motion.effect(LocalReducedMotion.current),
        label = "topBarHairline",
    )
    val hairlineColor = MaterialTheme.colorScheme.outlineVariant
    TopAppBar(
        title = { Text(text = title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        modifier = modifier.drawBehind {
            if (hairlineAlpha > 0f) {
                val stroke = Sizes.HairlineWidth.toPx()
                val y = size.height - stroke / 2f
                drawLine(
                    color = hairlineColor.copy(alpha = hairlineAlpha),
                    start = Offset(0f, y),
                    end = Offset(size.width, y),
                    strokeWidth = stroke,
                )
            }
        },
        scrollBehavior = scroll?.behavior,
        navigationIcon = {
            if (onNavigateUp != null) {
                IconButton(onClick = onNavigateUp) {
                    Icon(imageVector = navigationIcon, contentDescription = navigateUpContentDescription)
                }
            }
        },
        actions = actions,
        colors = TopAppBarDefaults.topAppBarColors(
            containerColor = MaterialTheme.colorScheme.surface,
            scrolledContainerColor = MaterialTheme.colorScheme.surface,
            navigationIconContentColor = MaterialTheme.colorScheme.onSurface,
            titleContentColor = MaterialTheme.colorScheme.onSurface,
            actionIconContentColor = MaterialTheme.colorScheme.onSurfaceVariant,
        ),
    )
}

/** A 48 dp icon action for [FieldTapTopBar]; [contentDescription] is required because it has no text. */
@Composable
fun TopBarAction(
    icon: ImageVector,
    contentDescription: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    IconButton(onClick = onClick, modifier = modifier, enabled = enabled) {
        Icon(imageVector = icon, contentDescription = contentDescription)
    }
}

/**
 * A 48 dp icon that turns a mode on or off, for [FieldTapTopBar] or an action rail: walk mode on Live. When on, the icon
 * sits in a tonal circle, so the state shows by shape as well as by colour. TalkBack reads [contentDescription] ("Walk
 * mode") with [stateDescription] ("On" or "Off").
 */
@Composable
fun TopBarToggleAction(
    icon: ImageVector,
    contentDescription: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    stateDescription: String,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    IconToggleButton(
        checked = checked,
        onCheckedChange = onCheckedChange,
        modifier = modifier.semantics { this.stateDescription = stateDescription },
        enabled = enabled,
        colors = IconButtonDefaults.iconToggleButtonColors(
            checkedContainerColor = MaterialTheme.colorScheme.primaryContainer,
            checkedContentColor = MaterialTheme.colorScheme.onPrimaryContainer,
        ),
    ) {
        Icon(imageVector = icon, contentDescription = contentDescription)
    }
}

@FieldTapPreviews
@Composable
private fun FieldTapTopBarPreview() {
    PreviewSurface {
        FieldTapTopBar(
            title = "Session detail",
            onNavigateUp = {},
            navigateUpContentDescription = "Back",
            actions = {
                TopBarAction(icon = FieldTapIcons.Share, contentDescription = "Share", onClick = {})
                TopBarAction(icon = FieldTapIcons.Delete, contentDescription = "Delete", onClick = {})
            },
        )
        FieldTapTopBar(
            title = "Live",
            actions = {
                TopBarToggleAction(icon = FieldTapIcons.Walk, contentDescription = "Walk mode", checked = true, onCheckedChange = {}, stateDescription = "On")
                TopBarAction(icon = FieldTapIcons.Sessions, contentDescription = "Sessions", onClick = {})
                TopBarAction(icon = FieldTapIcons.Tune, contentDescription = "Settings", onClick = {})
            },
        )
    }
}
