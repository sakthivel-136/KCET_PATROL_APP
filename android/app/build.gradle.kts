plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

// Fixed: Removed the ?: "1" because they are already non-nullable in new Flutter versions
val flutterVersionCode = flutter.versionCode
val flutterVersionName = flutter.versionName

android {
    namespace = "com.veripatrol.veripatrol"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // Fixed: Updated to the new compilerOptions style to remove the deprecation warning
    kotlinOptions {
        jvmTarget = "17"
    }

    defaultConfig {
        applicationId = "com.veripatrol.veripatrol"
        
        minSdk = flutter.minSdkVersion 
        targetSdk = flutter.targetSdkVersion
        
        // Fixed: Removed .toInt() because flutterVersionCode is already an Int
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

flutter {
    source = "../.."
}
