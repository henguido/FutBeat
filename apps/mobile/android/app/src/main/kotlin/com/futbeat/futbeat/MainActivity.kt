package com.futbeat.futbeat

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Called from Dart only when push is configured for this build
        // (lib/core/push_messages.dart, ensureAndroidNotificationChannel).
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

    companion object {
        private const val CHANNEL = "futbeat/notifications"
    }
}
