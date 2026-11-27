package com.futbeat.futbeat

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.BroadcastReceiver
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.telephony.TelephonyManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.TimeZone

class MainActivity : FlutterActivity() {
    private var deviceChannel: MethodChannel? = null
    private var clockReceiver: BroadcastReceiver? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Called from Dart only when push is configured for this build
        // (lib/core/push_messages.dart, ensureAndroidNotificationChannel).
        // Country of the SIM (else the network): a region hint that needs
        // no permission and no location (lib/core/interests.dart).
        deviceChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE_CHANNEL)
        deviceChannel!!.setMethodCallHandler { call, result ->
                if (call.method == "timeZone") {
                    result.success(TimeZone.getDefault().id)
                    return@setMethodCallHandler
                }
                if (call.method != "simCountry") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val telephony = getSystemService(Context.TELEPHONY_SERVICE)
                    as? TelephonyManager
                val country = telephony?.simCountryIso?.takeIf { it.isNotBlank() }
                    ?: telephony?.networkCountryIso?.takeIf { it.isNotBlank() }
                result.success(country)
            }
        clockReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                deviceChannel?.invokeMethod("clockChanged", null)
            }
        }
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_TIMEZONE_CHANGED)
            addAction(Intent.ACTION_TIME_CHANGED)
            addAction(Intent.ACTION_DATE_CHANGED)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(clockReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(clockReceiver, filter)
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "createNotificationChannel") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val id = call.argument<String>("id")
                val name = call.argument<String>("name")
                if (id.isNullOrEmpty() || name.isNullOrEmpty()) {
                    result.error("invalid", "id and name are required", null)
                    return@setMethodCallHandler
                }
                // Channels exist from Android 8 (API 26); older versions
                // ignore them.
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    val channel = NotificationChannel(
                        id,
                        name,
                        NotificationManager.IMPORTANCE_HIGH,
                    )
                    channel.description = call.argument<String>("description")
                    val manager = getSystemService(Context.NOTIFICATION_SERVICE)
                        as NotificationManager
                    // Idempotent: re-creating an existing channel only updates
                    // its name and description.
                    manager.createNotificationChannel(channel)
                    result.success(true)
                } else {
                    result.success(false)
                }
            }
    }

    override fun onDestroy() {
        clockReceiver?.let { unregisterReceiver(it) }
        clockReceiver = null
        deviceChannel?.setMethodCallHandler(null)
        deviceChannel = null
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "futbeat/notifications"
        private const val DEVICE_CHANNEL = "futbeat/device"
    }
}
