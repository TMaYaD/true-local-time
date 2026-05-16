package loonybin.true_local_time

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent

const val WIDGET_CHANNEL = "loonybin.true_local_time/widget"

// Shared SharedPreferences-backed cache for the last GPS fix the Flutter app
// has seen. The widget can't reach Geolocator's FusedLocationProvider cache
// (it's private to Google Play Services), so the app pushes fixes here and
// the widget reads from here.
object WidgetBridge {
    private const val PREFS = "true_local_time_widget"
    private const val LAT_BITS = "latitude_bits"
    private const val LON_BITS = "longitude_bits"

    fun saveFix(context: Context, latitude: Double, longitude: Double) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putLong(LAT_BITS, java.lang.Double.doubleToRawLongBits(latitude))
            .putLong(LON_BITS, java.lang.Double.doubleToRawLongBits(longitude))
            .apply()
    }

    fun loadFix(context: Context): Pair<Double, Double>? {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (!prefs.contains(LAT_BITS) || !prefs.contains(LON_BITS)) return null
        return java.lang.Double.longBitsToDouble(prefs.getLong(LAT_BITS, 0)) to
            java.lang.Double.longBitsToDouble(prefs.getLong(LON_BITS, 0))
    }

    fun refreshWidgets(context: Context) {
        val mgr = AppWidgetManager.getInstance(context)
        val ids = mgr.getAppWidgetIds(
            ComponentName(context, TrueLocalTimeWidget::class.java),
        )
        if (ids.isEmpty()) return
        val intent = Intent(context, TrueLocalTimeWidget::class.java).apply {
            action = AppWidgetManager.ACTION_APPWIDGET_UPDATE
            putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
        }
        context.sendBroadcast(intent)
    }
}
