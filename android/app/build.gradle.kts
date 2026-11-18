plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "io.github.qianyuan1437.openspeak"
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
        applicationId = "io.github.qianyuan1437.openspeak"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Community builds are signed with the keystore committed to the repo so
    // CI and local release APKs can update each other. Override with
    // OPENSPEAK_KEYSTORE / OPENSPEAK_KEYSTORE_PASSWORD for private builds.
    signingConfigs {
        create("release") {
            storeFile = file(System.getenv("OPENSPEAK_KEYSTORE") ?: "openspeak-release.jks")
            storePassword = System.getenv("OPENSPEAK_KEYSTORE_PASSWORD") ?: "openspeak"
            keyAlias = System.getenv("OPENSPEAK_KEY_ALIAS") ?: "openspeak"
            keyPassword = System.getenv("OPENSPEAK_KEY_PASSWORD") ?: "openspeak"
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

flutter {
    source = "../.."
}
