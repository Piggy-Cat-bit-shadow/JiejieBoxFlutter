package com.jiejiebox.app.bridge

import org.json.JSONArray
import org.json.JSONObject
import java.lang.reflect.InvocationHandler
import java.lang.reflect.Method
import java.lang.reflect.Proxy
import java.util.ArrayDeque
import java.util.UUID

/**
 * App-process runtime subscription.
 *
 * The core's CommandServer listens on a unix socket under the host's base path; the
 * app opens a CommandClient to the same path and receives groups/status/connections/
 * logs as callbacks. Callbacks are serialized into the runtime contract events that
 * `events.poll` drains.
 *
 * Reflection is used because the AAR is an optional build artifact: the host must
 * stay compilable before libbox.aar exists. Once linked, the names below match the
 * gomobile Java binding exactly (`io.nekohasekai.libbox`).
 */
object JjboxRuntime {
    val hostEpoch: String = UUID.randomUUID().toString()

    private const val PACKAGE = "io.nekohasekai.libbox"
    private const val MAX_EVENTS = 4096

    private var client: Any? = null
    private var clientClass: Class<*>? = null
    private var seq: Long = 0
    private val events = ArrayDeque<String>()
    private val lock = Any()
    private var lastGroups: List<JSONObject> = emptyList()

    fun start() {
        synchronized(lock) {
            if (client != null) return
            val libbox = try {
                Class.forName("$PACKAGE.Libbox")
            } catch (_: ClassNotFoundException) {
                return
            }
            val handlerClass = Class.forName("$PACKAGE.CommandClientHandler")
            val optionsClass = Class.forName("$PACKAGE.CommandClientOptions")
            val handler = Proxy.newProxyInstance(
                handlerClass.classLoader,
                arrayOf(handlerClass),
                InvocationHandler { _, method, args -> handleCallback(method, args) },
            )
            val options = optionsClass.getDeclaredConstructor().newInstance()
            runCatching {
                optionsClass.getMethod("setStatusInterval", java.lang.Long.TYPE)
                    .invoke(options, 1000L)
            }
            val created = try {
                libbox.getMethod("newCommandClient", handlerClass, optionsClass)
                    .invoke(null, handler, options)
            } catch (_: Exception) {
                null
            } ?: return
            client = created
            clientClass = created.javaClass
            Thread {
                // The service socket may still be opening when Dart sends the
                // first runtime call; retry briefly instead of giving up once.
                for (attempt in 0 until 10) {
                    val connected = runCatching {
                        created.javaClass.getMethod("connect").invoke(created)
                    }.isSuccess
                    if (connected) return@Thread
                    Thread.sleep(100)
                }
            }.start()
        }
    }

    fun stop() {
        synchronized(lock) {
            val current = client ?: return
            client = null
            runCatching { current.javaClass.getMethod("disconnect").invoke(current) }
        }
    }

    fun poll(): String? = synchronized(lock) {
        if (events.isEmpty()) null else events.removeFirst()
    }

    fun select(group: String, outbound: String, expectedRevision: Long): JSONObject {
        val current = client ?: throw CoreException("core_unavailable", "command client is not running")
        val box = current.javaClass.getMethod(
            "selectOutboundWithRequest",
            String::class.java,
            String::class.java,
            java.lang.Long.TYPE,
            java.lang.Long.TYPE,
        ).invoke(current, group, outbound, 0L, expectedRevision)
        return stringBoxJson(box)
            ?: JSONObject().put("accepted", true).put("group", group).put("outbound", outbound)
    }

    fun urlTest(outbound: String) {
        val current = client ?: throw CoreException("core_unavailable", "command client is not running")
        current.javaClass.getMethod("urlTest", String::class.java).invoke(current, outbound)
    }

    fun setMode(mode: String) {
        val current = client ?: throw CoreException("core_unavailable", "command client is not running")
        current.javaClass.getMethod("setClashMode", String::class.java).invoke(current, mode)
    }

    fun setGroupExpand(group: String, expanded: Boolean) {
        val current = client ?: throw CoreException("core_unavailable", "command client is not running")
        current.javaClass.getMethod(
            "setGroupExpand",
            String::class.java,
            java.lang.Boolean.TYPE,
        ).invoke(current, group, expanded)
    }

    fun clearLogs() {
        val current = client ?: throw CoreException("core_unavailable", "command client is not running")
        current.javaClass.getMethod("clearLogs").invoke(current)
        emit("logs.cleared", JSONObject())
    }

    fun closeConnection(id: String) {
        val current = client ?: throw CoreException("core_unavailable", "command client is not running")
        current.javaClass.getMethod("closeConnection", String::class.java).invoke(current, id)
    }

    fun closeAllConnections() {
        val current = client ?: throw CoreException("core_unavailable", "command client is not running")
        current.javaClass.getMethod("closeConnections").invoke(current)
    }

    fun refreshProviders(tags: List<String>, timeoutMillis: Long): JSONObject {
        val current = client ?: throw CoreException("core_unavailable", "command client is not running")
        val box = current.javaClass.getMethod(
            "refreshRemoteProviders",
            String::class.java,
            java.lang.Long.TYPE,
        ).invoke(current, tags.joinToString(","), timeoutMillis)
        return stringBoxJson(box) ?: JSONObject().put("supported", false)
    }

    fun groupsSnapshot(): List<JSONObject> = synchronized(lock) { lastGroups }

    private fun handleCallback(method: Method, args: Array<out Any?>?): Any? {
        when (method.name) {
            "connected" -> emit("runtime.connected", JSONObject())
            "disconnected" -> emit(
                "runtime.disconnected",
                JSONObject().put("message", args?.firstOrNull()?.toString() ?: ""),
            )
            "initializeClashMode" -> {
                val modes = JSONArray()
                (args?.getOrNull(0) as? Any)?.let { iterator ->
                    while (hasNext(iterator)) {
                        modes.put(next(iterator)?.toString() ?: "")
                    }
                }
                emit(
                    "runtime.modes",
                    JSONObject()
                        .put("modes", modes)
                        .put("current", args?.getOrNull(1)?.toString() ?: "")
                        .put("available", modes.length() > 0),
                )
            }
            "updateClashMode" -> emit(
                "runtime.modes",
                JSONObject().put("current", args?.firstOrNull()?.toString() ?: "").put("available", true),
            )
            "writeGroups" -> emitGroups(args?.firstOrNull())
            "writeStatus" -> emitStatus(args?.firstOrNull())
            "writeLogs" -> emitLogs(args?.firstOrNull())
            "writeConnectionEvents" -> emitConnections(args?.firstOrNull())
            "clearLogs" -> emit("logs.cleared", JSONObject())
            else -> return null
        }
        return null
    }

    private fun emitGroups(iterator: Any?) {
        if (iterator == null) return
        val groups = JSONArray()
        val snapshot = mutableListOf<JSONObject>()
        while (hasNext(iterator)) {
            val group = next(iterator) ?: break
            val items = JSONArray()
            val itemIterator = call(group, "getItems")
            if (itemIterator != null) {
                while (hasNext(itemIterator)) {
                    val item = next(itemIterator) ?: break
                    items.put(
                        JSONObject()
                            .put("tag", callString(item, "getTag"))
                            .put("type", callString(item, "getType"))
                            .put("urlTestTime", callLong(item, "getURLTestTime"))
                            .put("urlTestDelay", callInt(item, "getURLTestDelay")),
                    )
                }
            }
            val record = JSONObject()
                .put("tag", callString(group, "getTag"))
                .put("type", callString(group, "getType"))
                .put("selectable", callBoolean(group, "getSelectable"))
                .put("selected", callString(group, "getSelected"))
                .put("expanded", callBoolean(group, "getIsExpand"))
                .put("items", items)
            groups.put(record)
            snapshot.add(record)
        }
        synchronized(lock) { lastGroups = snapshot }
        emit("runtime.groups", JSONObject().put("groups", groups))
    }

    private fun emitStatus(message: Any?) {
        if (message == null) return
        emit(
            "runtime.status",
            JSONObject()
                .put("serviceState", "running")
                .put("memoryBytes", callLong(message, "getMemory"))
                .put("goroutines", callInt(message, "getGoroutines"))
                .put("connectionsIn", callInt(message, "getConnectionsIn"))
                .put("connectionsOut", callInt(message, "getConnectionsOut"))
                .put("trafficAvailable", callBoolean(message, "getTrafficAvailable"))
                .put("uplinkBytes", callLong(message, "getUplink"))
                .put("downlinkBytes", callLong(message, "getDownlink"))
                .put("uplinkTotalBytes", callLong(message, "getUplinkTotal"))
                .put("downlinkTotalBytes", callLong(message, "getDownlinkTotal"))
                .put("sampledAt", System.currentTimeMillis()),
        )
    }

    private fun emitLogs(iterator: Any?) {
        if (iterator == null) return
        while (hasNext(iterator)) {
            val entry = next(iterator) ?: break
            emit(
                "runtime.log",
                JSONObject()
                    .put("level", callInt(entry, "getLevel"))
                    .put("message", redact(callString(entry, "getMessage")))
                    .put("at", System.currentTimeMillis()),
            )
        }
    }

    private fun emitConnections(eventsObject: Any?) {
        if (eventsObject == null) return
        val records = JSONArray()
        val iterator = call(eventsObject, "iterator")
        if (iterator != null) {
            while (hasNext(iterator)) {
                val event = next(iterator) ?: break
                val record = JSONObject()
                    .put("type", callInt(event, "getType"))
                    .put("id", callString(event, "getID"))
                    .put("uplinkDelta", callLong(event, "getUplinkDelta"))
                    .put("downlinkDelta", callLong(event, "getDownlinkDelta"))
                    .put("closedAt", callLong(event, "getClosedAt"))
                val connection = call(event, "getConnection")
                if (connection != null) {
                    record
                        .put("network", callString(connection, "getNetwork"))
                        .put("destination", callString(connection, "getDestination"))
                        .put("outbound", callString(connection, "getOutbound"))
                        .put("createdAt", callLong(connection, "getCreatedAt"))
                        .put("rule", callString(connection, "getRule"))
                    val chain = JSONArray()
                    val chainIterator = call(connection, "chain")
                    if (chainIterator != null) {
                        while (hasNext(chainIterator)) {
                            chain.put(next(chainIterator)?.toString() ?: "")
                        }
                    }
                    record.put("chain", chain)
                }
                records.put(record)
            }
        }
        emit(
            "runtime.connections",
            JSONObject()
                .put("reset", callBoolean(eventsObject, "getReset"))
                .put("instanceId", callString(eventsObject, "getInstanceId"))
                .put("events", records),
        )
    }

    private fun emit(type: String, payload: JSONObject) {
        synchronized(lock) {
            seq += 1
            payload.put("hostEpoch", hostEpoch)
            val envelope = JSONObject()
                .put("type", type)
                .put("seq", seq)
                .put("payload", payload)
            events.addLast(envelope.toString())
            while (events.size > MAX_EVENTS) {
                events.removeFirst()
            }
        }
    }

    private fun hasNext(iterator: Any): Boolean =
        runCatching { iterator.javaClass.getMethod("hasNext").invoke(iterator) as Boolean }.getOrDefault(false)

    private fun next(iterator: Any): Any? =
        runCatching { iterator.javaClass.getMethod("next").invoke(iterator) }.getOrNull()

    private fun call(target: Any, name: String): Any? =
        runCatching { target.javaClass.getMethod(name).invoke(target) }.getOrNull()

    private fun callString(target: Any, name: String): String =
        runCatching { target.javaClass.getMethod(name).invoke(target) as? String }.getOrNull() ?: ""

    private fun callLong(target: Any, name: String): Long =
        runCatching { (target.javaClass.getMethod(name).invoke(target) as Number).toLong() }.getOrDefault(0L)

    private fun callInt(target: Any, name: String): Int =
        runCatching { (target.javaClass.getMethod(name).invoke(target) as Number).toInt() }.getOrDefault(0)

    private fun callBoolean(target: Any, name: String): Boolean =
        runCatching { target.javaClass.getMethod(name).invoke(target) as Boolean }.getOrDefault(false)

    private fun stringBoxJson(box: Any?): JSONObject? {
        if (box == null) return null
        val value = runCatching {
            box.javaClass.getMethod("getValue").invoke(box) as? String
        }.getOrNull() ?: return null
        return runCatching { JSONObject(value) }.getOrNull()
    }

    private fun redact(message: String): String {
        var result = message
        for (key in listOf("password=", "token=", "uuid=")) {
            val regex = Regex("(?i)" + Regex.escape(key) + "([^ &;\\t\\n]+)")
            result = regex.replace(result) { key + "***" }
        }
        return result
    }
}
