plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.minikanban.minikanban"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.minikanban.minikanban"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 35
        targetSdk = 36
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            // R8 включён; без правил из proguard-rules.pro он ломает сканер QR
            // (CameraX/ML Kit в mobile_scanner: NPE при запуске камеры).
            // Ресурсы не сжимаем: выигрыш мал, а риск для ML Kit есть.
            isMinifyEnabled = true
            isShrinkResources = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

// Корень Flutter-проекта. Gradle раскрывает ссылки (junction) в реальный
// путь, а gen_snapshot не читает пути с не-ASCII символами. Если проект
// лежит в такой папке, задайте ASCII-путь к нему (junction/symlink)
// свойством Gradle `minikanban.asciiRoot` — в android/gradle.properties,
// в ~/.gradle/gradle.properties или через -P. Несуществующий путь
// игнорируется.
val asciiRoot: String? =
    providers
        .gradleProperty("minikanban.asciiRoot")
        .orNull
        ?.takeIf { it.isNotBlank() && file(it).isDirectory }

flutter {
    source = asciiRoot ?: "../.."
}