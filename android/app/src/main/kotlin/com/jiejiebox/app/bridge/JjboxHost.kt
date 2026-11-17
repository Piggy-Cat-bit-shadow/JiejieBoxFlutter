package com.jiejiebox.app.bridge

import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest

/**
 * Handles the bridge envelope on Android: capability answers, profile storage and
 * the service lifecycle. The core itself sits behind [JjboxCore] so the shell can
 * answer `unsupported_platform` and report core:false before the AAR is linked.
 */
class JjboxHost(
    private val context: Context,
    private val emit: (JSONObject) -> Unit,
) {
    private val lifetime = JjboxLifetime()
    private val profilesDir = File(context.filesDir, "profiles").apply { mkdirs() }

    fun detach() = Unit

    fun handle(method: String, args: JSONObject, reply: (JSONObject) -> Unit) {
        runCatching { route(method, args) }
            .onSuccess { reply(it) }
            .onFailure { failure ->
                if (failure is JjboxCorruptProfileException) {
                    reply(error("storage_corrupt", failure.message ?: "profile corrupt", false))
                } else {
                    reply(error("internal", failure.message ?: failure.javaClass.simpleName, false))
                }
            }
    }

    private fun route(method: String, args: JSONObject): JSONObject = when (method) {
        "host.capabilities" -> ok(capabilities())
        "core.capabilities" -> ok(JjboxCore.capabilities())
        "host.setup" -> {
            JjboxCore.setup(args)
            ok(JSONObject())
        }
        "host.shutdown" -> {
            context.startService(JjboxVpnService.intent(context, JjboxVpnService.ACTION_STOP))
            lifetime.close(lifetime.revision + 1)
            ok(JSONObject())
        }
        "service.start" -> serviceStart(args)
        "service.stop" -> serviceStop(args)
        "service.status" -> ok(status())
        "config.check" -> coreCall { JjboxCore.checkConfig(args.optString("content")) }
        "config.format" -> coreCall { JjboxCore.formatConfig(args.optString("content")) }
        "config.preview" -> {
            if (!JjboxCore.isLoaded) error("unsupported_platform", "ParsePreview is not in this build", false)
            else coreCall { JjboxCore.preview(args.optString("content")) }
        }
        "profile.list" -> ok(profileList())
        "profile.read" -> profileRead(args)
        "profile.write" -> profileWrite(args)
        "profile.delete" -> profileDelete(args)
        "profile.apply" -> profileApply(args)
        "provider.refresh" -> coreCall { JjboxCore.refreshProviders(args.optString("tags")) }
        "systemProxy.apply", "systemProxy.status" ->
            error("unsupported_platform", "the system proxy is a desktop capability", false)
        "tun.requestPermission" -> ok(
            JSONObject()
                .put("status", if (JjboxCore.vpnPermissionGranted) "granted" else "unrequested")
                .put("asked", false),
        )
        "qr.scan" -> if (JjboxCore.hasCameraScanner) {
            error("unsupported_platform", "scanning runs in the activity, P2", false)
        } else {
            error("unsupported_platform", "no camera scanner", false)
        }
        "clipboard.readCandidate" -> ok(clipboardCandidate())
        "file.pickConfig" ->
            error("unsupported_platform", "the file picker is Activity-bound; it lands in P3 with the import page", false)
        "app.setAutoLaunch" -> error("unsupported_platform", "no desktop shell", false)
        "tray.update" -> error("unsupported_platform", "no desktop shell", false)
        else -> error("unsupported_platform", "unknown method $method", false)
    }

    private fun serviceStart(args: JSONObject): JSONObject {
        val revision = args.optInt("revision", 0)
        val mode = args.optString("mode", "proxy")
        val needsPermission = mode == "vpn"
        val outcome = lifetime.start(revision, needsPermission)
        if (outcome == "pending") {
            context.startService(
                JjboxVpnService.intent(context, JjboxVpnService.ACTION_START)
                    .putExtra(JjboxVpnService.EXTRA_MODE, mode),
            )
            emit(stateEvent())
        }
        return ok(JSONObject().put("accepted", outcome != "rejected:closed").put("revision", revision))
    }

    private fun serviceStop(args: JSONObject): JSONObject {
        val revision = args.optInt("revision", 0)
        val outcome = lifetime.stop(revision)
        if (outcome == "pending") {
            context.startService(JjboxVpnService.intent(context, JjboxVpnService.ACTION_STOP))
            emit(stateEvent())
        }
        return ok(JSONObject().put("accepted", outcome != "rejected:closed").put("revision", revision))
    }

    private fun status(): JSONObject = lifetime.statusJson()
        .put("sinceMillis", 0)
        .put("mode", "proxy")
        .put("tunActive", lifetime.state == JjboxLifetime.State.RUNNING)
        .put("permission", if (JjboxCore.vpnPermissionGranted) "granted" else "unrequested")

    private fun stateEvent(): JSONObject = JSONObject()
        .put("type", "service.state")
        .put("seq", nextSeq())
        .put("data", status())

    private var seq = 0
    private fun nextSeq(): Int = ++seq

    private fun capabilities(): JSONObject = JSONObject()
        .put("core", JjboxCore.isLoaded)
        .put("tun", true)
        .put("systemProxy", false)
        .put("perAppProxy", true)
        .put("autostart", false)
        .put("tray", false)
        .put("qrCamera", JjboxCore.hasCameraScanner)
        .put("qrImageDecode", true)
        .put("fileImport", true)
        .put("clipboardWatch", true)
        .put("notifications", true)
        .put("deepLink", true)
        .put("memoryPressure", true)
        .put("serviceModes", JSONArray().put("vpn").put("proxy"))

    /**
     * Reads the clipboard only. Promotion still requires an explicit user action and
     * a foreground app; that gate lives in Dart (ClipboardGate), so this never saves.
     */
    private fun clipboardCandidate(): JSONObject {
        val manager = context.getSystemService(ClipboardManager::class.java)
        val text = manager?.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.text?.toString()
        return JSONObject()
            .put("text", text ?: JSONObject.NULL)
            .put("likely", classifyClipboard(text))
    }

    private fun classifyClipboard(text: String?): String {
        if (text.isNullOrBlank()) return "unknown"
        if (text.startsWith("http://") || text.startsWith("https://")) return "subscription-url"
        val schemes = listOf("vless://", "vmess://", "trojan://", "ss://", "ssr://", "tuic://", "hysteria2://", "hy2://", "anytls://", "socks://")
        if (schemes.any { text.startsWith(it) }) return "share-link"
        if (text.startsWith("{")) return "singbox-json"
        if (text.startsWith("proxies:")) return "clash-yaml"
        return "unknown"
    }

    private fun profileList(): JSONObject {
        val items = JSONArray()
        profilesDir.listFiles { file -> file.name.endsWith(".meta.json") }
            ?.sortedBy { it.name }
            ?.forEach { metaFile ->
                val meta = try {
                    readMetaFile(metaFile)
                } catch (corrupt: JjboxCorruptProfileException) {
                    null
                } ?: return@forEach
                val body = File(profilesDir, meta.optString("id") + ".json")
                items.put(
                    JSONObject()
                        .put("id", meta.optString("id"))
                        .put("label", meta.optString("label"))
                        .put("kind", meta.optString("kind"))
                        .put("revision", meta.optString("revision"))
                        .put("updatedAtMillis", meta.optLong("updatedAtMillis"))
                        .put("source", "local")
                        .put("bytes", body.length()),
                )
            }
        return JSONObject().put("items", items)
    }

    private fun profileRead(args: JSONObject): JSONObject {
        val id = args.optString("id")
        val meta = readMeta(id) ?: return error("invalid_argument", "no such profile $id", false)
        val body = File(profilesDir, "$id.json").readText()
        return ok(
            JSONObject()
                .put("id", id)
                .put("content", android.util.Base64.encodeToString(body.toByteArray(), android.util.Base64.NO_WRAP))
                .put("revision", meta.optString("revision"))
                .put("updatedAtMillis", meta.optLong("updatedAtMillis")),
        )
    }

    private fun profileWrite(args: JSONObject): JSONObject {
        val expected = if (args.isNull("expectedRevision")) null else args.optString("expectedRevision")
        val id = if (args.isNull("id")) "p" + System.currentTimeMillis() else args.optString("id")
        val existing = readMeta(id)
        if (expected != null && existing?.optString("revision") != expected) {
            return error("revision_mismatch", "expectedRevision mismatch", true)
        }
        val content = String(
            android.util.Base64.decode(args.optString("content"), android.util.Base64.NO_WRAP),
        )
        val revision = sha256(content)
        // temp + fsync + rename: a crash leaves either the old body or the new one.
        val body = File(profilesDir, "$id.json")
        val temp = File(profilesDir, "$id.json.tmp")
        temp.outputStream().use { stream ->
            stream.write(content.toByteArray())
            stream.flush()
            stream.fd.sync()
        }
        if (!temp.renameTo(body)) {
            return error("storage_write_failed", "rename failed", true)
        }
        val meta = JSONObject()
            .put("id", id)
            .put("label", args.optString("label"))
            .put("kind", args.optString("kind", "local"))
            .put("revision", revision)
            .put("updatedAtMillis", System.currentTimeMillis())
        File(profilesDir, "$id.meta.json").writeText(meta.toString())
        return ok(
            JSONObject()
                .put("id", id)
                .put("revision", revision)
                .put("bytes", content.toByteArray().size)
                .put("validated", args.optBoolean("validate", true)),
        )
    }

    private fun profileDelete(args: JSONObject): JSONObject {
        val id = args.optString("id")
        val expected = if (args.isNull("expectedRevision")) null else args.optString("expectedRevision")
        val existing = readMeta(id) ?: return error("invalid_argument", "no such profile $id", false)
        if (expected != null && existing.optString("revision") != expected) {
            return error("revision_mismatch", "expectedRevision mismatch", true)
        }
        File(profilesDir, "$id.json").delete()
        File(profilesDir, "$id.meta.json").delete()
        return ok(JSONObject())
    }

    private fun profileApply(args: JSONObject): JSONObject {
        val id = args.optString("id")
        val meta = readMeta(id) ?: return error("invalid_argument", "no such profile $id", false)
        val outcome = lifetime.start(args.optInt("revision", 0), true)
        emit(stateEvent())
        return ok(
            JSONObject()
                .put("applied", outcome != "rejected:closed")
                .put("requestId", args.optString("requestId"))
                .put("coreMessage", "revision ${meta.optString("revision")}"),
        )
    }

    private fun readMeta(id: String): JSONObject? {
        val file = File(profilesDir, "$id.meta.json")
        if (!file.exists()) return null
        return runCatching { JSONObject(file.readText()) }.getOrNull()
    }

    private fun coreCall(block: () -> JSONObject): JSONObject {
        if (!JjboxCore.isLoaded) {
            return error("unsupported_platform", "libbox is not linked into this build", false)
        }
        return runCatching(block).getOrElse { error("core_start_failed", it.message ?: "core failure", true) }
    }

    private fun ok(result: JSONObject): JSONObject = JSONObject().put("ok", true).put("result", result)

    private fun error(code: String, message: String, retryable: Boolean): JSONObject = JSONObject()
        .put("ok", false)
        .put("error", JSONObject().put("code", code).put("message", message).put("retryable", retryable))

    private fun sha256(text: String): String =
        MessageDigest.getInstance("SHA-256").digest(text.toByteArray())
            .joinToString("") { "%02x".format(it) }
}
