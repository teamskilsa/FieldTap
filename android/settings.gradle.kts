pluginManagement {
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "fieldtap-android"

// :format  plain Kotlin/JVM: the session files the Python report reads.
// :diag    plain Kotlin/JVM: the Qualcomm diag protocol, so signalling decodes on the handset.
// :core    plain Kotlin/JVM: platform-independent logic, unit-tested on any JDK.
// :app     the Android application.
include(":format", ":diag", ":core", ":app")
