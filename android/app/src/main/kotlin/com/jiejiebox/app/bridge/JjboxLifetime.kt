package com.jiejiebox.app.bridge

import org.json.JSONArray
import org.json.JSONObject

/**
 * Latest-intent reconciler, the Android mirror of package:jjbox_bridge's
 * HostServiceStateMachine.
 *
 * The service state is derived from (newest intent revision, runtime evidence).
 * A start ack is not evidence: only [runtimeReport] can produce RUNNING.
 */
class JjboxLifetime {
    enum class State { IDLE, AWAITING_PERMISSION, STARTING, RUNNING, STOPPING, FAILED, CLOSED }

    enum class Intent { START, STOP, RESTART, CLOSE }

    private data class Pending(val intent: Intent, val revision: Int, var needsPermission: Boolean)

    var state: State = State.IDLE
        private set
    var revision: Int = 0
        private set
    private var pending: Pending? = null
    private var runtimeRunning = false
    private var permissionGranted = false
    private var closed = false
    val results = mutableListOf<String>()
    val errors = mutableListOf<String>()

    fun start(revision: Int, needsPermission: Boolean): String {
        if (closed) return reject("closed")
        if (revision <= this.revision) return reject("stale_revision")
        this.revision = revision
        val hadPending = pending != null
        when (pending?.intent) {
            Intent.START -> results += "start@${pending!!.revision}:coalesced"
            null -> Unit
            else -> results += "${pending!!.intent.name.lowercase()}@${pending!!.revision}:superseded"
        }
        pending = null
        if (runtimeRunning && !hadPending) {
            results += "start@$revision:applied"
            permissionGranted = true
            return "applied"
        }
        pending = Pending(Intent.START, revision, needsPermission && !permissionGranted)
        state = derive()
        return "pending"
    }

    fun stop(revision: Int): String {
        if (closed) return reject("closed")
        if (revision <= this.revision) return reject("stale_revision")
        this.revision = revision
        when (pending?.intent) {
            Intent.STOP -> results += "stop@${pending!!.revision}:coalesced"
            null -> Unit
            else -> results += "${pending!!.intent.name.lowercase()}@${pending!!.revision}:superseded"
        }
        pending = Pending(Intent.STOP, revision, false)
        state = derive()
        return "pending"
    }

    fun close(revision: Int): String {
        if (closed) return reject("closed")
        if (revision <= this.revision) return reject("stale_revision")
        this.revision = revision
        pending = Pending(Intent.CLOSE, revision, false)
        state = derive()
        return "pending"
    }

    /** Runtime evidence; a report older than the newest intent is dropped. */
    fun runtimeReport(running: Boolean, reportRevision: Int = 0): String {
        if (reportRevision != 0 && reportRevision < revision) {
            errors += "stale_runtime_report"
            return "dropped"
        }
        runtimeRunning = running
        val current = pending
        if (current == null) {
            if (running) {
                state = State.RUNNING
                return "observed"
            }
            if (state == State.RUNNING) {
                fail("service.lost")
                return "observed"
            }
            state = derive()
            return "observed"
        }
        when (current.intent) {
            Intent.START, Intent.RESTART -> {
                if (running) {
                    results += "start@${current.revision}:applied"
                    pending = null
                    state = State.RUNNING
                    return "applied"
                }
                if (current.intent == Intent.RESTART) state = State.STARTING
                return "waiting"
            }
            Intent.STOP -> {
                if (!running) {
                    results += "stop@${current.revision}:applied"
                    pending = null
                    state = State.IDLE
                    return "applied"
                }
                return "waiting"
            }
            Intent.CLOSE -> {
                if (!running) {
                    results += "close@${current.revision}:applied"
                    pending = null
                    state = State.CLOSED
                    closed = true
                    return "applied"
                }
                return "waiting"
            }
        }
    }

    fun permissionReport(granted: Boolean): String {
        permissionGranted = granted
        val current = pending
        if (current != null && (current.intent == Intent.START || current.intent == Intent.RESTART)) {
            if (!granted) {
                fail("permission_denied")
                return "failed"
            }
            current.needsPermission = false
            state = derive()
            return "proceed"
        }
        return "ignored"
    }

    fun failPending(message: String): String {
        if (pending == null) return "ignored"
        fail(message)
        return "failed"
    }

    fun statusJson(): JSONObject = JSONObject()
        .put("state", state.name.lowercase())
        .put("revision", revision)

    private fun derive(): State {
        if (closed) return State.CLOSED
        pending?.let { current ->
            return when (current.intent) {
                Intent.START -> if (current.needsPermission) State.AWAITING_PERMISSION else State.STARTING
                Intent.RESTART -> State.STARTING
                Intent.STOP, Intent.CLOSE -> State.STOPPING
            }
        }
        if (runtimeRunning) return State.RUNNING
        if (state == State.FAILED) return State.FAILED
        return State.IDLE
    }

    private fun fail(message: String) {
        state = State.FAILED
        pending?.let { results += "${it.intent.name.lowercase()}@${it.revision}:applied" }
        pending = null
        errors += message
    }

    private fun reject(reason: String): String {
        errors += reason
        return "rejected:$reason"
    }

    fun resultsJson(): JSONArray = JSONArray(results)
}
