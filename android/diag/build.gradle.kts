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
    // Contract v1 (ios/Contract/CONTRACT.md): ContractGoldenTest's fixtures are capture-derived and git-ignored
    // (ios/Fixtures/local), so their paths come from the environment. Unset, those tests skip;
    // FT_REQUIRE_FIXTURES=1 turns a skip into a failure.
    mapOf(
        "ft.contract" to "FT_CONTRACT_DIR",
        "ft.iphoneQmdl" to "FT_IPHONE_QMDL",
        "ft.fixtures" to "FT_FIXTURES",
        "ft.require" to "FT_REQUIRE_FIXTURES",
    ).forEach { (property, variable) ->
        providers.environmentVariable(variable).orNull?.let { systemProperty(property, it) }
    }
}

// ContractGoldenTest runs ios/Contract/tools/GoldenDump.kt, the tool that wrote the goldens, instead of a port that
// could drift from it. It is copied in only when ios/ is there; without it the test skips.
val contractTools = tasks.register<Sync>("contractTools") {
    from(file("../../ios/Contract/tools")) { include("GoldenDump.kt") }
    into(layout.buildDirectory.dir("generated/contract-tools"))
}

kotlin.sourceSets.named("test") {
    kotlin.srcDir(contractTools)
}

dependencies {
    testImplementation(libs.junit)
}
