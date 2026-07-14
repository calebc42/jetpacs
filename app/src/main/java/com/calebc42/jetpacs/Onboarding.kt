package com.calebc42.jetpacs

import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Rocket
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import java.io.File

/**
 * First-run onboarding wizard, shown until an Emacs has paired at least once.
 *
 * It replaces the bare "Waiting for Emacs" screen with a branching setup flow.
 * The one hard constraint it works around: this companion (com.calebc42.jetpacs)
 * is a third app with its own UID, so it CANNOT write into Emacs's or Termux's
 * private sandboxes (/data/data/org.emacs, /data/data/com.termux) — the same
 * wall deploy.ps1 hits. So the wizard *generates* the files and hands them over
 * two ways:
 *
 *   - the small init snippet (one seam line + the pairing token) goes on the
 *     clipboard to paste (well under the Android clipboard ceiling);
 *   - the foundation files — jetpacs-init.el (the managed entry point the
 *     seam loads) and jetpacs-core.el (the bundle it adopts) — are written to
 *     /sdcard/Documents/jetpacs as a pair, the slot the seam and entry point read.
 *
 * The companion onboards for the FOUNDATION only. Tier-1 apps (Glasspane,
 * orgzly-native, yours) distribute their own single-file bundles from their
 * own repos; the wizard explains the generic install path (download → list
 * it in ~/.emacs.d/jetpacs/apps.el) without shipping or naming any app.
 */
private enum class OnbStep { WELCOME, ADVANCED, DELIVER, PAIR }

/** Where init.el lives depends on whether the Termux HOME redirect is active. */
private fun initPath(termux: Boolean): String =
    if (termux) "/data/data/com.termux/files/home/.emacs.d/init.el"
    else "/data/data/org.emacs/files/.emacs.d/init.el"

private const val EARLY_INIT_PATH = "/data/data/org.emacs/files/.emacs.d/early-init.el"

/**
 * Jetpacs's dedicated staging subfolder under shared Documents, and its on-disk
 * path. This is the single slot the seam (jetpacs-init.el) and core
 * (`jetpacs-staging-dirs`) read from: a subfolder so Jetpacs's files stay
 * together instead of loose in the Documents root.
 */
private const val STAGING_SUBDIR = "jetpacs"
private const val STAGING_DIR = "/sdcard/Documents/jetpacs"

/** The Termux single-source-of-truth redirect, pasted into early-init.el. */
private const val EARLY_INIT_SNIPPET = """;; 1. REDIRECT HOME TO TERMUX
(setenv "HOME" "/data/data/com.termux/files/home")
(setq default-directory "/data/data/com.termux/files/home/")
(setq user-emacs-directory "/data/data/com.termux/files/home/.emacs.d/")

;; Force Emacs to re-evaluate what "~/" means globally
(setq abbreviated-home-dir nil)

;; 2. INJECT TERMUX BINARIES
;; Ensures Emacs can always find the Termux FOSS tools
(setenv "PATH" (concat "/data/data/com.termux/files/usr/bin:" (getenv "PATH")))
(add-to-list 'exec-path "/data/data/com.termux/files/usr/bin")

;; (custom-file is set by the Jetpacs entry point, from this HOME.)

;; DO NOT manually load init.el here. Emacs will naturally look for it
;; in your new user-emacs-directory when it is safe to do so.
"""

/** Minimal bootstrap for a user keeping their own init — the one seam line. */
private fun byoSnippet(token: String): String = """;; Jetpacs companion bootstrap — add near the TOP of your own init.el.
;;
;; One line loads Jetpacs's managed entry point (like `(load custom-file)`).
;; First run copies it in from /sdcard/Documents/jetpacs (staged by this app);
;; after that it self-updates. Everything Jetpacs manages lives under
;; ~/.emacs.d/jetpacs/; install apps by listing them in jetpacs/apps.el.
(let ((entry (expand-file-name "jetpacs/jetpacs-init.el" user-emacs-directory))
      (staged "/sdcard/Documents/jetpacs/jetpacs-init.el"))
  (when (and (file-readable-p staged)
             (or (not (file-exists-p entry))
                 (file-newer-than-file-p staged entry)))
    (make-directory (file-name-directory entry) t)
    (copy-file staged entry t))
  (unless (load entry t)
    (message "Jetpacs: %s is missing and nothing is staged at %s — run the companion app's setup, and check that Emacs can read shared storage" entry staged)))
(setq jetpacs-auth-token "$token")
"""

private fun readAsset(context: Context, name: String): ByteArray =
    context.assets.open(name).use { it.readBytes() }

/** The starter init from docs/, with the pairing token substituted live in. */
private fun starterInit(context: Context, token: String): String {
    val template = String(readAsset(context, "starter-init.el"))
    return template.replace(
        ";; (setq jetpacs-auth-token \"PASTE-YOUR-PAIRING-LINE-HERE\")",
        "(setq jetpacs-auth-token \"$token\")",
    )
}

private fun copyToClipboard(context: Context, label: String, text: String) {
    val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    cm.setPrimaryClip(ClipData.newPlainText(label, text))
    // Android 13+ shows its own clipboard confirmation overlay.
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
        Toast.makeText(context, "Copied", Toast.LENGTH_SHORT).show()
    }
}

/**
 * Write a bundled asset [name] into /sdcard/Documents/jetpacs so Emacs can adopt
 * it on next launch. API 29+ goes through MediaStore (no permission); older
 * devices write that public dir directly (guarded by WRITE_EXTERNAL_STORAGE,
 * requested before this is called). Returns the on-disk path.
 */
private fun installAssetToDocuments(context: Context, name: String): String {
    val bytes = readAsset(context, name)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        val resolver = context.contentResolver
        val collection = MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        // Drop any prior copy so init.el always sees a strictly newer file.
        // Prefix match, not equality: older companions declared text/plain,
        // which made MediaStore mangle the name ("name.txt", "name (2).txt");
        // sweep those variants too so retries don't pile up junk.
        resolver.query(
            collection,
            arrayOf(MediaStore.MediaColumns._ID),
            "${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ? AND " +
                "${MediaStore.MediaColumns.DISPLAY_NAME} LIKE ?",
            arrayOf("${Environment.DIRECTORY_DOCUMENTS}/$STAGING_SUBDIR/%", "$name%"),
            null,
        )?.use { c ->
            val idCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
            while (c.moveToNext()) {
                resolver.delete(ContentUris.withAppendedId(collection, c.getLong(idCol)), null, null)
            }
        }
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            // octet-stream is the one MIME type MediaStore never "fixes" the
            // extension for; anything text-like gets .txt appended and Emacs
            // then can't find the file under its staged name.
            put(MediaStore.MediaColumns.MIME_TYPE, "application/octet-stream")
            // MediaStore creates the jetpacs/ subfolder under Documents as needed.
            put(MediaStore.MediaColumns.RELATIVE_PATH, "${Environment.DIRECTORY_DOCUMENTS}/$STAGING_SUBDIR")
        }
        val uri = resolver.insert(collection, values)
            ?: throw java.io.IOException("MediaStore rejected the insert")
        resolver.openOutputStream(uri)?.use { it.write(bytes) }
            ?: throw java.io.IOException("Could not open the target for writing")
        // MediaStore may still have renamed the file (e.g. a leftover copy
        // owned by a previous install collides, so it uniquifies to
        // "name (2)"). The staged name is the contract with init.el — a
        // rename means Emacs will never see this file, so fail loudly.
        val storedName = resolver.query(
            uri, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null,
        )?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
        if (storedName != name) {
            resolver.delete(uri, null, null)
            throw java.io.IOException(
                "Android stored it as \"${storedName ?: "?"}\" instead of \"$name\" — " +
                    "probably a leftover copy from an older install is in the way. " +
                    "Delete $name from Documents/jetpacs in the Files app and retry.",
            )
        }
        return "$STAGING_DIR/$name"
    } else {
        @Suppress("DEPRECATION")
        val dir = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOCUMENTS),
            STAGING_SUBDIR,
        )
        dir.mkdirs()
        val file = File(dir, name)
        file.writeBytes(bytes)
        return file.absolutePath
    }
}

/**
 * The on-disk path of a previously-installed asset [name] in the public
 * Documents/jetpacs dir, or null if none is there. Mirrors
 * [installAssetToDocuments]'s two storage paths so a re-run can show an
 * already-installed state.
 */
private fun findInstalledBundle(context: Context, name: String): String? {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        val resolver = context.contentResolver
        val collection = MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        resolver.query(
            collection,
            arrayOf(MediaStore.MediaColumns._ID),
            "${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ? AND " +
                "${MediaStore.MediaColumns.DISPLAY_NAME} = ?",
            arrayOf("${Environment.DIRECTORY_DOCUMENTS}/$STAGING_SUBDIR/%", name),
            null,
        )?.use { c -> if (c.moveToFirst()) return "$STAGING_DIR/$name" }
        return null
    } else {
        @Suppress("DEPRECATION")
        val docs = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOCUMENTS)
        val file = File(File(docs, STAGING_SUBDIR), name)
        return if (file.exists()) file.absolutePath else null
    }
}

@Composable
internal fun OnboardingFlow() {
    var step by remember { mutableStateOf(OnbStep.WELCOME) }
    var byo by remember { mutableStateOf(false) }
    var termux by remember { mutableStateOf(false) }

    when (step) {
        OnbStep.WELCOME -> WelcomeStep(
            onStart = {
                byo = false
                termux = false
                step = OnbStep.DELIVER
            },
            onAdvanced = { step = OnbStep.ADVANCED },
            onSkipToPair = { step = OnbStep.PAIR },
        )
        OnbStep.ADVANCED -> AdvancedSetupStep(
            onUseExistingConfig = {
                byo = true
                termux = false
                step = OnbStep.DELIVER
            },
            onUseTermux = {
                byo = false
                termux = true
                step = OnbStep.DELIVER
            },
            onBack = { step = OnbStep.WELCOME },
        )
        OnbStep.DELIVER -> DeliverStep(
            byo = byo,
            termux = termux,
            onNext = { step = OnbStep.PAIR },
            onBack = { step = if (byo || termux) OnbStep.ADVANCED else OnbStep.WELCOME },
        )
        OnbStep.PAIR -> Box(Modifier.fillMaxSize()) {
            PairingScreen(instructions = pairInstructions(byo))
            BackChip(
                modifier = Modifier.align(Alignment.TopStart).statusBarsPadding().padding(8.dp),
                onClick = { step = OnbStep.DELIVER },
            )
            StepDots(
                index = 2,
                total = 2,
                modifier = Modifier.align(Alignment.TopCenter).statusBarsPadding().padding(top = 12.dp),
            )
        }
    }
}

/** Path-aware pairing guidance for the final onboarding step. */
private fun pairInstructions(byo: Boolean): String =
    if (byo) {
        "You added the Jetpacs bootstrap to your own init.\n\n" +
            "Restart Emacs (or re-evaluate your init) — it loads the core and " +
            "connects automatically. If it doesn't, run M-x jetpacs-connect.\n\n" +
            "This screen updates the moment the handshake completes."
    } else {
        "Your init.el is ready, with the pairing token already in it.\n\n" +
            "Just start Emacs — it loads the Jetpacs core and connects " +
            "automatically. There are no commands to run.\n\n" +
            "This screen updates the moment the handshake completes."
    }

@Composable
private fun StepScaffold(
    onBack: (() -> Unit)?,
    index: Int = 0,
    total: Int = 0,
    content: @Composable ColumnScope.() -> Unit,
) {
    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .statusBarsPadding()
                .verticalScroll(rememberScrollState())
                .padding(24.dp),
        ) {
            if (onBack != null) {
                BackChip(onClick = onBack)
                Spacer(Modifier.height(8.dp))
            }
            if (total > 0) {
                StepDots(index, total, Modifier.align(Alignment.CenterHorizontally))
                Spacer(Modifier.height(16.dp))
            }
            content()
        }
    }
}

/** A row of [total] progress dots with the first [index] filled (current = last filled). */
@Composable
private fun StepDots(index: Int, total: Int, modifier: Modifier = Modifier) {
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
        repeat(total) { i ->
            val done = i < index
            Box(
                Modifier
                    .size(if (i == index - 1) 10.dp else 8.dp)
                    .clip(CircleShape)
                    .background(
                        if (done) MaterialTheme.colorScheme.primary
                        else MaterialTheme.colorScheme.surfaceVariant,
                    ),
            )
        }
    }
}

@Composable
private fun BackChip(modifier: Modifier = Modifier, onClick: () -> Unit) {
    TextButton(onClick = onClick, modifier = modifier) {
        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back", modifier = Modifier.size(18.dp))
        Spacer(Modifier.size(4.dp))
        Text("Back")
    }
}

@Composable
private fun WelcomeStep(
    onStart: () -> Unit,
    onAdvanced: () -> Unit,
    onSkipToPair: () -> Unit,
) {
    StepScaffold(onBack = null) {
        Icon(
            Icons.Default.Rocket,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary,
            modifier = Modifier.size(56.dp).padding(bottom = 8.dp),
        )
        Text("Set up Jetpacs", style = MaterialTheme.typography.headlineMedium)
        Text(
            "Jetpacs is the phone face of an Emacs running on this device — " +
                "a foundation that Emacs apps plug into. Let's get Emacs " +
                "configured and paired.",
            style = MaterialTheme.typography.bodyMedium,
            modifier = Modifier.padding(top = 8.dp, bottom = 24.dp),
        )
        Button(onClick = onStart, modifier = Modifier.fillMaxWidth()) {
            Text("Set up Jetpacs")
        }
        Spacer(Modifier.height(8.dp))
        OutlinedButton(onClick = onAdvanced, modifier = Modifier.fillMaxWidth()) {
            Text("Advanced setup")
        }
        Spacer(Modifier.height(24.dp))
        TextButton(onClick = onSkipToPair, modifier = Modifier.align(Alignment.CenterHorizontally)) {
            Text("Already set up? Skip to pairing")
        }
    }
}

@Composable
private fun AdvancedSetupStep(
    onUseExistingConfig: () -> Unit,
    onUseTermux: () -> Unit,
    onBack: () -> Unit,
) {
    StepScaffold(onBack = onBack) {
        Text("Advanced setup", style = MaterialTheme.typography.headlineSmall)
        Text(
            "Choose one of these only if you already manage your Emacs configuration " +
                "or use a shared Termux environment.",
            style = MaterialTheme.typography.bodyMedium,
            modifier = Modifier.padding(top = 8.dp, bottom = 20.dp),
        )
        Button(onClick = onUseExistingConfig, modifier = Modifier.fillMaxWidth()) {
            Text("Use my existing init.el")
        }
        Spacer(Modifier.height(8.dp))
        OutlinedButton(onClick = onUseTermux, modifier = Modifier.fillMaxWidth()) {
            Text("Use a shared Termux home")
        }
        Text(
            "Most people do not need either option. Go back and choose Set up Jetpacs " +
                "for the standard standalone configuration.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 16.dp),
        )
        Text(
            "The Termux option is for an Emacs APK signed to share Termux's identity.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 8.dp),
        )
    }
}

@Composable
private fun SetupProgressScaffold(
    onBack: () -> Unit,
    content: @Composable ColumnScope.() -> Unit,
) {
    StepScaffold(onBack = onBack, index = 1, total = 2) {
        content()
    }
}

@Composable
private fun DeliverStep(byo: Boolean, termux: Boolean, onNext: () -> Unit, onBack: () -> Unit) {
    val context = LocalContext.current
    val token = remember { JetpacsAuth.token(context) }
    var installResult by remember { mutableStateOf<String?>(null) }
    var coreInstalled by remember { mutableStateOf(false) }
    var showAdvancedSave by remember(byo, termux) { mutableStateOf(byo || termux) }
    var showOptional by remember { mutableStateOf(false) }

    // On (re-)entry, detect an already-installed bundle so a repeat run reflects
    // that state instead of pretending nothing happened.
    LaunchedEffect(Unit) {
        if (!coreInstalled) {
            findInstalledBundle(context, "jetpacs-core.el")?.let {
                coreInstalled = true
                if (installResult == null) installResult = "Already installed at $it"
            }
        }
    }

    // SAF fallback: let the user save the core bundle anywhere if Documents
    // fails or they'd rather choose the folder themselves. octet-stream, not
    // text/plain: the Files app appends .txt for text MIME types and the .el
    // name is the contract with init.el.
    val saf = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("application/octet-stream"),
    ) { uri ->
        if (uri != null) {
            installResult = try {
                val output = context.contentResolver.openOutputStream(uri)
                    ?: error("The selected location could not be opened")
                output.use {
                    it.write(readAsset(context, "jetpacs-core.el"))
                }
                // The seam still loads the entry file from Documents/jetpacs; stage it.
                runCatching { installAssetToDocuments(context, "jetpacs-init.el") }
                coreInstalled = true
                "Saved. The core bundle is adopted from Documents/jetpacs — if you chose " +
                    "another folder, move it there (or edit ~/.emacs.d/jetpacs/jetpacs-init.el)."
            } catch (e: Exception) {
                "Save failed: ${e.message}"
            }
        }
    }

    // The asset a pending storage-permission grant should install, so the
    // legacy (API ≤ 28) request can resume the same file it was launched for.
    var pendingInstall by remember { mutableStateOf("jetpacs-core.el") }

    // Legacy (API ≤ 28) needs the storage permission before a direct write.
    val storagePerm = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        installResult = if (granted) {
            runCatching {
                // The foundation is a pair: the entry file the seam loads, plus
                // the core bundle it adopts. Stage both together.
                if (pendingInstall == "jetpacs-core.el") {
                    installAssetToDocuments(context, "jetpacs-init.el")
                }
                installAssetToDocuments(context, pendingInstall)
            }
                .fold(
                    {
                        if (pendingInstall == "jetpacs-core.el") coreInstalled = true
                        "Installed to $it"
                    },
                    {
                        showAdvancedSave = true
                        "Install failed: ${it.message}"
                    },
                )
        } else {
            showAdvancedSave = true
            "Storage permission denied — use \"Save elsewhere…\" instead."
        }
    }

    val installAsset = { name: String ->
        val needsPerm = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q &&
            ContextCompat.checkSelfPermission(
                context, android.Manifest.permission.WRITE_EXTERNAL_STORAGE,
            ) != android.content.pm.PackageManager.PERMISSION_GRANTED
        if (needsPerm) {
            pendingInstall = name
            storagePerm.launch(android.Manifest.permission.WRITE_EXTERNAL_STORAGE)
        } else {
            installResult = runCatching {
                // Stage the entry file alongside the core bundle (the seam pair).
                if (name == "jetpacs-core.el") {
                    installAssetToDocuments(context, "jetpacs-init.el")
                }
                installAssetToDocuments(context, name)
            }
                .fold(
                    {
                        if (name == "jetpacs-core.el") coreInstalled = true
                        "Installed to $it"
                    },
                    {
                        showAdvancedSave = true
                        "Install failed: ${it.message}"
                    },
                )
        }
    }

    SetupProgressScaffold(onBack = onBack) {
        Text(
            if (byo || termux) "Finish advanced setup" else "Finish setting up Jetpacs",
            style = MaterialTheme.typography.headlineSmall,
        )
        Text(
            if (byo || termux) {
                "Copy the configuration into Emacs, then install the Jetpacs foundation."
            } else {
                "Two quick steps prepare Emacs and install Jetpacs on this device."
            },
            style = MaterialTheme.typography.bodyMedium,
            modifier = Modifier.padding(top = 6.dp, bottom = 16.dp),
        )

        var stepNo = 1

        if (termux) {
            TermuxStorageCard(number = stepNo++)
            SnippetCard(
                number = stepNo++,
                title = "Termux redirect → early-init.el",
                body = "Create this file and paste the snippet. It points Emacs's HOME at " +
                    "Termux so both share one config and the Termux tools.",
                path = EARLY_INIT_PATH,
                copyText = EARLY_INIT_SNIPPET,
            )
        }

        SnippetCard(
            number = stepNo++,
            title = if (byo) "Bootstrap → your init.el" else "Copy the starter configuration",
            body = if (byo) {
                "You keep your own init — just add these lines (the one-line Jetpacs " +
                    "seam and your pairing token) near the top of it."
            } else {
                "A complete starter init, with your pairing token already filled in. " +
                    "Paste it as your whole init.el."
            },
            path = initPath(termux),
            copyText = if (byo) byoSnippet(token) else starterInit(context, token),
            showPathInitially = byo || termux,
        )

        // Install the foundation bundle.
        Card(Modifier.fillMaxWidth().padding(bottom = 12.dp)) {
            Column(Modifier.padding(16.dp)) {
                Text("$stepNo. Install Jetpacs", style = MaterialTheme.typography.titleMedium)
                Text(
                    "Save the Jetpacs foundation where the starter configuration can find it.",
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.padding(top = 4.dp, bottom = 12.dp),
                )
                if (coreInstalled) {
                    FilledTonalButton(
                        onClick = { installAsset("jetpacs-core.el") },
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Icon(Icons.Default.Check, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.size(6.dp))
                        Text("Jetpacs installed — reinstall")
                    }
                } else {
                    Button(onClick = { installAsset("jetpacs-core.el") }, modifier = Modifier.fillMaxWidth()) {
                        Text("Install Jetpacs")
                    }
                }
                if (!showAdvancedSave) {
                    TextButton(
                        onClick = { showAdvancedSave = true },
                        modifier = Modifier.align(Alignment.CenterHorizontally),
                    ) {
                        Text("Choose another save location")
                    }
                } else {
                    Spacer(Modifier.height(8.dp))
                    OutlinedButton(
                        onClick = { saf.launch("jetpacs-core.el") },
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text("Save somewhere else…")
                    }
                }
                installResult?.let {
                    Text(
                        it,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.padding(top = 10.dp),
                    )
                }
            }
        }

        TextButton(
            onClick = { showOptional = !showOptional },
            modifier = Modifier.align(Alignment.CenterHorizontally),
        ) {
            Text(if (showOptional) "Hide optional extras" else "Optional: apps and hello demo")
        }

        if (showOptional) {
            // Apps are not shipped by this companion — explain the generic path.
            Card(Modifier.fillMaxWidth().padding(bottom = 12.dp)) {
                Column(Modifier.padding(16.dp)) {
                    Text("Get apps", style = MaterialTheme.typography.titleMedium)
                    Text(
                        "Apps for Jetpacs (like Glasspane) ship as single .el bundles from " +
                            "their own projects. Download one in your browser, move it into the " +
                            "Documents/jetpacs folder, then add its file name to " +
                            "~/.emacs.d/jetpacs/apps.el and restart Emacs. Each app's own " +
                            "instructions cover the rest.",
                        style = MaterialTheme.typography.bodySmall,
                        modifier = Modifier.padding(top = 4.dp),
                    )
                }
            }

            // The built-in demo: the smallest possible Tier-1 app.
            Card(Modifier.fillMaxWidth().padding(bottom = 12.dp)) {
                Column(Modifier.padding(16.dp)) {
                    Text("Try the hello demo", style = MaterialTheme.typography.titleMedium)
                    Text(
                        "jetpacs-hello.el is a complete app in ~60 lines. Install it, then — " +
                            "once paired — evaluate this from the Eval tab to grow a Hello tab " +
                            "live:\n\n(load \"/sdcard/Documents/jetpacs/jetpacs-hello.el\")",
                        style = MaterialTheme.typography.bodySmall,
                        modifier = Modifier.padding(top = 4.dp, bottom = 12.dp),
                    )
                    OutlinedButton(
                        onClick = { installAsset("jetpacs-hello.el") },
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text("Install jetpacs-hello.el")
                    }
                }
            }
        }

        Spacer(Modifier.height(8.dp))
        Button(
            onClick = onNext,
            enabled = coreInstalled || byo || termux,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(if (coreInstalled) "Continue to connection" else "Install Jetpacs to continue")
        }
        Spacer(Modifier.height(24.dp))
    }
}

/**
 * The Termux storage-access step, shown only on the shared-Termux path. Emacs
 * shares Termux's identity and redirects HOME there, so it reaches the staged
 * Jetpacs bundle in /sdcard through Termux's storage grant — not the companion's.
 * `termux-setup-storage` requests that permission (and creates the ~/storage
 * symlinks) once. It runs in the Termux app; the companion can't reach into
 * Termux's sandbox to do it.
 */
@Composable
private fun TermuxStorageCard(number: Int) {
    val context = LocalContext.current
    var copied by remember { mutableStateOf(false) }
    Card(Modifier.fillMaxWidth().padding(bottom = 12.dp)) {
        Column(Modifier.padding(16.dp)) {
            Text("$number. Grant Termux storage access", style = MaterialTheme.typography.titleMedium)
            Text(
                "Emacs shares Termux's identity, so it reads the Jetpacs bundle from " +
                    "shared storage through Termux's permission. Run this once in the " +
                    "Termux app and approve the storage prompt.",
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.padding(top = 4.dp, bottom = 10.dp),
            )
            Surface(
                shape = RoundedCornerShape(8.dp),
                color = MaterialTheme.colorScheme.surfaceVariant,
                modifier = Modifier.fillMaxWidth().padding(bottom = 10.dp),
            ) {
                Text(
                    "termux-setup-storage",
                    style = MaterialTheme.typography.labelSmall,
                    fontFamily = FontFamily.Monospace,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth().padding(8.dp),
                )
            }
            val onCopy = {
                copyToClipboard(context, "termux-setup-storage", "termux-setup-storage")
                copied = true
            }
            if (copied) {
                FilledTonalButton(onClick = onCopy, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.Default.Check, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.size(6.dp))
                    Text("Copied — copy again")
                }
            } else {
                Button(onClick = onCopy, modifier = Modifier.fillMaxWidth()) {
                    Text("Copy command")
                }
            }
        }
    }
}

@Composable
private fun SnippetCard(
    number: Int,
    title: String,
    body: String,
    path: String,
    copyText: String,
    showPathInitially: Boolean = true,
) {
    val context = LocalContext.current
    var copied by remember { mutableStateOf(false) }
    var showPath by remember(showPathInitially) { mutableStateOf(showPathInitially) }
    Card(Modifier.fillMaxWidth().padding(bottom = 12.dp)) {
        Column(Modifier.padding(16.dp)) {
            Text("$number. $title", style = MaterialTheme.typography.titleMedium)
            Text(
                body,
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.padding(top = 4.dp, bottom = 10.dp),
            )
            if (showPath) {
                Surface(
                    shape = RoundedCornerShape(8.dp),
                    color = MaterialTheme.colorScheme.surfaceVariant,
                    modifier = Modifier.fillMaxWidth().padding(bottom = 10.dp),
                ) {
                    Text(
                        path,
                        style = MaterialTheme.typography.labelSmall,
                        fontFamily = FontFamily.Monospace,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.fillMaxWidth().padding(8.dp),
                    )
                }
            } else {
                TextButton(
                    onClick = { showPath = true },
                    modifier = Modifier.align(Alignment.CenterHorizontally),
                ) {
                    Text("Show init.el location")
                }
            }
            val onCopy = { copyToClipboard(context, "jetpacs-$number", copyText); copied = true }
            if (copied) {
                FilledTonalButton(onClick = onCopy, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.Default.Check, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.size(6.dp))
                    Text("Copied — copy again")
                }
            } else {
                Button(onClick = onCopy, modifier = Modifier.fillMaxWidth()) {
                    Text("Copy snippet")
                }
            }
        }
    }
}
