package dev.igor.motonav.settings

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings

/**
 * The battery optimization exemption (C13a). With it Android lets the navigation
 * service start with the app in the background, which is the case of a favorite requested from the
 * watch with the phone in a pocket. A navigation started from the phone does not need it.
 */
object BatteryExemption {

    fun granted(context: Context): Boolean =
        context.getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(context.packageName)

    /** The system dialog that asks for the exemption for this package (the `.sim` one is another). */
    @SuppressLint("BatteryLife")
    fun request(context: Context): Intent =
        Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${context.packageName}"))
}
