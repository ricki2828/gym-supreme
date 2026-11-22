// Standalone Gradle build: pure Kotlin/JVM, no Android plugin. The app build includes it via
// includeBuild("core") in android/settings.gradle.kts. CI only: no Gradle on the dev host.
rootProject.name = "core"

pluginManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
    }
}

dependencyResolutionManagement {
    repositories {
        mavenCentral()
    }
}
