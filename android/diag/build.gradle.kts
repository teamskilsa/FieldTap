import org.jetbrains.kotlin.gradle.dsl.JvmTarget

// Plain Kotlin/JVM, no Android: the Qualcomm diag protocol: framing, log packets, log codes. Runs on any JDK.
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

dependencies {
    testImplementation(libs.junit)
}
