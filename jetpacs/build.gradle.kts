plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.ksp)
}

// The Jetpacs library: protocol, renderer, offline queue, and the OS surfaces
// (widgets, tiles, notifications) — everything a host companion app needs
// short of its own identity. The Glasspane shell in :app is one host; the
// boundary rule is ARCHITECTURE.md's: this module carries no app opinion
// and names no host class (launch goes through JetpacsLaunch, editor toolbars
// through the JetpacsToolbars registry).
android {
    namespace = "com.calebc42.jetpacs.core"
    compileSdk {
        version = release(36) {
            minorApiLevel = 1
        }
    }

    defaultConfig {
        minSdk = 24

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        consumerProguardFiles("consumer-rules.pro")
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
    buildFeatures {
        compose = true
    }
}

dependencies {
    // `api`, not `implementation`: hosts compose their UI out of these types
    // (RenderChildren, SduiNode, RadialMenu, the state objects), so the
    // renderer stack is part of this module's contract surface.
    val roomVersion = "2.6.1"
    api("androidx.room:room-runtime:$roomVersion")
    api("androidx.room:room-ktx:$roomVersion")
    ksp("androidx.room:room-compiler:$roomVersion")
    api(libs.androidx.core.ktx)
    api(libs.androidx.lifecycle.runtime.ktx)
    // BackHandler (RadialMenu, SduiScaffold) lives in activity-compose.
    api(libs.androidx.activity.compose)
    api(platform(libs.androidx.compose.bom))
    api(libs.androidx.compose.ui)
    api(libs.androidx.compose.ui.graphics)
    api(libs.androidx.compose.material3)
    api("androidx.compose.material:material-icons-extended")
    api("io.coil-kt:coil-compose:2.6.0")
}
