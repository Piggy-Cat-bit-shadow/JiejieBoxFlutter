package com.jiejiebox.app.bridge

import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.lang.reflect.InvocationHandler
import java.lang.reflect.InvocationTargetException
import java.lang.reflect.Method
import java.lang.reflect.Proxy

/**
 * The single place that talks to libbox.
 *
 * The gomobile AAR is an optional build artefact: when `io.nekohasekai.libbox`
 * is on the classpath this object drives the real CommandServer and the real
 * config functions through reflection, so the source stays compilable before the
 * AAR lands. When the AAR is absent every capability is false and every call
 * fails with `core_unavailable` rather than pretending.
 */
object JjboxCore {
    private const val PACKAGE = "io.nekohasekai.libbox"

    @Volatile
    var isLoaded: Boolean = false
        private set

    var vpnPermissionGranted: Boolean = false
    var hasCameraScanner: Boolean = false

    private var libboxClass: Class<*>? = null
    private var commandServer: Any? = null
    private var commandServerClass: Class<*>? = null
    private var setupDone = false
    private var running = false
    @Volatile
    private var tunFd: Int = -1
    @Volatile
    private var startFailure: String? = null

    private var basePath: String = ""
    private var appVersion: String = ""
    private val lock = Any()

    fun setup(args: JSONObject) {
        basePath = args.optString("basePath")
        appVersion = args.optString("appVersion")
        if (basePath.isBlank()) {
            basePath = args.optString("dataDir")
        }
        if (basePath.isNotBlank()) {
            runCatching { requireLibbox() }
        }
    }

    fun capabilities(): JSONObject = JSONObject()
        .put("apiVersion", if (isLoaded) 4 else 0)
        .put("buildId", if (isLoaded) "linked" else JSONObject.NULL)
        .put("buildQuic", isLoaded)
        .put("platform", "android")
        .put("version", appVersion)
        .put("goVersion", JSONObject.NULL)
        .put("capabilities", JSONArray())

    fun checkConfig(content: String): JSONObject {
        val libbox = requireLibbox()
        try {
            libbox.getMethod("checkConfig", String::class.java).invoke(null, content)
            return JSONObject().put("ok", true).put("normalizedKind", "singbox-json")
        } catch (error: InvocationTargetException) {
            throw CoreException("core_rejected_config", coreMessage(error))
        }
    }

    fun formatConfig(content: String): JSONObject {
        val libbox = requireLibbox()
        val formatted = try {
            stringBoxValue(
                libbox.getMethod("formatConfig", String::class.java)
                    .invoke(null, content),
            )
        } catch (error: InvocationTargetException) {
            throw CoreException("core_rejected_config", coreMessage(error))
        } ?: throw CoreException("core_rejected_config", "formatConfig returned no document")
        return JSONObject().put(
            "content",
            Base64.encodeToString(formatted.toByteArray(Charsets.UTF_8), Base64.NO_WRAP),
        )
    }

    fun preview(content: String): JSONObject {
        val libbox = requireLibbox()
        val preview = try {
            stringBoxValue(
                libbox.getMethod("parsePreview", String::class.java)
                    .invoke(null, content),
            )
        } catch (error: InvocationTargetException) {
            throw CoreException("invalid_argument", coreMessage(error))
        } ?: throw CoreException("invalid_argument", "parsePreview returned no document")
        return JSONObject(preview)
    }

    fun refreshProviders(tags: String): JSONObject {
        // Provider refresh needs a live CommandClient; the host has no provider
        // manager wired yet. This is a capability answer, not a fake success.
        return JSONObject()
            .put("supported", false)
            .put("refreshed", JSONArray())
            .put("failed", JSONArray())
            .put("durationMillis", 0)
    }

    @Synchronized
    fun startService(content: String) {
        val libbox = requireLibbox()
        ensureSetup(libbox)
        val overrideClass = Class.forName("$PACKAGE.OverrideOptions")
        val override = overrideClass.getDeclaredConstructor().newInstance()
        if (running) {
            val method = commandServerClass!!.getMethod(
                "startOrReloadService",
                String::class.java,
                overrideClass,
            )
            invokeCommand(method, content, override)
            return
        }
        val serverClass = Class.forName("$PACKAGE.CommandServer")
        val handlerClass = Class.forName("$PACKAGE.CommandServerHandler")
        val platformClass = Class.forName("$PACKAGE.PlatformInterface")
        val handler = newProxy(handlerClass) { method, _ -> handlerDefault(method) }
        val platform = newProxy(platformClass) { method, args -> platformDefault(method, args) }
        val server = try {
            serverClass.getConstructor(handlerClass, platformClass).newInstance(handler, platform)
        } catch (error: InvocationTargetException) {
            throw CoreException("core_unavailable", coreMessage(error))
        }
        commandServer = server
        commandServerClass = serverClass
        val method = serverClass.getMethod(
            "startOrReloadService",
            String::class.java,
            overrideClass,
        )
        invokeCommand(method, content, override)
        running = true
    }

    @Synchronized
    fun stopService() {
        val server = commandServer ?: return
        try {
            server.javaClass.getMethod("closeService").invoke(server)
        } catch (error: InvocationTargetException) {
            throw CoreException("core_stop_failed", coreMessage(error))
        } finally {
            running = false
            tunFd = -1
        }
    }

    @Synchronized
    fun isRunning(): Boolean = running

    fun openTun(fd: Int): Boolean {
        // TUN is not wired yet: the Android adapter advertises tun=false and
        // service modes ["proxy"]. Do not hand a detached fd to a stub.
        return false
    }

    fun closeTun() = Unit

    /** The VpnService has established the descriptor the core will adopt. */
    fun attachTun(fd: Int) {
        tunFd = fd
    }

    fun clearTun() {
        tunFd = -1
    }

    fun reportFailure(message: String) {
        startFailure = message
    }

    fun consumeFailure(): String? {
        val failure = startFailure
        startFailure = null
        return failure
    }

    private fun requireLibbox(): Class<*> {
        if (!isLoaded) {
            val loaded = try {
                Class.forName("$PACKAGE.Libbox")
            } catch (_: ClassNotFoundException) {
                null
            }
            if (loaded == null) {
                throw CoreException("core_unavailable", "libbox AAR is not linked into this build")
            }
            libboxClass = loaded
            isLoaded = true
        }
        return libboxClass!!
    }

    private fun ensureSetup(libbox: Class<*>) {
        if (setupDone) return
        if (basePath.isBlank()) {
            throw CoreException("core_unavailable", "basePath is not configured")
        }
        File(basePath, "core").mkdirs()
        File(basePath, "temp").mkdirs()
        val optionsClass = Class.forName("$PACKAGE.SetupOptions")
        val options = optionsClass.getDeclaredConstructor().newInstance()
        setField(options, "basePath", basePath)
        setField(options, "workingPath", File(basePath, "core").absolutePath)
        setField(options, "tempPath", File(basePath, "temp").absolutePath)
        setField(options, "appVersion", appVersion)
        setField(options, "logMaxLines", 1000)
        setField(options, "debug", false)
        try {
            libbox.getMethod("setup", optionsClass).invoke(null, options)
        } catch (error: InvocationTargetException) {
            throw CoreException("core_unavailable", coreMessage(error))
        }
        setupDone = true
    }

    private fun invokeCommand(method: Method, content: String, override: Any?) {
        try {
            method.invoke(commandServer, content, override)
        } catch (error: InvocationTargetException) {
            throw CoreException("core_start_failed", coreMessage(error))
        }
    }

    private fun setField(target: Any, name: String, value: Any) {
        val capitalized = name.replaceFirstChar { it.uppercaseChar() }
        val candidates = listOf(name, capitalized, "set$capitalized")
        for (candidate in candidates) {
            val field = target.javaClass.fields.firstOrNull { it.name == candidate }
                ?: target.javaClass.declaredFields.firstOrNull { it.name == candidate }
            if (field != null) {
                field.isAccessible = true
                field.set(target, coerce(value, field.type))
                return
            }
            val setter = target.javaClass.methods.firstOrNull {
                it.name == candidate && it.parameterCount == 1
            }
            if (setter != null) {
                setter.invoke(target, coerce(value, setter.parameterTypes[0]))
                return
            }
        }
    }

    private fun coerce(value: Any, type: Class<*>): Any = when {
        type == java.lang.Long.TYPE || type == java.lang.Long::class.java ->
            (value as Number).toLong()
        type == java.lang.Integer.TYPE || type == java.lang.Integer::class.java ->
            (value as Number).toInt()
        else -> value
    }

    private fun stringBoxValue(value: Any?): String? {
        if (value == null) return null
        if (value is String) return value
        return try {
            value.javaClass.getMethod("getValue").invoke(value) as? String
        } catch (_: Exception) {
            value.toString()
        }
    }

    private fun handlerDefault(method: Method): Any? = when (method.name) {
        "connectSSHAgent" -> 0
        else -> defaultValue(method.returnType)
    }

    private fun platformDefault(method: Method, args: Array<out Any?>?): Any? {
        return when (method.name) {
            "usePlatformInterface",
            "usePlatformAutoDetectInterfaceControl",
            "underNetworkExtension",
            "includeAllNetworks",
            "usePlatformShell",
            "usePlatformBridge",
            "usePlatformAutoRedirect" -> false
            "getInterfaces", "localDNSTransport" -> null
            "openTun" -> {
                val fd = tunFd
                if (fd < 0) {
                    throw UnsupportedOperationException("TUN descriptor is not attached")
                }
                fd
            }
            else -> defaultValue(method.returnType)
        }
    }

    private fun defaultValue(type: Class<*>): Any? = when (type) {
        java.lang.Boolean.TYPE -> false
        java.lang.Byte.TYPE -> 0.toByte()
        java.lang.Short.TYPE -> 0.toShort()
        java.lang.Integer.TYPE -> 0
        java.lang.Long.TYPE -> 0L
        java.lang.Float.TYPE -> 0f
        java.lang.Double.TYPE -> 0.0
        java.lang.Character.TYPE -> '\u0000'
        else -> null
    }

    private fun newProxy(iface: Class<*>, block: (Method, Array<out Any?>?) -> Any?): Any {
        return Proxy.newProxyInstance(iface.classLoader, arrayOf(iface), InvocationHandler { _, method, args ->
            when (method.name) {
                "toString" -> "JjboxProxy(${iface.simpleName})"
                "hashCode" -> System.identityHashCode(iface)
                "equals" -> false
                else -> block(method, args)
            }
        })
    }

    private fun coreMessage(error: InvocationTargetException): String {
        val cause = error.targetException ?: error
        return cause.message ?: cause.javaClass.simpleName
    }
}

class CoreException(val code: String, override val message: String) : Exception(message)
