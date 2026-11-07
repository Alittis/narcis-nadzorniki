import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "si.terenska.beleznica"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "si.terenska.beleznica"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Default launcher label; release (Play) build keeps this. Non-release
        // builds override it below so the side-by-side dev app is identifiable.
        manifestPlaceholders["appLabel"] = "Terenska beležnica"
        // NV-554 P3: flutter_appauth's redirect receiver claims this private-use
        // scheme — the app's client at Račun NarcIS redirects to
        // si.terenska.beleznica:/prijava (narcis-racun RN-18). Lowercase, as
        // AppAuth requires. The dev build claims it too (one app per device).
        manifestPlaceholders["appAuthRedirectScheme"] = "si.terenska.beleznica"
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
        // Side-by-side dev install: non-release builds take a distinct
        // applicationId (si.terenska.beleznica.dev) so a profile/debug build
        // coexists with the Play (release) app on one device. The release build
        // shipped to Play is untouched.
        getByName("debug") {
            applicationIdSuffix = ".dev"
            versionNameSuffix = "-dev"
            manifestPlaceholders["appLabel"] = "Beležnica dev"
        }
        getByName("profile") {
            applicationIdSuffix = ".dev"
            versionNameSuffix = "-dev"
            manifestPlaceholders["appLabel"] = "Beležnica dev"
        }
    }
}

flutter {
    source = "../.."
}
