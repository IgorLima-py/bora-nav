package dev.igor.motonav

/** Identifiers shared with the watch app. */
object MotoNavIds {

    /**
     * Application id of the Connect IQ app, identical to `id` in watch/manifest.xml.
     * Never regenerate it (see docs/DECISIONS.md).
     */
    const val WATCH_APP_UUID = "2c29817b21c0413583b3e4f4e2d253dd"

    /** Garmin Connect Mobile — required for any communication with the watch. */
    const val GCM_PACKAGE = "com.garmin.android.apps.connectmobile"
}
