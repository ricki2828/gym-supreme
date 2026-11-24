import org.jetbrains.kotlin.gradle.dsl.JvmTarget

// Pure Kotlin core for the live workout (plan 6.2): journal codec, timer and cue scheduler,
// HR parse. No Android types, so it unit-tests on any JVM.
plugins {
    kotlin("jvm") version "2.4.0"
}

group = "app.gymsupreme"
version = "0.1.0"

kotlin {
    jvmToolchain(21)
    compilerOptions {
        // Compile against the Java 8 API surface: anything newer than what Android 10 (API 29,
        // minSdk) ships fails at compile time instead of with NoSuchMethodError on the phone.
        jvmTarget.set(JvmTarget.JVM_1_8)
        freeCompilerArgs.add("-Xjdk-release=1.8")
    }
}

java {
    sourceCompatibility = JavaVersion.VERSION_1_8
    targetCompatibility = JavaVersion.VERSION_1_8
}

dependencies {
    testImplementation(kotlin("test"))
}

tasks.test {
    useJUnitPlatform()
    testLogging {
        events("passed", "failed", "skipped", "standard_out")
        // Full assertion output in the CI log (the host cannot run Gradle to see it).
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
    }
}
