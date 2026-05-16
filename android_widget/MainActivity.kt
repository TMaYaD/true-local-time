package loonybin.true_local_time

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            WIDGET_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "saveFix" -> {
                    val lat = call.argument<Double>("latitude")
                    val lon = call.argument<Double>("longitude")
                    if (lat == null || lon == null) {
                        result.error("BAD_ARGS", "lat/lon required", null)
                    } else {
                        WidgetBridge.saveFix(this, lat, lon)
                        WidgetBridge.refreshWidgets(this)
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
