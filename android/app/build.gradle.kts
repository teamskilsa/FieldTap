// AGP 9 compiles Kotlin itself (built-in Kotlin), so org.jetbrains.kotlin.android is not applied.
plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

// The applicationId is a working ID that changes before registration. It is defined once,
// as fieldtap.applicationId in android/gradle.properties, and read only here.
val fieldtapApplicationId: String = providers.gradleProperty("fieldtap.applicationId").orNull
    ?: error("fieldtap.applicationId is not set; define it in android/gradle.properties")

// The release key never enters the repository (android/README.md, "Release key"). Its keystore and password come from
// the environment or from ~/.gradle/gradle.properties; an environment variable wins over the property:
//   FIELDTAP_RELEASE_STORE_FILE           fieldtap.release.storeFile           the PKCS12 keystore
//   FIELDTAP_RELEASE_STORE_PASSWORD       fieldtap.release.storePassword       its password, or instead
//   FIELDTAP_RELEASE_STORE_PASSWORD_FILE  fieldtap.release.storePasswordFile   a file whose first line is the password
//   FIELDTAP_RELEASE_KEY_ALIAS            fieldtap.release.keyAlias            the key's alias, default 5gto6g-fieldtap
// With none of them set, the release APK is built unsigned (app-release-unsigned.apk), as in CI's build job. Setting only
// some of them fails the build, so a release meant to be signed is never silently left unsigned.
class ReleaseKey(val storeFile: File, val password: String, val alias: String)

fun releaseSetting(environmentVariable: String, gradleProperty: String): String? =
    (providers.environmentVariable(environmentVariable).orNull ?: providers.gradleProperty(gradleProperty).orNull)
        ?.trim()
        ?.takeIf { it.isNotEmpty() }

val releaseKey: ReleaseKey? = run {
    val storePath = releaseSetting("FIELDTAP_RELEASE_STORE_FILE", "fieldtap.release.storeFile")
    val inlinePassword = releaseSetting("FIELDTAP_RELEASE_STORE_PASSWORD", "fieldtap.release.storePassword")
    val passwordPath = releaseSetting("FIELDTAP_RELEASE_STORE_PASSWORD_FILE", "fieldtap.release.storePasswordFile")
    val alias = releaseSetting("FIELDTAP_RELEASE_KEY_ALIAS", "fieldtap.release.keyAlias") ?: "5gto6g-fieldtap"
    if (storePath == null && inlinePassword == null && passwordPath == null) return@run null

    val storeFile = storePath?.let { file(it) }
        ?: throw GradleException("The release key is half configured: set FIELDTAP_RELEASE_STORE_FILE to the keystore")
    if (!storeFile.isFile) throw GradleException("The release keystore does not exist: $storeFile")
    val password = inlinePassword ?: passwordPath?.let { path ->
        val passwordFile = file(path)
        providers.fileContents(objects.fileProperty().fileValue(passwordFile)).asText.orNull
            ?.lineSequence()?.firstOrNull()?.trim()?.takeIf { it.isNotEmpty() }
            ?: throw GradleException("The release keystore password file is missing or empty: $passwordFile")
    } ?: throw GradleException(
        "The release key is half configured: set FIELDTAP_RELEASE_STORE_PASSWORD or FIELDTAP_RELEASE_STORE_PASSWORD_FILE",
    )
    ReleaseKey(storeFile, password, alias)
}

android {
    namespace = "com.fieldtap"
    compileSdk {
        version = release(37)
    }

    defaultConfig {
        applicationId = fieldtapApplicationId
        minSdk {
            version = release(31)
        }
        targetSdk {
            version = release(36)
        }
        // Raise versionCode for every APK that installs over an older one: Android refuses a lower or equal code.
        versionCode = 5
        versionName = "1.0.0"

        // The instrumented end-to-end tests in src/androidTest; android/e2e/run_e2e.sh runs them on the CI emulator.
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    signingConfigs {
        releaseKey?.let { key ->
            create("release") {
                storeFile = key.storeFile
                storePassword = key.password
                keyAlias = key.alias
                // A PKCS12 keystore has one password, for the store and for its key.
                keyPassword = key.password
            }
        }
    }

    buildTypes {
        release {
            // R8 shrinks and optimises the release build: a far smaller download than the unshrunk 28 MB, and a faster
            // cold start. CI's release job signs the minified APK with a key made for the run and drives it on the API 36
            // and API 31 emulators (android/e2e/release_smoke.sh), so a class R8 removed wrongly fails there, not on a phone.
            isMinifyEnabled = true
            isShrinkResources = true
            isDebuggable = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // Null, and so an unsigned APK, when no release key is configured.
            signingConfig = signingConfigs.findByName("release")
        }
    }

    // Java 17 bytecode; with built-in Kotlin, Kotlin's jvmTarget follows targetCompatibility.
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
    }

    lint {
        // targetSdk 36 is deliberate: it is the Android version the CI emulator and the field phones run.
        // Raise it together with a test pass on that version, not because lint suggests it.
        disable += "OldTargetApi"
    }
}

// Compiled by the JDK 21 toolchain.
java {
    toolchain {
        languageVersion = JavaLanguageVersion.of(21)
    }
}

dependencies {
    implementation(project(":core"))
    implementation(project(":diag"))
    implementation(project(":format"))

    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.ui.tooling.preview)
    debugImplementation(libs.androidx.compose.ui.tooling)

    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.lifecycle.service)
    implementation(libs.androidx.navigation.compose)
    implementation(libs.androidx.datastore.preferences)
    implementation(libs.kotlinx.coroutines.android)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)

    // End-to-end tests: Compose UI testing drives the app's screens, UiAutomator Android's own dialogs.
    androidTestImplementation(platform(libs.androidx.compose.bom))
    androidTestImplementation(libs.androidx.compose.ui.test.junit4)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.androidx.test.espresso.core)
    androidTestImplementation(libs.androidx.test.uiautomator)
    androidTestImplementation(libs.junit)
}
