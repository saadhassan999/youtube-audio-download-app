import java.io.FileInputStream
import java.util.Properties
import org.gradle.api.GradleException

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
val isReleaseTaskRequested = gradle.startParameter.taskNames.any {
    it.contains("Release", ignoreCase = true) ||
    it.contains("bundle", ignoreCase = true) ||
    it.contains("upload", ignoreCase = true) ||
    it.contains("publish", ignoreCase = true)
}

if (keystorePropertiesFile.exists()) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
} else if (isReleaseTaskRequested) {
    throw GradleException("Missing android/key.properties for release signing. Create it alongside upload-keystore.jks (see README).")
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // Updated to bundle Python 3.11+ and recent yt-dlp (fixes ImportError on Python 3.8)
    implementation("io.github.junkfood02.youtubedl-android:library:0.17.2")
    implementation("com.fasterxml.jackson.core:jackson-databind:2.14.3")
    implementation("com.fasterxml.jackson.module:jackson-module-kotlin:2.14.3")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")
}


android {
    namespace = "com.example.youtube_audio_downloader"
    compileSdk = 35
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.youtube_audio_downloader"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystoreProperties.isEmpty && isReleaseTaskRequested) {
                throw GradleException("Missing android/key.properties for release signing. Create it alongside upload-keystore.jks (see README).")
            }
            if (keystoreProperties.isNotEmpty()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = rootProject.file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }

    packaging {
        // Skip strip on the embedded Python zip and keep legacy extraction for native libs
        doNotStrip += setOf("**/libpython.zip.so")
        jniLibs {
            useLegacyPackaging = true
        }
    }
}

flutter {
    source = "../.."
}
