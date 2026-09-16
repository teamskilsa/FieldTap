package com.fieldtap.ui.nav

import androidx.annotation.StringRes
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.dropUnlessResumed
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavDestination
import androidx.navigation.NavDestination.Companion.hierarchy
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import androidx.navigation.navigation
import com.fieldtap.R
import com.fieldtap.app.AppGraph
import com.fieldtap.core.privacy.Consent
import com.fieldtap.platform.Permissions
import com.fieldtap.ui.about.AboutScreen
import com.fieldtap.ui.common.graphViewModelFactory
import com.fieldtap.ui.signal.SignalScreen
import com.fieldtap.ui.live.KeepScreenOnEffect
import com.fieldtap.ui.live.LiveViewModel
import com.fieldtap.app.SessionStatus
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.fieldtap.ui.onboarding.DisclosureScreen
import com.fieldtap.ui.onboarding.OnboardingViewModel
import com.fieldtap.ui.onboarding.PermissionsScreen
import com.fieldtap.data.CaptureStore
import com.fieldtap.ui.common.FileSharer
import com.fieldtap.ui.probe.ProbeScreen
import com.fieldtap.ui.signalling.CaptureDetailScreen
import com.fieldtap.ui.signalling.CaptureDetailViewModel
import com.fieldtap.ui.logs.LogsHeader
import com.fieldtap.ui.traffic.TrafficScreen
import com.fieldtap.ui.traffic.TrafficViewModel
import com.fieldtap.ui.signalling.SignallingViewModel
import com.fieldtap.ui.probe.ProbeViewModel
import com.fieldtap.ui.readiness.ReadinessScreen
import com.fieldtap.ui.readiness.ReadinessViewModel
import com.fieldtap.ui.sessions.SessionDetailScreen
import com.fieldtap.ui.sessions.SessionDetailViewModel
import com.fieldtap.ui.sessions.SessionsScreen
import com.fieldtap.ui.sessions.SessionsViewModel
import com.fieldtap.ui.settings.SettingsScreen
import com.fieldtap.ui.settings.SettingsViewModel
import com.fieldtap.ui.settings.TestTargetsScreen
import com.fieldtap.ui.theme.FieldTapIcons
import com.fieldtap.ui.theme.Sizes
import kotlinx.coroutines.CancellationException

/**
 * Routes. Directory names are `[A-Za-z0-9._-]` only, so they go into a route unescaped.
 *
 * The app is a four-tab shell (a Material bottom [NavigationBar], [TopTab]): Signal, Traffic, Logs and
 * Settings. Each tab is a nested graph with its own start and its own back stack; detail screens push on top
 * within their tab. Onboarding ([DISCLOSURE], [PERMISSIONS]) and the disclosure-declined About
 * ([ABOUT_ONBOARDING]) are top-level, with no bottom bar.
 *
 * Owner: workstream `ui-session`.
 */
object Routes {
    const val DISCLOSURE: String = "disclosure"
    const val PERMISSIONS: String = "permissions"

    /** The disclosure-declined About: the one screen usable before consent, so it carries no bottom bar. */
    const val ABOUT_ONBOARDING: String = "about_onboarding"

    const val LIVE: String = "live"
    const val SESSIONS: String = "sessions"
    const val SESSION_DETAIL: String = "sessions/{dirName}"
    const val READINESS: String = "readiness"
    const val PROBE: String = "probe"

    /** One kept capture's call flow. It sits in the Recordings graph, which is the list that opens it. */
    const val CAPTURE_DETAIL: String = "recordings/capture/{captureName}"
    const val ARG_CAPTURE_NAME: String = "captureName"

    fun capture(name: String): String = "recordings/capture/" + java.net.URLEncoder.encode(name, "UTF-8")
    const val SETTINGS: String = "settings"

    /** The ping and download targets, a screen of their own under Settings. */
    const val TEST_TARGETS: String = "settings/tests"
    const val ABOUT: String = "about"

    /** The nested graph that holds each tab's root and its detail screens. */
    const val LIVE_GRAPH: String = "live_graph"
    const val SESSIONS_GRAPH: String = "sessions_graph"
    /** iperf3 and ping against a server the user names. */
    const val TRAFFIC: String = "traffic"
    const val TRAFFIC_GRAPH: String = "traffic_graph"
    const val SETTINGS_GRAPH: String = "settings_graph"

    const val ARG_DIR_NAME: String = "dirName"

    fun sessionDetail(dirName: String): String = "sessions/$dirName"
}

/**
 * The four top-level tabs, in bar order: Signal, Traffic, Logs and Settings. Each names the nested [graph]
 * it selects, the [root] destination it pops to when re-tapped, its [icon] and its [label].
 *
 * Owner: workstream `ui-session`.
 */
enum class TopTab(
    val graph: String,
    val root: String,
    val icon: ImageVector,
    @StringRes val label: Int,
) {
    /** The meter: serving cell, channel, identity, neighbours. LTE Discovery's first screen, done properly. */
    SIGNAL(Routes.LIVE_GRAPH, Routes.LIVE, FieldTapIcons.SignalBars, R.string.nav_signal),

    /** iperf3 and ping, on cellular, against a server the user names — in a lab, the callbox. */
    TRAFFIC(Routes.TRAFFIC_GRAPH, Routes.TRAFFIC, FieldTapIcons.Transfer, R.string.nav_traffic),

    /**
     * Recording and what was recorded: the signal log, the RRC/NAS capture when rooted, and the list of
     * both. Recording used to be a button on the meter and a tab of its own; it is one job, in one place.
     */
    LOGS(Routes.SESSIONS_GRAPH, Routes.SESSIONS, FieldTapIcons.Sessions, R.string.nav_logs),

    /** Everything done once and rarely: the probe, readiness, targets, consent, about. */
    SETTINGS(Routes.SETTINGS_GRAPH, Routes.SETTINGS, FieldTapIcons.Tune, R.string.nav_settings),
    ;

    companion object {
        val graphRoutes: Set<String> = entries.map { it.graph }.toSet()
    }
}

/**
 * Where the app opens and where onboarding continues. Pure, so it is unit-tested.
 *
 * Owner: workstream `ui-session`.
 */
object StartDestination {
    /** The disclosure until consent is current, then permissions until precise location is granted, then Live. */
    fun route(consentCurrent: Boolean, preciseLocationGranted: Boolean): String = when {
        !consentCurrent -> Routes.DISCLOSURE
        !preciseLocationGranted -> Routes.PERMISSIONS
        else -> Routes.LIVE
    }

    /** After the disclosure is accepted: permissions, unless precise location is already granted. */
    fun afterDisclosure(preciseLocationGranted: Boolean): String =
        if (preciseLocationGranted) Routes.LIVE else Routes.PERMISSIONS
}

/**
 * The whole navigation graph, hosted under a [Scaffold] whose bottom bar is the four-tab [FieldTapBottomBar].
 * Start destination: [Routes.DISCLOSURE] until consent is current (`Consent.isCurrent(settings.consent)`),
 * then [Routes.PERMISSIONS] until precise location is granted, then the Live tab. Readiness never refuses a
 * start (decision 7): Live runs the checks itself and opens [Routes.READINESS] only when the user asks for it.
 *
 * - The start destination is decided once, from settings read off the main thread, and survives recreation;
 *   until it is known the screen shows only the background, so no location prompt can appear before the
 *   disclosure.
 * - The bottom bar shows on the four tab graphs (roots and their detail screens) and hides on onboarding, so
 *   a declined disclosure leaves only the [Routes.ABOUT_ONBOARDING] screen usable.
 * - Tapping a tab switches to its root and preserves that tab's back stack (`saveState`/`restoreState`);
 *   re-tapping the current tab pops it to its root. Live is the back-stack base, so system Back walks a tab's
 *   own stack, then returns to Live, then exits.
 * - Onboarding steps opened from Live (review consent, allow location) return to Live when done instead of
 *   stacking a second Live; every navigation callback is dropped unless its screen is resumed.
 *
 * Owner: workstream `ui-session`.
 */
@Composable
fun FieldTapNavHost(
    graph: AppGraph,
    modifier: Modifier = Modifier,
    navController: NavHostController = rememberNavController(),
) {
    val context = LocalContext.current
    var startRoute by rememberSaveable { mutableStateOf<String?>(null) }
    LaunchedEffect(graph) {
        if (startRoute == null) {
            val consentCurrent = try {
                Consent.isCurrent(graph.settings.current().consent)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // Unreadable settings: ask again rather than assume consent.
                false
            }
            startRoute = StartDestination.route(consentCurrent, Permissions.preciseLocationGranted(context))
        }
    }
    val start = startRoute
    if (start == null) {
        Box(modifier = modifier.fillMaxSize().background(MaterialTheme.colorScheme.background))
        return
    }
    // The Live start route resolves inside the Live tab graph.
    val navStart = if (start == Routes.LIVE) Routes.LIVE_GRAPH else start

    val currentEntry by navController.currentBackStackEntryAsState()
    val currentDestination = currentEntry?.destination
    val showBottomBar = currentDestination.isInTabGraph()

    // The screen stays on while a signal log records, whichever tab is showing. Android samples cells every
    // 2 s only while the display is on; a log started from Logs and watched on Signal must not quietly drop
    // to every 10 s because the screen that started it is no longer composed.
    val sessionStatus by graph.sessionControl.status.collectAsStateWithLifecycle()
    KeepScreenOnEffect(enabled = sessionStatus !is SessionStatus.Idle)

    Scaffold(
        modifier = modifier,
        containerColor = MaterialTheme.colorScheme.background,
        // The tabs and each screen's top bar / floating action bar own the system-bar insets themselves.
        contentWindowInsets = WindowInsets(0, 0, 0, 0),
        bottomBar = {
            if (showBottomBar) {
                FieldTapBottomBar(
                    currentDestination = currentDestination,
                    onSelectTab = { tab -> navController.selectTab(tab) },
                )
            }
        },
    ) { innerPadding ->
        NavHost(
            navController = navController,
            startDestination = navStart,
            // Pad for the bottom bar and mark its insets consumed, so a screen's own navigationBarsPadding
            // (the floating action bar) does not add it twice and docks directly above the bar.
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .consumeWindowInsets(innerPadding),
        ) {
            composable(Routes.DISCLOSURE) {
                val viewModel: OnboardingViewModel = viewModel(factory = graphViewModelFactory(graph) { OnboardingViewModel(it) })
                DisclosureScreen(
                    viewModel = viewModel,
                    onAccepted = dropUnlessResumed {
                        val next = StartDestination.afterDisclosure(Permissions.preciseLocationGranted(context))
                        navController.completeOnboardingStep(Routes.DISCLOSURE, next)
                    },
                    onDeclined = dropUnlessResumed { navController.navigate(Routes.ABOUT_ONBOARDING) { launchSingleTop = true } },
                )
            }
            composable(Routes.PERMISSIONS) {
                PermissionsScreen(
                    onDone = dropUnlessResumed { navController.completeOnboardingStep(Routes.PERMISSIONS, Routes.LIVE) },
                )
            }
            composable(Routes.ABOUT_ONBOARDING) {
                AboutScreen(appInfo = graph.appInfo, onBack = dropUnlessResumed { navController.popBackStack() })
            }

            navigation(startDestination = Routes.LIVE, route = Routes.LIVE_GRAPH) {
                composable(Routes.LIVE) {
                    val viewModel: LiveViewModel = viewModel(factory = graphViewModelFactory(graph) { LiveViewModel(it) })
                    SignalScreen(viewModel = viewModel)
                }
            }

            navigation(startDestination = Routes.SESSIONS, route = Routes.SESSIONS_GRAPH) {
                composable(Routes.SESSIONS) {
                    val context = LocalContext.current
                    val store = captureStore(context)
                    val viewModel: SessionsViewModel =
                        viewModel(factory = graphViewModelFactory(graph) { SessionsViewModel(it, store) })
                    val live: LiveViewModel = viewModel(factory = graphViewModelFactory(graph) { LiveViewModel(it) })
                    val signalling: SignallingViewModel = viewModel(
                        factory = graphViewModelFactory(graph) { SignallingViewModel(scratchDir(context), store) },
                    )
                    SessionsScreen(
                        viewModel = viewModel,
                        title = stringResource(R.string.nav_logs),
                        onOpenSession = { dirName -> navController.openSessionDetail(dirName) },
                        onOpenCapture = { name -> navController.openCaptureDetail(name) },
                        onGoToLive = dropUnlessResumed { navController.selectTab(TopTab.SIGNAL) },
                        header = {
                            LogsHeader(
                                live = live,
                                signalling = signalling,
                                onOpenCapture = { name ->
                                    viewModel.refresh()
                                    navController.openCaptureDetail(name)
                                },
                            )
                        },
                    )
                }
                composable(
                    route = Routes.SESSION_DETAIL,
                    arguments = listOf(navArgument(Routes.ARG_DIR_NAME) { type = NavType.StringType }),
                ) { entry ->
                    val dirName = entry.arguments?.getString(Routes.ARG_DIR_NAME).orEmpty()
                    val viewModel: SessionDetailViewModel =
                        viewModel(factory = graphViewModelFactory(graph) { SessionDetailViewModel(it, dirName) })
                    SessionDetailScreen(
                        viewModel = viewModel,
                        onBack = dropUnlessResumed { navController.popBackStack() },
                    )
                }
                // A capture's call flow sits in the Recordings graph because that is the list it is opened
                // from; the Signalling tab reaches it by switching tabs, the way Live opens a session.
                composable(
                    route = Routes.CAPTURE_DETAIL,
                    arguments = listOf(navArgument(Routes.ARG_CAPTURE_NAME) { type = NavType.StringType }),
                ) { entry ->
                    val context = LocalContext.current
                    val name = entry.arguments?.getString(Routes.ARG_CAPTURE_NAME).orEmpty()
                    val store = captureStore(context)
                    val viewModel: CaptureDetailViewModel =
                        viewModel(factory = graphViewModelFactory(graph) { CaptureDetailViewModel(store, name) })
                    val subject = stringResource(R.string.signalling_export_subject)
                    CaptureDetailScreen(
                        viewModel = viewModel,
                        onBack = dropUnlessResumed { navController.popBackStack() },
                        onExport = {
                            // Shared from cache/exports, which is the only place the file provider serves.
                            viewModel.file()?.let { kept ->
                                runCatching {
                                    val shareable = java.io.File(scratchDir(context), kept.name)
                                    scratchDir(context).mkdirs()
                                    kept.copyTo(shareable, overwrite = true)
                                    FileSharer.share(context, shareable, SignallingViewModel.MIME, subject, null)
                                }
                            }
                            Unit
                        },
                    )
                }
            }

            navigation(startDestination = Routes.TRAFFIC, route = Routes.TRAFFIC_GRAPH) {
                composable(Routes.TRAFFIC) {
                    val viewModel: TrafficViewModel = viewModel()
                    TrafficScreen(viewModel = viewModel)
                }
            }

            navigation(startDestination = Routes.SETTINGS, route = Routes.SETTINGS_GRAPH) {
                composable(Routes.SETTINGS) {
                    val viewModel: SettingsViewModel = viewModel(factory = graphViewModelFactory(graph) { SettingsViewModel(it) })
                    SettingsScreen(
                        viewModel = viewModel,
                        onOpenTestTargets = dropUnlessResumed { navController.navigate(Routes.TEST_TARGETS) { launchSingleTop = true } },
                        onOpenReadiness = dropUnlessResumed { navController.navigate(Routes.READINESS) { launchSingleTop = true } },
                        onOpenAbout = dropUnlessResumed { navController.navigate(Routes.ABOUT) { launchSingleTop = true } },
                        onOpenProbe = dropUnlessResumed { navController.navigate(Routes.PROBE) { launchSingleTop = true } },
                    )
                }
                // The capability probe is a setup task: run once on a new phone, read, and left alone.
                composable(Routes.PROBE) {
                    val viewModel: ProbeViewModel = viewModel(factory = graphViewModelFactory(graph) { ProbeViewModel(it) })
                    ProbeScreen(
                        viewModel = viewModel,
                        onBack = dropUnlessResumed { navController.popBackStack() },
                    )
                }
                composable(Routes.TEST_TARGETS) {
                    val viewModel: SettingsViewModel = viewModel(factory = graphViewModelFactory(graph) { SettingsViewModel(it) })
                    TestTargetsScreen(viewModel = viewModel, onBack = dropUnlessResumed { navController.popBackStack() })
                }
                composable(Routes.READINESS) {
                    val viewModel: ReadinessViewModel = viewModel(factory = graphViewModelFactory(graph) { ReadinessViewModel(it) })
                    ReadinessScreen(viewModel = viewModel, onBack = dropUnlessResumed { navController.popBackStack() })
                }
                composable(Routes.ABOUT) {
                    AboutScreen(appInfo = graph.appInfo, onBack = dropUnlessResumed { navController.popBackStack() })
                }
            }
        }
    }
}

/**
 * The Momentum bottom bar: the four [TopTab]s over the Momentum surface with a soft top hairline, the
 * selected item in the indigo `primaryContainer` indicator pill. The label always shows, in Hanken, and each
 * item announces its name and selected state to TalkBack (the [NavigationBarItem]'s own role and selection).
 */
@Composable
private fun FieldTapBottomBar(currentDestination: NavDestination?, onSelectTab: (TopTab) -> Unit) {
    val hairline = MaterialTheme.colorScheme.outlineVariant
    NavigationBar(
        modifier = Modifier.drawBehind {
            val stroke = Sizes.HairlineWidth.toPx()
            drawLine(
                color = hairline,
                start = Offset(0f, stroke / 2f),
                end = Offset(size.width, stroke / 2f),
                strokeWidth = stroke,
            )
        },
        // The Momentum surface (white in light, the elevated card in dark); no accent tint on chrome.
        containerColor = MaterialTheme.colorScheme.surfaceContainerLow,
        contentColor = MaterialTheme.colorScheme.onSurfaceVariant,
        tonalElevation = 0.dp, // Depth is the hairline, not a tint (tonalElevation is 0 everywhere).
        windowInsets = WindowInsets.navigationBars,
    ) {
        val selected = currentDestination.selectedTab()
        TopTab.entries.forEach { tab ->
            val isSelected = selected == tab
            NavigationBarItem(
                selected = isSelected,
                onClick = { onSelectTab(tab) },
                icon = { Icon(imageVector = tab.icon, contentDescription = null) },
                label = {
                    Text(
                        text = stringResource(tab.label),
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                        textAlign = TextAlign.Center,
                    )
                },
                alwaysShowLabel = true,
                colors = NavigationBarItemDefaults.colors(
                    selectedIconColor = MaterialTheme.colorScheme.onPrimaryContainer,
                    selectedTextColor = MaterialTheme.colorScheme.onSurface,
                    indicatorColor = MaterialTheme.colorScheme.primaryContainer,
                    unselectedIconColor = MaterialTheme.colorScheme.onSurfaceVariant,
                    unselectedTextColor = MaterialTheme.colorScheme.onSurfaceVariant,
                ),
            )
        }
    }
}

/** True when [this] destination belongs to one of the four tab graphs (a root or a detail within a tab). */
private fun NavDestination?.isInTabGraph(): Boolean =
    this?.hierarchy?.any { it.route in TopTab.graphRoutes } == true

/** The tab whose graph contains [this] destination, or null when it is an onboarding screen. */
private fun NavDestination?.selectedTab(): TopTab? {
    val routes = this?.hierarchy?.mapNotNull { it.route }?.toSet() ?: return null
    return TopTab.entries.firstOrNull { it.graph in routes }
}

/**
 * Selects [tab]. When it is already the current tab, pops that tab to its root; otherwise switches to it,
 * saving the tab being left and restoring [tab]'s own back stack, with Live kept as the back-stack base.
 */
private fun NavHostController.selectTab(tab: TopTab) {
    val current = currentBackStackEntry?.destination.selectedTab()
    if (current == tab) {
        popBackStack(tab.root, inclusive = false)
        return
    }
    // Live is the base of the tabbed back stack: popping up to it (saving what is left) keeps system Back
    // walking a tab's own stack, then returning to Live, then exiting.
    navigate(tab.graph) {
        popUpTo(Routes.LIVE) { saveState = true }
        launchSingleTop = true
        restoreState = true
    }
}

/**
 * Leaves the onboarding step [current]: back to Live when Live opened it, else on to [next] with the step
 * removed from the back stack, so Back never returns to a finished step.
 */
private fun NavHostController.completeOnboardingStep(current: String, next: String) {
    if (popBackStack(Routes.LIVE, inclusive = false)) return
    navigate(next) {
        popUpTo(current) { inclusive = true }
        launchSingleTop = true
    }
}

/** Opens a session, ignoring a second tap while the first navigation is still running. */
private fun NavHostController.openSessionDetail(dirName: String) {
    val route = Routes.sessionDetail(dirName)
    if (currentBackStackEntry?.destination?.route != Routes.SESSIONS) return
    navigate(route) { launchSingleTop = true }
}

/**
 * Opens a capture's call flow. Unlike a session this is not guarded on the Recordings root, because the
 * Signalling tab opens it straight after a capture finishes, from its own destination.
 */
private fun NavHostController.openCaptureDetail(name: String) {
    if (currentBackStackEntry?.destination?.route == Routes.CAPTURE_DETAIL) return
    navigate(Routes.capture(name)) { launchSingleTop = true }
}

/** Where a capture lands before it is kept, and the only directory the file provider serves. */
private fun scratchDir(context: android.content.Context): java.io.File =
    java.io.File(context.cacheDir, FileSharer.EXPORTS_DIR)

/** Kept captures live in the app's own files, not in a session: they hold layer-3 signalling. */
private fun captureStore(context: android.content.Context): CaptureStore =
    CaptureStore(java.io.File(context.filesDir, "signalling").apply { mkdirs() })
