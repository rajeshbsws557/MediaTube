import java.util.Properties
import java.io.FileInputStream


plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.rajesh.mediatube"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // Enable core library desugaring for flutter_local_notifications
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // compilerOptions removed from here


    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.rajesh.mediatube"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24  // Required for FFmpeg and InAppWebView
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true
        
        // Only include specific ABIs to reduce APK size
        ndk {
            abiFilters += listOf("armeabi-v7a", "arm64-v8a")
        }
    }
    
    // Enable split APKs by ABI - significantly reduces download size
    splits {
        abi {
            isEnable = true
            reset()
            include("armeabi-v7a", "arm64-v8a")
            isUniversalApk = true  // Also build universal APK
        }
    }

    val keystoreProperties = Properties()
    val keystorePropertiesFile = rootProject.file("key.properties")

    if (keystorePropertiesFile.exists()) {
        keystoreProperties.load(FileInputStream(keystorePropertiesFile))
    }

    signingConfigs {
        create("release") {
            // Load from key.properties (local) or Environment Variables (CI/CD)
            keyAlias = (keystoreProperties["keyAlias"] as String?) ?: System.getenv("KEY_ALIAS")
            keyPassword = (keystoreProperties["keyPassword"] as String?) ?: System.getenv("KEY_PASSWORD")
            
            val storeFileVal = (keystoreProperties["storeFile"] as String?) ?: System.getenv("STORE_FILE")
            if (storeFileVal != null) {
                storeFile = file(storeFileVal)
            }
            
            storePassword = (keystoreProperties["storePassword"] as String?) ?: System.getenv("STORE_PASSWORD")
        }
    }



    buildTypes {
        release {
            // Enable minification and resource shrinking for smaller APK
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            signingConfig = signingConfigs.getByName("release")
        }
    }
    
    // Optimize packaging
    packaging {
        resources {
            excludes += listOf(
                "META-INF/DEPENDENCIES",
                "META-INF/LICENSE",
                "META-INF/LICENSE.txt",
                "META-INF/NOTICE",
                "META-INF/NOTICE.txt",
                "META-INF/*.kotlin_module"
            )
        }
    }

    // kotlinOptions removed; configured globally below
    
    // Auto-copy split APKs to the Flutter output directory
    applicationVariants.all {
         if (name == "release") {
             val variant = this
             outputs.all {
                 val output = this
                 val outputFile = output.outputFile
                 if (outputFile != null && outputFile.name.endsWith(".apk")) {
                     val flutterOutput = rootProject.file("../build/app/outputs/flutter-apk")
                     // Use assembleProvider.get().doLast to run AFTER build
                     variant.assembleProvider.get().doLast {
                         if (!flutterOutput.exists()) flutterOutput.mkdirs()
                         copy {
                             from(outputFile)
                             into(flutterOutput)
                         }
                         println("✅ Copied ${outputFile.name} to ${flutterOutput.absolutePath}")
                     }
                 }
             }
         }
    }
}

// Global configuration for Kotlin tasks - correct place for compilerOptions
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    // Use NIO variant for URLDecoder(String, Charset) support required by NewPipe
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs_nio:2.0.4")
    
    // NewPipe Extractor for on-device YouTube stream extraction
    // v0.25.1 has latest YouTube API fixes; NIO desugaring provides Java 10+ API support
    implementation("com.github.TeamNewPipe:NewPipeExtractor:v0.25.1")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.google.code.gson:gson:2.10.1")
}

flutter {
    source = "../.."
}
