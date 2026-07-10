package com.calebc42.jetpacs

import android.content.Context
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Pairing-token authentication for the bridge (KDE Connect / Syncthing
 * pairing model, HMAC instead of TLS certs).
 *
 * Loopback binding keeps the socket off the network, but any app on this
 * device can connect to 127.0.0.1 — so the handshake must prove identity in
 * BOTH directions: Emacs proves it holds the token before the companion
 * trusts its actions, and the companion proves the same back so a rogue app
 * that squatted the port first can't harvest Emacs's surface pushes.
 *
 * The token is generated once, lives in app-private prefs, is shown to the
 * user on the pairing screen, and never crosses the wire — only nonce-bound
 * HMACs do:
 *
 *   hello → challenge{nonce_s} → response{nonce_c, mac} → welcome{server_proof}
 *
 *   mac          = HMAC(token, "jetpacs1:client:nonce_s:nonce_c")
 *   server_proof = HMAC(token, "jetpacs1:server:nonce_c:nonce_s")
 */
object JetpacsAuth {
    private const val PREFS = "jetpacs"
    private const val KEY_TOKEN = "pairing_token"
    private const val KEY_PAIRED = "has_paired"

    /** Crockford base32: no I/L/O/U, so the token survives being read aloud. */
    private const val ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

    /** The device's pairing token, generated on first use (80 bits). */
    fun token(context: Context): String {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        prefs.getString(KEY_TOKEN, null)?.let { return it }
        val rnd = SecureRandom()
        val fresh = CharArray(16) { ALPHABET[rnd.nextInt(ALPHABET.length)] }
            .toList().chunked(4).joinToString("-") { it.joinToString("") }
        prefs.edit().putString(KEY_TOKEN, fresh).apply()
        return fresh
    }

    /**
     * True once any Emacs has completed the pairing handshake on this device.
     * Gates the UI: until it flips true, the pairing screen wins even over a
     * cached dashboard, so a not-yet-paired user can always reach the token
     * instead of staring at a stale surface from a pre-auth session.
     */
    fun hasPaired(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean(KEY_PAIRED, false)

    fun markPaired(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putBoolean(KEY_PAIRED, true).apply()
    }

    /** Lowercase-hex HMAC-SHA256 of [message] keyed by [key], both UTF-8. */
    fun hmacHex(key: String, message: String): String {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key.toByteArray(Charsets.UTF_8), "HmacSHA256"))
        return mac.doFinal(message.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
    }

    /** Constant-time MAC comparison — never compare MACs with ==. */
    fun macEquals(a: String, b: String): Boolean =
        MessageDigest.isEqual(a.toByteArray(Charsets.UTF_8), b.toByteArray(Charsets.UTF_8))

    /** A fresh random nonce as 32 hex chars. */
    fun newNonce(): String {
        val bytes = ByteArray(16)
        SecureRandom().nextBytes(bytes)
        return bytes.joinToString("") { "%02x".format(it) }
    }
}
