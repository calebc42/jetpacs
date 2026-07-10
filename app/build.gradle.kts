import java.io.File

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

// The Glasspane shell: app identity (branding, theme, launcher activity,
// the org capture tile, the org keyboard toolbar) on top of the :jetpacs
// library, which carries the protocol, renderer, and OS surfaces.
android {
    namespace = "com.calebc42.jetpacs"
    compileSdk {
        version = release(36) {
            minorApiLevel = 1
        }
    }

    defaultConfig {
        applicationId = "com.calebc42.jetpacs"
        minSdk = 24
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
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

// The onboarding wizard hands a phone-only user (no PC, no adb) the
// foundation bundle and the token-substituted starter init — too large or
// too fiddly for the clipboard. Stage them from the repo root into a
// generated assets dir wired through the Variant API, so they ship inside the
// APK (read back with AssetManager at runtime) and the copy is ordered before
// asset merge automatically.
abstract class StageOnboardingAssets : DefaultTask() {
    @get:org.gradle.api.tasks.InputFiles
    abstract val sources: org.gradle.api.file.ConfigurableFileCollection

    @get:org.gradle.api.tasks.OutputDirectory
    abstract val outputDir: org.gradle.api.file.DirectoryProperty

    @org.gradle.api.tasks.TaskAction
    fun stage() {
        val out = outputDir.get().asFile
        out.mkdirs()
        sources.files.forEach { it.copyTo(File(out, it.name), overwrite = true) }
    }
}

androidComponents {
    onVariants { variant ->
        val stage = tasks.register(
            "stage${variant.name.replaceFirstChar(Char::uppercase)}OnboardingAssets",
            StageOnboardingAssets::class,
        ) {
            sources.from(
                // Foundation assets only, BY DESIGN: this companion onboards
                // for the foundation and ships no Tier-1 app. Apps (Glasspane,
                // orgzly-native, yours) distribute their own bundles from their
                // own repos; the wizard teaches the download-and-adopt path.
                rootProject.file("docs/starter-init.el"),
                rootProject.file("jetpacs-core.el"),
                rootProject.file("emacs/apps/jetpacs-hello.el"),
            )
        }
        variant.sources.assets?.addGeneratedSourceDirectory(stage, StageOnboardingAssets::outputDir)
    }
}

dependencies {
    // The Jetpacs foundation (protocol, renderer, widgets/tiles, queue). Its
    // build file exposes the renderer stack as `api`, so Compose/Room types
    // used in shell code resolve through it.
    implementation(project(":jetpacs"))

    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.compose.material3)
    testImplementation(libs.junit)
    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(libs.androidx.espresso.core)
    androidTestImplementation(platform(libs.androidx.compose.bom))
    androidTestImplementation(libs.androidx.compose.ui.test.junit4)
    debugImplementation(libs.androidx.compose.ui.tooling)
    debugImplementation(libs.androidx.compose.ui.test.manifest)
}
