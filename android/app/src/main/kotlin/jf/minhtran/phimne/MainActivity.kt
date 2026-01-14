package jf.minhtran.phimne

import android.app.ActivityManager
import android.app.admin.DevicePolicyManager
import android.content.Context
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.ryanheise.audioservice.AudioServiceFragmentActivity

class MainActivity : AudioServiceFragmentActivity() {
    private val channelName = "phimne/lockdown"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startLockTaskMode" -> {
                        val started = startLockTaskSafe()
                        result.success(started)
                    }
                    "stopLockTaskMode" -> {
                        stopLockTask()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun startLockTaskSafe(): Boolean {
        // On Android 5.0+ apps can call startLockTask, but fully preventing
        // exit requires device owner / lock task packages configured by the OS.
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                startLockTask()
                true
            } else {
                false
            }
        } catch (e: IllegalArgumentException) {
            // Thrown if the app is not allowed to enter lock task mode.
            false
        } catch (e: IllegalStateException) {
            false
        }
    }
}
