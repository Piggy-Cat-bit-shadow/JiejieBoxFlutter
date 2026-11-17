package com.jiejiebox.app.bridge

import org.json.JSONArray
import org.json.JSONObject

/**
 * The single place that talks to libbox.
 *
 * P1 links no AAR yet, so [isLoaded] is false and every core method answers
 * `core_unavailable` instead of pretending. When the pinned `libbox.aar` is added
 * to `android/app/libs`, only this object changes:
 *
 *  - setup(args)            -> Libbox.setup(SetupOptions)
 *  - checkConfig(content)   -> Libbox.checkConfig(content)
 *  - formatConfig(content)  -> Libbox.formatConfig(content)
 *  - preview(content)       -> Libbox.parsePreview(content)   (feature/flutter-api)
 *  - refreshProviders(tags) -> CommandClient.refreshRemoteProviders(tags, timeout)
 *  - openTun(fd, options)   -> Libbox.openTun / the CommandServer's PlatformInterface
 */
object JjboxCore {
    var isLoaded: Boolean = false
    var vpnPermissionGranted: Boolean = false
    var hasCameraScanner: Boolean = false

    private var basePath: String = ""
    private var appVersion: String = ""

    fun setup(args: JSONObject) {
        basePath = args.optString("basePath")
        appVersion = args.optString("appVersion")
    }

    fun capabilities(): JSONObject = JSONObject()
        .put("apiVersion", 4)
        .put("buildId", if (isLoaded) "pending" else JSONObject.NULL)
        .put("buildQuic", false)
        .put("platform", "android")
        .put("version", appVersion)
        .put("goVersion", JSONObject.NULL)
        .put("capabilities", JSONArray())

    fun checkConfig(content: String): JSONObject {
        throw UnsupportedOperationException("libbox is not linked")
    }

    fun formatConfig(content: String): JSONObject {
        throw UnsupportedOperationException("libbox is not linked")
    }

    fun preview(content: String): JSONObject {
        throw UnsupportedOperationException("libbox is not linked")
    }

    fun refreshProviders(tags: String): JSONObject {
        throw UnsupportedOperationException("libbox is not linked")
    }

    fun openTun(fd: Int): Boolean = false

    fun closeTun() = Unit
}
