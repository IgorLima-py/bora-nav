package dev.igor.motonav.ui

import android.content.res.Resources
import androidx.annotation.StringRes
import dev.igor.motonav.R
import dev.igor.motonav.link.LinkState
import dev.igor.motonav.link.SdkProblem
import dev.igor.motonav.nav.NavActivity

/**
 * The state of the Home screen header (sheet 2, direction 3; `docs/design/telas.md` §5.4).
 *
 * **The sign shows health and the ring shows activity** (language rule 1): the check is
 * ready, the dimmed "?" cannot find the watch and the "!" says one thing is missing. The ring stays whole,
 * spins or stays dashed. The table's order decides the header, and the list brings **all** the
 * pending items, not just the first.
 */
data class HomeStatus(
    val ring: Ring,
    val sign: Sign,
    val title: String,
    val detail: String,
    val pending: List<Pending>,
) {
    /** Ready: solid cyan. Working: spinning track and arc. Where: dashed. Missing: amber. */
    enum class Ring { READY, WORKING, NO_WATCH, MISSING }

    enum class Sign { NONE, CHECK, QUESTION, BANG }

    /** What a pending item's button does. */
    enum class Action(@StringRes val label: Int) {
        INSTALL_GCM(R.string.action_install),
        UPDATE_GCM(R.string.action_update),
        OPEN_GCM(R.string.action_open),
        ALLOW_BATTERY(R.string.battery_allow),
        SAVE_TOKEN(R.string.action_save),
    }

    enum class Icon { WATCH_OFF, APPS, BATTERY, TOKEN }

    /**
     * A line of "Still missing". [yours] paints the icon and button amber: it is something only the
     * person can fix. The rest (the missing watch) stays gray, with the cyan open button.
     */
    data class Pending(val icon: Icon, val label: String, val action: Action?, val yours: Boolean)
}

/**
 * @param res the texts come out in the device's language (C16.8b).
 * @param versionName the phone's version. The watch's does not reach the phone today (§9: it asks for a
 *   field in the protocol), so Ready shows only this one.
 */
fun homeStatus(
    res: Resources,
    link: LinkState,
    batteryExempt: Boolean,
    hasToken: Boolean,
    activity: NavActivity,
    versionName: String,
): HomeStatus {
    val pending = mutableListOf<HomeStatus.Pending>()
    val device = link.devices.firstOrNull { it.connected }
    val anyName = device?.name ?: link.devices.firstOrNull()?.name ?: res.getString(R.string.home_watch)

    val gcm = when (link.problem) {
        SdkProblem.GCM_NOT_INSTALLED -> HomeStatus.Action.INSTALL_GCM
        SdkProblem.GCM_NEEDS_UPGRADE -> HomeStatus.Action.UPDATE_GCM
        SdkProblem.SERVICE_ERROR, SdkProblem.SDK_SHUT_DOWN -> HomeStatus.Action.OPEN_GCM
        null -> null
    }
    if (gcm != null) {
        pending += HomeStatus.Pending(HomeStatus.Icon.APPS, res.getString(R.string.pending_gcm), gcm, yours = true)
    } else if (!link.initializing) {
        if (link.devices.isEmpty()) {
            pending += HomeStatus.Pending(HomeStatus.Icon.WATCH_OFF, res.getString(R.string.pending_watch_paired), HomeStatus.Action.OPEN_GCM, yours = false)
        } else if (device == null) {
            pending += HomeStatus.Pending(HomeStatus.Icon.WATCH_OFF, res.getString(R.string.pending_watch_on, anyName), HomeStatus.Action.OPEN_GCM, yours = false)
            pending += HomeStatus.Pending(HomeStatus.Icon.APPS, res.getString(R.string.pending_app_on_watch), null, yours = false)
        } else if (device.appInstalled == false) {
            pending += HomeStatus.Pending(HomeStatus.Icon.APPS, res.getString(R.string.pending_app_on_watch), null, yours = true)
        }
    }
    if (!batteryExempt) {
        pending += HomeStatus.Pending(HomeStatus.Icon.BATTERY, res.getString(R.string.pending_battery), HomeStatus.Action.ALLOW_BATTERY, yours = true)
    }
    if (!hasToken) {
        pending += HomeStatus.Pending(HomeStatus.Icon.TOKEN, res.getString(R.string.token_label), HomeStatus.Action.SAVE_TOKEN, yours = true)
    }
    val health = if (pending.any { it.yours }) HomeStatus.Sign.BANG else HomeStatus.Sign.CHECK

    fun status(ring: HomeStatus.Ring, sign: HomeStatus.Sign, @StringRes title: Int, detail: String) =
        HomeStatus(ring, sign, res.getString(title), detail, pending.toList())

    fun status(ring: HomeStatus.Ring, sign: HomeStatus.Sign, @StringRes title: Int, @StringRes detail: Int) =
        status(ring, sign, title, res.getString(detail))

    return when {
        link.initializing ->
            status(HomeStatus.Ring.WORKING, HomeStatus.Sign.NONE, R.string.status_searching, R.string.status_searching_detail)
        link.problem == SdkProblem.GCM_NOT_INSTALLED ->
            status(HomeStatus.Ring.MISSING, HomeStatus.Sign.BANG, R.string.status_gcm_missing, R.string.status_gcm_missing_detail)
        link.problem == SdkProblem.GCM_NEEDS_UPGRADE ->
            status(HomeStatus.Ring.MISSING, HomeStatus.Sign.BANG, R.string.status_gcm_old, R.string.status_gcm_old_detail)
        link.problem != null ->
            status(HomeStatus.Ring.MISSING, HomeStatus.Sign.BANG, R.string.status_gcm_error, R.string.status_gcm_error_detail)
        link.devices.isEmpty() ->
            status(HomeStatus.Ring.NO_WATCH, HomeStatus.Sign.QUESTION, R.string.status_no_watch, R.string.status_no_watch_pair)
        device == null ->
            status(HomeStatus.Ring.NO_WATCH, HomeStatus.Sign.QUESTION, R.string.status_no_watch, R.string.status_no_watch_bt)
        activity is NavActivity.Calculating ->
            status(HomeStatus.Ring.WORKING, health, R.string.status_calculating, forWhom(res, activity.destination, activity.fromWatch))
        activity is NavActivity.Sending ->
            status(HomeStatus.Ring.WORKING, health, R.string.status_sending, forWhom(res, activity.destination, activity.fromWatch))
        device.appInstalled == false ->
            status(HomeStatus.Ring.MISSING, HomeStatus.Sign.BANG, R.string.status_app_missing, res.getString(R.string.status_app_missing_detail, device.name))
        !batteryExempt ->
            status(HomeStatus.Ring.MISSING, HomeStatus.Sign.BANG, R.string.status_one_thing, R.string.status_battery_detail)
        // Search works without a token since C16.5 (Photon comes first); the route does not: Directions is
        // Mapbox's (DECISIONS.md §2026-10-18, as telas iniciais).
        !hasToken ->
            status(HomeStatus.Ring.MISSING, HomeStatus.Sign.BANG, R.string.status_token_missing, R.string.status_token_missing_detail)
        else ->
            status(HomeStatus.Ring.READY, HomeStatus.Sign.CHECK, R.string.status_ready, res.getString(R.string.status_ready_detail, device.name, versionName))
    }
}

private fun forWhom(res: Resources, destination: String, fromWatch: Boolean): String =
    res.getString(if (fromWatch) R.string.status_for_watch else R.string.status_for, destination)
