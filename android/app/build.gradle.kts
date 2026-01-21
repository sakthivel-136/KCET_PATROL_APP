plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

val flutterVersionCode = flutter.versionCode
val flutterVersionName = flutter.versionName

android {
    namespace = "com.veripatrol.veripatrol"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // ENABLE DESUGARING HERE
        isCoreLibraryDesugaringEnabled = true 
        
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    defaultConfig {
        applicationId = "com.veripatrol.veripatrol"
        
        // Ensure minSdk is at least 21 for multidex/notifications
        minSdk = flutter.minSdkVersion 
        targetSdk = flutter.targetSdkVersion
        
        versionCode = flutterVersionCode
        versionName = flutterVersionName
        
        multiDexEnabled = true
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

// ADD THIS SECTION AT THE BOTTOM
dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.3")
}

flutter {
    source = "../.."
}
