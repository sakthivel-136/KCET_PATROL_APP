plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    // Standard namespace for your package
    namespace = "com.veripatrol.veripatrol"
    
    // Using modern Flutter defaults (API 34 or 35+)
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // Required for using Java 8+ features on older devices
        isCoreLibraryDesugaringEnabled = true
        
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    defaultConfig {
        applicationId = "com.veripatrol.veripatrol"
        
        // Bumping to 24 as required by Flutter 3.35+ and modern plugins
        minSdk = 24 
        targetSdk = flutter.targetSdkVersion
        
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        
        // Necessary if your app grows large
        multiDexEnabled = true
    }

    buildTypes {
        release {
            // Replace with your actual release signing config when ready
            signingConfig = signingConfigs.getByName("debug")
            
            // Recommended: enable shrinking for smaller APKs
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

dependencies {
    // Specifically version 2.0.3+ for modern Java feature support
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
}

flutter {
    source = "../.."
}