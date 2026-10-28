import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ── release 签名（JKS）─────────────────────────────────────────────────
// 密码/别名/路径都放在 android/key.properties 里（已被 .gitignore 忽略，
// 不会进仓库）。文件不存在时（换台机器、CI 上没配密钥）自动退回 debug 签名，
// 这样 `flutter build apk --release` 依然能跑通，不会因为缺密钥直接失败。
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        FileInputStream(keystorePropertiesFile).use { load(it) }
    }
}
val hasReleaseKeystore = keystorePropertiesFile.exists()

android {
    namespace = "com.rpniu.vestige"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // 应用唯一标识。注意：一旦上架后不要再改，否则会被当成另一个 App。
        applicationId = "com.rpniu.vestige"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                // 说明：AGP 9 只输出 APK Signature Scheme v2 签名，v1(JAR) 不再生成
                // （实测即使写 enableV1Signing = true 也仍是 v1=false）。
                // 本项目 minSdk = 24（Android 7.0），系统从 7.0 起就支持 v2，够用。
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                // 没配密钥时用 debug 签名，保证仍能构建出可安装的包
                signingConfigs.getByName("debug")
            }
            // 保持 Flutter 模板默认：不开 R8 混淆/资源压缩。
            // 以后想开，需要给插件（drift / flutter_file_dialog / file_selector 等）补 keep 规则再打开。
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

