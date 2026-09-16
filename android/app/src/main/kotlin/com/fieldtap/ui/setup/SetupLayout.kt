package com.fieldtap.ui.setup

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import com.fieldtap.R
import com.fieldtap.ui.components.FieldTapTopBar
import com.fieldtap.ui.components.rememberTopBarScroll
import com.fieldtap.ui.theme.Sizes
import com.fieldtap.ui.theme.Spacing

/** Caps one item of a setup screen at [Sizes.MaxContentWidth]; the screen's column centres it on wide windows. */
internal fun Modifier.setupContentWidth(): Modifier = widthIn(max = Sizes.MaxContentWidth).fillMaxWidth()

/**
 * The frame of every setup screen, following the design system's screen recipe: a [FieldTapTopBar] (none when
 * [title] is null), an optional snackbar host and bottom bar, and a lazy column with the screen gutter,
 * [Spacing.SectionGap] between items and content centred on wide windows. Items should use [setupContentWidth].
 * The column pads for the keyboard, so text fields near the bottom stay visible.
 */
@Composable
internal fun SetupScreenScaffold(
    title: String?,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
    snackbarHostState: SnackbarHostState? = null,
    actions: @Composable RowScope.() -> Unit = {},
    bottomBar: @Composable () -> Unit = {},
    content: LazyListScope.() -> Unit,
) {
    val backDescription = stringResource(R.string.setup_back)
    val topBarScroll = rememberTopBarScroll()
    Scaffold(
        modifier = modifier.nestedScroll(topBarScroll.connection),
        topBar = {
            if (title != null) {
                FieldTapTopBar(
                    scroll = topBarScroll,
                    title = title,
                    onNavigateUp = onBack,
                    // The setup screens keep their own "Back", so the setup wording rule covers every
                    // string they show rather than most of them.
                    navigateUpContentDescription = backDescription,
                    actions = actions,
                )
            }
        },
        bottomBar = bottomBar,
        snackbarHost = {
            if (snackbarHostState != null) SnackbarHost(hostState = snackbarHostState)
        },
    ) { padding ->
        BoxWithConstraints(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .consumeWindowInsets(padding)
                .imePadding(),
        ) {
            val gutter = if (maxWidth >= Sizes.WideLayoutMinWidth) Spacing.ScreenGutterWide else Spacing.ScreenGutter
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(start = gutter, top = Spacing.Sm, end = gutter, bottom = Spacing.Xxl),
                verticalArrangement = Arrangement.spacedBy(Spacing.SectionGap),
                horizontalAlignment = Alignment.CenterHorizontally,
                content = content,
            )
        }
    }
}

/** A heading inside a card ("Ping", "Download"): title style, and a TalkBack heading. */
@Composable
internal fun SetupSubheading(text: String, modifier: Modifier = Modifier) {
    Text(
        text = text,
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.onSurface,
        modifier = modifier.semantics { heading() },
    )
}

/** Secondary prose inside a card. */
@Composable
internal fun SetupParagraph(text: String, modifier: Modifier = Modifier) {
    Text(
        text = text,
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = modifier,
    )
}

/** A small spinner in the button's content colour, shown before the label while the button's work runs. */
@Composable
internal fun ButtonProgress(modifier: Modifier = Modifier) {
    CircularProgressIndicator(
        modifier = modifier.size(Sizes.InlineProgress),
        color = LocalContentColor.current,
        strokeWidth = Spacing.Xxs,
    )
}
