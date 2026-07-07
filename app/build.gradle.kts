import java.io.File

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

// The Glasspane shell: app identity (branding, theme, launcher activity,
// the org capture tile, the org keyboard toolbar) on top of the :eabp
// library, which carries the protocol, renderer, and OS surfaces.
android {
    namespace = "com.calebc42.eabp"
    compileSdk {
        version = release(36) {
            minorApiLevel = 1
        }
    }

    defaultConfig {
        applicationId = "com.calebc42.eabp"
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

// The onboarding wizard hands a phone-only user (no PC, no adb) the 827 KB
// glasspane.el bundle and the token-substituted starter init — both too large
// or too fiddly for the clipboard. Stage them from the repo root into a
// generated assets dir wired through the Variant API, so they ship inside the
// APK (read back with AssetManager at runtime) and the copy is ordered before
// asset merge automatically.
abstract class StageGlasspaneAssets : DefaultTask() {
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
            "stage${variant.name.replaceFirstChar(Char::uppercase)}GlasspaneAssets",
            StageGlasspaneAssets::class,
        ) {
            sources.from(
                rootProject.file("glasspane.el"),
                rootProject.file("docs/starter-init.el"),
                // Demo-only extras (eabp-core + the tiny Tier-1 sample), shipped
                // so the wizard can install them separately. Likely temporary —
                // drop these two lines and the "Demo bundles" card in
                // Onboarding.kt to remove.
                rootProject.file("eabp-core.el"),
                rootProject.file("emacs/apps/eabp-hello.el"),
            )
        }
        variant.sources.assets?.addGeneratedSourceDirectory(stage, StageGlasspaneAssets::outputDir)
    }
}

dependencies {
    // The EABP foundation (protocol, renderer, widgets/tiles, queue). Its
    // build file exposes the renderer stack as `api`, so Compose/Room types
    // used in shell code resolve through it.
    implementation(project(":eabp"))

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
