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
    sourceSets {
        getByName("main") {
            kotlin.srcDir("build/generated/contract")
        }
    }
}

// ─── Generated wire vocabulary ───────────────────────────────────────────────
// SDUI_NODE_TYPES derives at build time from the contract's `node_types`
// (ebp/contract.json, the authored wire truth — ebp SPEC-CHANGES #30): the
// Kotlin leg of the same single-source-of-truth rule the elisp client
// follows (its lint tables derive at load). A wire change is an ebp
// amendment + submodule bump; this task follows automatically, and
// SduiRendererNodeTypesTest then holds the dispatcher to the new set.
val generateContractTypes by tasks.registering {
    val contract = rootProject.file("ebp/contract.json")
    val outRoot = layout.buildDirectory.dir("generated/contract")
    inputs.file(contract)
    outputs.dir(outRoot)
    doLast {
        @Suppress("UNCHECKED_CAST")
        val nodeTypes = (groovy.json.JsonSlurper()
            .parse(contract) as Map<String, Any?>)["node_types"] as List<String>
        val pkgDir = outRoot.get().dir("com/calebc42/jetpacs").asFile
        pkgDir.mkdirs()
        pkgDir.resolve("SduiNodeTypes.kt").writeText(buildString {
            appendLine("// GENERATED from ebp/contract.json (`node_types`) by :jetpacs generateContractTypes.")
            appendLine("// Do not edit — the contract is the authored truth (ebp SPEC-CHANGES #30).")
            appendLine("package com.calebc42.jetpacs")
            appendLine()
            appendLine("/**")
            appendLine(" * Every node type this build renders — the contract's `node_types`,")
            appendLine(" * published to the client in the welcome (SPEC §3, §9) so a newer")
            appendLine(" * client can detect a node this companion predates and render a")
            appendLine(" * fallback instead of relying on the unknown-node degradation.")
            appendLine(" *")
            appendLine(" * INVARIANT: the `when` in SduiNode renders exactly this set —")
            appendLine(" * `SduiRendererNodeTypesTest` fails when the dispatcher and the")
            appendLine(" * contract diverge, so a wire addition lands renderer support in")
            appendLine(" * the same change-set as the submodule bump.")
            appendLine(" */")
            appendLine("val SDUI_NODE_TYPES: Set<String> = setOf(")
            nodeTypes.forEach { appendLine("    \"$it\",") }
            appendLine(")")
        })
    }
}

tasks.named("preBuild") { dependsOn(generateContractTypes) }

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
    testImplementation(libs.junit)
    // The real org.json for plain-JVM unit tests: the SDK's mockable jar only
    // stubs it, and the conformance suite (WireGoldenConformanceTest) parses
    // the golden corpus and docs/contract.json with it.
    testImplementation("org.json:json:20240303")
}
