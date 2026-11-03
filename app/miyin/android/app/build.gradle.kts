plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

dependencies {
    implementation("com.google.mlkit:translate:17.0.3")
    implementation("com.google.mlkit:text-recognition:16.0.1")
    implementation("com.google.mlkit:text-recognition-chinese:16.0.1")
}

android {
    packaging {
        jniLibs {
            useLegacyPackaging = true
            // These fixed runtime artifacts are already stripped and hashed.
            keepDebugSymbols += setOf("**/libmiyin_llama.so", "**/libllama*.so", "**/libggml*.so", "**/libmtmd.so")
        }
    }
    namespace = "com.miyin.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.miyin.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // target-platform limits Flutter itself, but transitive Android SDKs
        // also contribute native libraries. Keep the arm64 artifact arm64-only.
        if (providers.gradleProperty("target-platform").orNull == "android-arm64") {
            ndk {
                abiFilters.clear()
                abiFilters.add("arm64-v8a")
            }
        }
    }

    buildTypes {
        release {
            // Official builds are signed and verified by the protected release
            // tool after assembly. Contributor previews keep their local key.
            signingConfig = if (providers.gradleProperty("miyinProduction").orNull == "true")
                null else signingConfigs.getByName("debug")
            // Isolate a Release-only ML Kit model-status failure. Keep shrinking
            // disabled for this build until the device comparison identifies it.
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
