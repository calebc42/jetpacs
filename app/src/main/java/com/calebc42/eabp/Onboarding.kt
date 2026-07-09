package com.calebc42.eabp

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
 * The one hard constraint it works around: this companion (com.calebc42.eabp)
 * is a third app with its own UID, so it CANNOT write into Emacs's or Termux's
 * private sandboxes (/data/data/org.emacs, /data/data/com.termux) — the same
 * wall deploy.ps1 hits. So the wizard *generates* the files and hands them over
 * two ways:
 *
 *   - the small init snippets go on the clipboard to paste (well under the
 *     Android clipboard ceiling);
 *   - the 827 KB glasspane.el bundle (clipboard is hopeless) is written to
 *     /sdcard/Documents, the slot the starter init.el already adopts from.
 */
private enum class OnbStep { WELCOME, TERMUX, DELIVER, PAIR }

/** Where init.el lives depends on whether the Termux HOME redirect is active. */
private fun initPath(termux: Boolean): String =
    if (termux) "/data/data/com.termux/files/home/.emacs.d/init.el"
    else "/data/data/org.emacs/files/.emacs.d/init.el"

private const val EARLY_INIT_PATH = "/data/data/org.emacs/files/.emacs.d/early-init.el"

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

;; 3. LOAD THE TERMUX INIT.EL
;; Guarantee that Emacs boots using your Single Source of Truth configuration
(setq custom-file "/data/data/com.termux/files/home/.emacs.d/custom.el")
(load "/data/data/com.termux/files/home/.emacs.d/init.el" t t)
"""

/** Minimal bootstrap for a user keeping their own init — just the essentials. */
private fun byoSnippet(token: String): String = """;; Glasspane companion bootstrap — add to your own init.el.
;;
;; Optional packages that unlock Glasspane features — install them with your
;; own package manager (MELPA). Each feature degrades to absent when missing,
;; so none are required to pair:
;;   org-ql   — saved queries as table / board / calendar views
;;   org-srs  — spaced-repetition review
;;   vulpea   — wikilink autocomplete, backlinks & unlinked mentions
(add-to-list 'load-path (expand-file-name "elisp" user-emacs-directory))
(let ((staged (seq-filter #'file-readable-p
                          '("/sdcard/Documents/glasspane.el"
                            "/sdcard/Download/glasspane.el")))
      (installed (expand-file-name "elisp/glasspane.el" user-emacs-directory)))
  (dolist (s staged)
    (when (or (not (file-exists-p installed))
              (file-newer-than-file-p s installed))
      (make-directory (file-name-directory installed) t)
      (copy-file s installed t))))
(require 'glasspane)
(glasspane-config-ensure)
(setq eabp-auth-token "$token")
"""

private fun readAsset(context: Context, name: String): ByteArray =
    context.assets.open(name).use { it.readBytes() }

/** The starter init from docs/, with the pairing token substituted live in. */
private fun starterInit(context: Context, token: String): String {
    val template = String(readAsset(context, "starter-init.el"))
    return template.replace(
        ";; (setq eabp-auth-token \"PASTE-YOUR-PAIRING-LINE-HERE\")",
        "(setq eabp-auth-token \"$token\")",
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
 * Write a bundled asset [name] into /sdcard/Documents so Emacs can adopt it on
 * next launch. API 29+ goes through MediaStore (no permission); older devices
 * write the public Documents dir directly (guarded by WRITE_EXTERNAL_STORAGE,
 * requested before this is called). Returns the on-disk path.
 */
private fun installAssetToDocuments(context: Context, name: String): String {
    val bytes = readAsset(context, name)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        val resolver = context.contentResolver
        val collection = MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        // Drop any prior copy so init.el always sees a strictly newer file.
        resolver.query(
            collection,
            arrayOf(MediaStore.MediaColumns._ID),
            "${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ? AND " +
                "${MediaStore.MediaColumns.DISPLAY_NAME} = ?",
            arrayOf("${Environment.DIRECTORY_DOCUMENTS}/%", name),
            null,
        )?.use { c ->
            val idCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
            while (c.moveToNext()) {
                resolver.delete(ContentUris.withAppendedId(collection, c.getLong(idCol)), null, null)
            }
        }
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, "text/plain")
            put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOCUMENTS)
        }
        val uri = resolver.insert(collection, values)
            ?: throw java.io.IOException("MediaStore rejected the insert")
        resolver.openOutputStream(uri)?.use { it.write(bytes) }
            ?: throw java.io.IOException("Could not open the target for writing")
        return "/sdcard/Documents/$name"
    } else {
        @Suppress("DEPRECATION")
        val dir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOCUMENTS)
        dir.mkdirs()
        val file = File(dir, name)
        file.writeBytes(bytes)
        return file.absolutePath
    }
}

/**
 * The on-disk path of a previously-installed asset [name] in the public
 * Documents dir, or null if none is there. Mirrors [installAssetToDocuments]'s
 * two storage paths so a re-run can show an already-installed state.
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
            arrayOf("${Environment.DIRECTORY_DOCUMENTS}/%", name),
            null,
        )?.use { c -> if (c.moveToFirst()) return "/sdcard/Documents/$name" }
        return null
    } else {
        @Suppress("DEPRECATION")
        val file = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOCUMENTS), name)
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
            onChoose = { chosenByo ->
                byo = chosenByo
                step = if (chosenByo) OnbStep.DELIVER else OnbStep.TERMUX
            },
            onSkipToPair = { step = OnbStep.PAIR },
        )
        OnbStep.TERMUX -> TermuxStep(
            onAnswer = { t -> termux = t; step = OnbStep.DELIVER },
            onBack = { step = OnbStep.WELCOME },
        )
        OnbStep.DELIVER -> DeliverStep(
            byo = byo,
            termux = termux,
            onNext = { step = OnbStep.PAIR },
            onBack = { step = if (byo) OnbStep.WELCOME else OnbStep.TERMUX },
        )
        OnbStep.PAIR -> Box(Modifier.fillMaxSize()) {
            PairingScreen(instructions = pairInstructions(byo))
            BackChip(
                modifier = Modifier.align(Alignment.TopStart).statusBarsPadding().padding(8.dp),
                onClick = { step = OnbStep.DELIVER },
            )
            StepDots(
                index = if (byo) 2 else 3,
                total = if (byo) 2 else 3,
                modifier = Modifier.align(Alignment.TopCenter).statusBarsPadding().padding(top = 12.dp),
            )
        }
    }
}

/** Path-aware pairing guidance for the final onboarding step. */
private fun pairInstructions(byo: Boolean): String =
    if (byo) {
        "You added the Glasspane bootstrap to your own init.\n\n" +
            "Restart Emacs (or re-evaluate your init) — it loads Glasspane and " +
            "connects automatically. If it doesn't, run M-x eabp-connect.\n\n" +
            "This screen updates the moment the handshake completes."
    } else {
        "Your init.el is ready, with the pairing token already in it.\n\n" +
            "Just start Emacs — it loads Glasspane and connects automatically. " +
            "There are no commands to run.\n\n" +
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
private fun WelcomeStep(onChoose: (Boolean) -> Unit, onSkipToPair: () -> Unit) {
    StepScaffold(onBack = null) {
        Icon(
            Icons.Default.Rocket,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary,
            modifier = Modifier.size(56.dp).padding(bottom = 8.dp),
        )
        Text("Set up Glasspane", style = MaterialTheme.typography.headlineMedium)
        Text(
            "Glasspane is the phone face of an Emacs running on this device. " +
                "Let's get Emacs configured and paired.",
            style = MaterialTheme.typography.bodyMedium,
            modifier = Modifier.padding(top = 8.dp, bottom = 24.dp),
        )
        Text("Are you bringing your own Emacs config?", style = MaterialTheme.typography.titleMedium)
        Spacer(Modifier.height(12.dp))
        Button(onClick = { onChoose(false) }, modifier = Modifier.fillMaxWidth()) {
            Text("No — set me up (recommended)")
        }
        Spacer(Modifier.height(8.dp))
        OutlinedButton(onClick = { onChoose(true) }, modifier = Modifier.fillMaxWidth()) {
            Text("Yes — I manage my own init.el")
        }
        Spacer(Modifier.height(24.dp))
        TextButton(onClick = onSkipToPair, modifier = Modifier.align(Alignment.CenterHorizontally)) {
            Text("Already set up? Skip to pairing")
        }
    }
}

@Composable
private fun TermuxStep(onAnswer: (Boolean) -> Unit, onBack: () -> Unit) {
    // Reached only on the guided (non-BYO) path: step 1 of 3 (termux → deliver → pair).
    StepScaffold(onBack = onBack, index = 1, total = 3) {
        Text("Is Emacs sharing a signature with Termux?", style = MaterialTheme.typography.titleMedium)
        Text(
            "If your Emacs APK is signed to share Termux's identity, it can run Termux's " +
                "FOSS tools and boot from a single init.el in Termux's home. If you're not " +
                "sure, you're probably not — choose \"No\".",
            style = MaterialTheme.typography.bodyMedium,
            modifier = Modifier.padding(top = 8.dp, bottom = 20.dp),
        )
        Button(onClick = { onAnswer(true) }, modifier = Modifier.fillMaxWidth()) {
            Text("Yes — redirect Emacs to Termux")
        }
        Spacer(Modifier.height(8.dp))
        OutlinedButton(onClick = { onAnswer(false) }, modifier = Modifier.fillMaxWidth()) {
            Text("No — standalone Emacs")
        }
    }
}

@Composable
private fun DeliverStep(byo: Boolean, termux: Boolean, onNext: () -> Unit, onBack: () -> Unit) {
    val context = LocalContext.current
    val token = remember { EabpAuth.token(context) }
    var installResult by remember { mutableStateOf<String?>(null) }
    var glasspaneInstalled by remember { mutableStateOf(false) }

    // On (re-)entry, detect an already-installed bundle so a repeat run reflects
    // that state instead of pretending nothing happened.
    LaunchedEffect(Unit) {
        if (!glasspaneInstalled) {
            findInstalledBundle(context, "glasspane.el")?.let {
                glasspaneInstalled = true
                if (installResult == null) installResult = "Already installed at $it"
            }
        }
    }

    // SAF fallback: let the user save the bundle anywhere if Documents fails
    // or they'd rather choose the folder themselves.
    val saf = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("text/plain"),
    ) { uri ->
        if (uri != null) {
            installResult = try {
                context.contentResolver.openOutputStream(uri)?.use {
                    it.write(readAsset(context, "glasspane.el"))
                }
                "Saved. If the folder you chose isn't Documents or Download, edit init.el's " +
                    "adopt paths to point there."
            } catch (e: Exception) {
                "Save failed: ${e.message}"
            }
        }
    }

    // The asset a pending storage-permission grant should install, so the
    // legacy (API ≤ 28) request can resume the same file it was launched for.
    var pendingInstall by remember { mutableStateOf("glasspane.el") }

    // Legacy (API ≤ 28) needs the storage permission before a direct write.
    val storagePerm = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        installResult = if (granted) {
            runCatching { installAssetToDocuments(context, pendingInstall) }
                .fold(
                    {
                        if (pendingInstall == "glasspane.el") glasspaneInstalled = true
                        "Installed to $it"
                    },
                    { "Install failed: ${it.message}" },
                )
        } else {
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
            installResult = runCatching { installAssetToDocuments(context, name) }
                .fold(
                    {
                        if (name == "glasspane.el") glasspaneInstalled = true
                        "Installed to $it"
                    },
                    { "Install failed: ${it.message}" },
                )
        }
    }

    StepScaffold(onBack = onBack, index = if (byo) 1 else 2, total = if (byo) 2 else 3) {
        Text("Copy these onto your device", style = MaterialTheme.typography.headlineSmall)
        Text(
            "Glasspane can't write into Emacs's private folders (Android sandboxing), so " +
                "paste each snippet into the file named on its card, then install the bundle.",
            style = MaterialTheme.typography.bodyMedium,
            modifier = Modifier.padding(top = 6.dp, bottom = 16.dp),
        )

        var stepNo = 1

        if (termux) {
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
            title = if (byo) "Bootstrap → your init.el" else "Starter init.el",
            body = if (byo) {
                "You keep your own init — just add these lines (bundle adopt, require, " +
                    "and your pairing token) somewhere in it. The snippet also lists " +
                    "optional packages (org-ql, org-srs, vulpea) that unlock more features."
            } else {
                "A complete starter init, with your pairing token already filled in. " +
                    "Paste it as your whole init.el."
            },
            path = initPath(termux),
            copyText = if (byo) byoSnippet(token) else starterInit(context, token),
        )

        // Install the bundle.
        Card(Modifier.fillMaxWidth().padding(bottom = 12.dp)) {
            Column(Modifier.padding(16.dp)) {
                Text("$stepNo. Install glasspane.el", style = MaterialTheme.typography.titleMedium)
                Text(
                    "The 827 KB bundle is too big for the clipboard. This writes it to " +
                        "/sdcard/Documents, where the init above adopts it on next launch.",
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.padding(top = 4.dp, bottom = 12.dp),
                )
                if (glasspaneInstalled) {
                    FilledTonalButton(
                        onClick = { installAsset("glasspane.el") },
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Icon(Icons.Default.Check, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.size(6.dp))
                        Text("Installed — reinstall")
                    }
                } else {
                    Button(onClick = { installAsset("glasspane.el") }, modifier = Modifier.fillMaxWidth()) {
                        Text("Install to Documents")
                    }
                }
                Spacer(Modifier.height(8.dp))
                OutlinedButton(
                    onClick = { saf.launch("glasspane.el") },
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text("Save elsewhere…")
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

        // Demo bundles — TEMPORARY (see build.gradle.kts asset staging). Lets
        // eabp-core and the tiny Tier-1 sample be installed on their own for a
        // live demo. Delete this card and the two asset lines to remove.
        Card(Modifier.fillMaxWidth().padding(bottom = 12.dp)) {
            Column(Modifier.padding(16.dp)) {
                Text("Demo bundles (dev)", style = MaterialTheme.typography.titleMedium)
                Text(
                    "Install the foundation-only core or the ~60-line Tier-1 sample to " +
                        "/sdcard/Documents to demo them apart from Glasspane.",
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.padding(top = 4.dp, bottom = 12.dp),
                )
                OutlinedButton(
                    onClick = { installAsset("eabp-core.el") },
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text("Install eabp-core.el")
                }
                Spacer(Modifier.height(8.dp))
                OutlinedButton(
                    onClick = { installAsset("eabp-hello.el") },
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text("Install eabp-hello.el")
                }
            }
        }

        Spacer(Modifier.height(8.dp))
        Button(onClick = onNext, modifier = Modifier.fillMaxWidth()) {
            Text("Done — pair Emacs")
        }
        Spacer(Modifier.height(24.dp))
    }
}

@Composable
private fun SnippetCard(
    number: Int,
    title: String,
    body: String,
    path: String,
    copyText: String,
) {
    val context = LocalContext.current
    var copied by remember { mutableStateOf(false) }
    Card(Modifier.fillMaxWidth().padding(bottom = 12.dp)) {
        Column(Modifier.padding(16.dp)) {
            Text("$number. $title", style = MaterialTheme.typography.titleMedium)
            Text(
                body,
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.padding(top = 4.dp, bottom = 10.dp),
            )
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
            val onCopy = { copyToClipboard(context, "glasspane-$number", copyText); copied = true }
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
