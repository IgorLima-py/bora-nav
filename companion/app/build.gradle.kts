plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
}

android {
    namespace = "dev.igor.motonav"
    compileSdk = 35

    defaultConfig {
        applicationId = "dev.igor.motonav"
        minSdk = 26
        targetSdk = 35
        // Shown on the main screen and the share screen. Goes up with every
        // installed APK, independent of the watch: the two versions need not
        // match, each screen only has to show the right number for its side.
        versionCode = 39
        versionName = "1.4.2"
        // WIRELESS: the real watch, through Garmin Connect. Only `sim` turns this on.
        buildConfigField("boolean", "CIQ_TETHERED", "false")
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
        // C7a: the companion on the `pato37` emulator talking to the app in the Connect IQ
        // simulator (`TETHERED`, via `adb forward tcp:7381 tcp:7381`). Its own package,
        // so it never competes for the install with the S25 debug build.
        create("sim") {
            initWith(getByName("debug"))
            applicationIdSuffix = ".sim"
            versionNameSuffix = "-sim"
            matchingFallbacks += "debug"
            buildConfigField("boolean", "CIQ_TETHERED", "true")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        compose = true
        // BuildConfig.VERSION_NAME — AGP 8 does not generate it without this.
        buildConfig = true
    }

    lint {
        // A false positive for this app: the check is about request codes in a FragmentActivity,
        // and every `registerForActivityResult` here is in a ComponentActivity. Fragment 1.1.0
        // only comes in transitively. Without this, `assembleRelease` stops at lintVital.
        disable += "InvalidFragmentVersionForActivityResult"
    }

    testOptions {
        // `EventLog` calls `android.util.Log`, which does not exist on the unit-test JVM
        // and throws "not mocked". With this it returns a default value and the test runs
        // without needing Robolectric.
        unitTests.isReturnDefaultValues = true
        // The screen snapshot (`SettingsScreenTest`, Robolectric) needs the app's fonts and texts.
        unitTests.isIncludeAndroidResources = true
        // The tests read `tools/fixtures` (outside the module). Without declaring the folder
        // as an input, gradle treated the test as UP-TO-DATE with the fixture
        // changed: measured on 2026-09-29, the sabotaged `DemoFramesTest` golden
        // passed "green" without the test running.
        unitTests.all {
            it.inputs.dir(rootProject.file("../tools/fixtures"))
            // WatchSettingsTest checks the screen's ranges against the watch, and WatchFaceTest reads
            // the measurements of Hud, SpeedHud, StreetCache, the glyphs and Protocol (C16.6). The
            // whole folder: declaring only Config and DesignTokens meant changing any other `.mc`
            // left the task "up to date" and the test did not run.
            it.inputs.dir(rootProject.file("../watch/source"))
        }
    }
}

// `ConnectTypeTest` checks the three variants in a single run of
// `testDebugUnitTest`, reading the generated `BuildConfig.java` of each.
val buildConfigDir = layout.buildDirectory.dir("generated/source/buildConfig")
tasks.withType<Test>().configureEach {
    dependsOn("generateDebugBuildConfig", "generateReleaseBuildConfig", "generateSimBuildConfig")
    inputs.dir(buildConfigDir)
    systemProperty("motonav.buildConfigDir", buildConfigDir.get().asFile.absolutePath)
    // `-Pcanary`: `RerouteWaypointsTest` drops the stops between the resolver and the
    // session (the pre-C11 defect) and the recalculation test must fail.
    systemProperty("motonav.canary", project.hasProperty("canary").toString())
}

dependencies {
    implementation(platform("androidx.compose:compose-bom:2024.10.01"))
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    debugImplementation("androidx.compose.ui:ui-tooling")

    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")

    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("androidx.security:security-crypto:1.1.0-alpha06")
    implementation("com.google.android.gms:play-services-location:21.3.0")

    // Connect IQ Android SDK — talks to the watch through Garmin Connect Mobile.
    implementation("com.garmin.connectiq:ciq-companion-app-sdk:2.2.0")

    testImplementation("junit:junit:4.13.2")
    // The screen snapshot without an emulator (`SettingsScreenTest`): macOS cannot run the `pato37` emulator.
    testImplementation("org.robolectric:robolectric:4.14.1")
    testImplementation(platform("androidx.compose:compose-bom:2024.10.01"))
    testImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
