import org.jetbrains.kotlin.gradle.dsl.JvmTarget

// Plain Kotlin/JVM, no Android: platform-independent logic, unit-tested on a JVM.
plugins {
    alias(libs.plugins.kotlin.jvm)
}

// Built with the JDK 21 toolchain, emitting Java 17 bytecode against the Java 17 API.
kotlin {
    jvmToolchain(21)
    compilerOptions {
        jvmTarget = JvmTarget.JVM_17
        freeCompilerArgs.add("-Xjdk-release=17")
    }
}

tasks.withType<JavaCompile>().configureEach {
    options.release = 17
}

tasks.test {
    useJUnit()
}

// Every dependency the :core workstreams need is declared here up front, so no implementer has to
// edit this file (android/ARCHITECTURE.md, "Shared files"). :format, :diag and coroutines types appear in
// :core's public signatures, hence api. :diag has no dependencies of its own; `AppSettings.captureProfile`
// is its `CaptureProfile`, so the setting and the log mask cannot name different profiles.
dependencies {
    api(project(":format"))
    api(project(":diag"))
    api(libs.kotlinx.coroutines.core)
    // Reading JSON only (settings codec); session files are written by :format's own writer.
    implementation(libs.kotlinx.serialization.json)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
}
