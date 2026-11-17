package com.jiejiebox.app.bridge

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import org.json.JSONObject

/**
 * The Android end of `jjbox/host`.
 *
 * Registration happens in onAttachedToEngine; the channel handler only parses the
 * envelope and hands the work to [JjboxHost], which owns the core and the service.
 * Events go out on `jjbox/host/callback` as `{type, seq, data}` frames. The seq and
 * the envelope are the contract's, not Android's: no channel string decides a Go
 * API meaning.
 */
class JjboxPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var messenger: BinaryMessenger
    private lateinit var channel: MethodChannel
    private lateinit var callbackChannel: MethodChannel
    private lateinit var host: JjboxHost

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        messenger = binding.binaryMessenger
        // Serial background queue: a start and the status poll that follows it must
        // reach the host in the order Dart sent them.
        channel = MethodChannel(
            messenger,
            COMMANDS,
            StandardMethodCodec.INSTANCE,
            messenger.makeBackgroundTaskQueue(),
        )
        callbackChannel = MethodChannel(messenger, CALLBACKS)
        host = JjboxHost(binding.applicationContext, ::emit)
        // Rebind idempotently: a second attach on the same engine must replace
        // the handler, not stack a second one (P4 double-registration audit).
        channel.setMethodCallHandler(null)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        // The service keeps running after the engine detaches (always-on VPN,
        // notification stop); only the event sink goes away.
        host.detach()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            INVOKE -> dispatch(call, result)
            else -> result.notImplemented()
        }
    }

    private fun dispatch(call: MethodCall, result: MethodChannel.Result) {
        val raw = call.arguments as? String
        if (raw == null) {
            result.error("bad_args", "jjbox.invoke expects a JSON string", null)
            return
        }
        val request = runCatching { JSONObject(raw) }.getOrElse {
            result.error("bad_args", "malformed request: ${it.message}", null)
            return
        }
        val id = request.optString("id")
        val method = request.optString("method")
        val args = request.optJSONObject("args") ?: JSONObject()
        host.handle(method, args) { response ->
            response.put("id", id)
            result.success(response.toString())
        }
    }

    private fun emit(frame: JSONObject) {
        // StandardMethodCodec frames are what a MethodChannel handler receives; the
        // host sends them itself so an engine that detached never sees a frame.
        val message = StandardMethodCodec.INSTANCE.encodeMethodCall(
            MethodCall("event", frame.toString()),
        )
        messenger.send(CALLBACKS, message)
    }

    companion object {
        const val COMMANDS = "jjbox/host"
        const val CALLBACKS = "jjbox/host/callback"
        const val INVOKE = "jjbox.invoke"
    }
}
