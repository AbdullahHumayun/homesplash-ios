plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// CI passes the run number so every build installs over the previous one.
val buildNumber = (System.getenv("VERSION_CODE") ?: "1").toInt()
val keystore: String? = System.getenv("KEYSTORE_FILE")

android {
    namespace = "com.abdullahhumayun.homesplash.tv"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.abdullahhumayun.homesplash.tv"
        minSdk = 23
        targetSdk = 35
        versionCode = buildNumber
        versionName = "1.0.$buildNumber"
    }

    signingConfigs {
        create("release") {
            if (keystore != null) {
                storeFile = file(keystore)
                storePassword = System.getenv("KEYSTORE_PASSWORD")
                keyAlias = System.getenv("KEY_ALIAS") ?: "homesplash"
                keyPassword = System.getenv("KEYSTORE_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            // fixed key from CI secrets so updates install in place; debug key as a fallback for forks
            signingConfig = if (keystore != null) signingConfigs.getByName("release")
                            else signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}
