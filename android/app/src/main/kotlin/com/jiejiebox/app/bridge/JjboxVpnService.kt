package com.jiejiebox.app.bridge

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor

/**
 * The minimal VPN shell: foreground service first, then the TUN descriptor, then
 * the core. The descriptor hand-off to libbox is the only part that needs the AAR.
 *
 * Addresses follow mihomo's TUN defaults, which no LAN uses:
 * 198.18.0.1/30 and 198.18.0.2 for DNS (the fake-ip pool starts above this /30).
 */
class JjboxVpnService : VpnService() {
    private var established = false

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // startForeground must precede any other work or Android 12+ throws.
        startForeground(NOTIFICATION_ID, buildNotification())
        when (intent?.action) {
            ACTION_STOP -> {
                stopTun()
                stopSelf()
            }
            else -> startTun(
                intent?.getStringExtra(EXTRA_MODE) ?: "vpn",
                intent?.getIntExtra(EXTRA_MTU, 0) ?: 0,
                intent?.getStringExtra(EXTRA_CONFIG) ?: "",
            )
        }
        return START_NOT_STICKY
    }

    override fun onRevoke() {
        stopTun()
        JjboxCore.vpnPermissionGranted = false
        stopSelf()
    }

    override fun onDestroy() {
        stopTun()
        super.onDestroy()
    }

    private fun startTun(mode: String, mtu: Int, config: String) {
        if (mode != "vpn") {
            // Proxy-only mode: no TUN, the mixed listener is enough.
            return
        }
        if (config.isBlank()) {
            JjboxCore.reportFailure("VPN config is empty")
            JjboxCore.vpnPermissionGranted = false
            stopSelf()
            return
        }
        if (prepare(this) != null) {
            JjboxCore.reportFailure("VPN permission was not granted")
            JjboxCore.vpnPermissionGranted = false
            stopSelf()
            return
        }
        val fd = try {
            Builder()
                .setSession("JiejieBox")
                .setBlocking(false)
                .addAddress("198.18.0.1", 30)
                .addDnsServer("198.18.0.2")
                .addRoute("0.0.0.0", 0)
                .apply { if (mtu > 0) setMtu(mtu) }
                .establish()
                ?.detachFd()
        } catch (error: Exception) {
            null
        }
        // A rejected descriptor must tear the VPN down rather than report a start
        // that only looks successful.
        if (fd == null) {
            JjboxCore.reportFailure("VPN descriptor could not be established")
            JjboxCore.vpnPermissionGranted = false
            stopTun()
            stopSelf()
            return
        }
        JjboxCore.vpnPermissionGranted = true
        JjboxCore.attachTun(fd)
        try {
            JjboxCore.startService(config)
            established = true
        } catch (error: Exception) {
            JjboxCore.clearTun()
            JjboxCore.vpnPermissionGranted = false
            JjboxCore.reportFailure(error.message ?: "VPN core start failed")
            runCatching { ParcelFileDescriptor.adoptFd(fd).close() }
            stopTun()
            stopSelf()
        }
    }

    private fun stopTun() {
        if (established) {
            runCatching { JjboxCore.stopService() }
            JjboxCore.clearTun()
            established = false
        }
    }

    private fun buildNotification(): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, "JiejieBox", NotificationManager.IMPORTANCE_LOW),
            )
        }
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            packageManager.getLaunchIntentForPackage(packageName)
                ?: Intent(Intent.ACTION_MAIN).setPackage(packageName),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("JiejieBox")
            .setContentText("Running")
            .setSmallIcon(android.R.drawable.stat_sys_warning)
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .build()
    }

    companion object {
        const val ACTION_START = "com.jiejiebox.app.bridge.START"
        const val ACTION_STOP = "com.jiejiebox.app.bridge.STOP"
        const val EXTRA_MODE = "mode"
        const val EXTRA_MTU = "mtu"
        const val EXTRA_CONFIG = "config"
        private const val CHANNEL = "jjbox-service"
        private const val NOTIFICATION_ID = 1

        fun intent(context: Context, action: String): Intent =
            Intent(context, JjboxVpnService::class.java).setAction(action)
    }
}
