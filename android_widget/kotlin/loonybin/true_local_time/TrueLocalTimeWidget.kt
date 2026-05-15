package loonybin.true_local_time

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.location.Location
import android.location.LocationManager
import android.widget.RemoteViews
import kotlin.math.abs
import kotlin.math.roundToInt

class TrueLocalTimeWidget : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        val longitude = lastKnownLongitude(context)
        val tzId = solarTimeZoneId(longitude)
        val views = RemoteViews(context.packageName, R.layout.true_local_time_widget).apply {
            setString(R.id.tlt_widget_date, "setTimeZone", tzId)
            setString(R.id.tlt_widget_time, "setTimeZone", tzId)
            setTextViewText(R.id.tlt_widget_longitude, longitudeLabel(longitude))
            launchAppOnTap(context, this)
        }
        appWidgetIds.forEach { appWidgetManager.updateAppWidget(it, views) }
    }

    private fun launchAppOnTap(context: Context, views: RemoteViews) {
        val intent = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?: return
        val pi = PendingIntent.getActivity(
            context,
            0,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        views.setOnClickPendingIntent(R.id.tlt_widget_root, pi)
    }

    @SuppressLint("MissingPermission")
    private fun lastKnownLongitude(context: Context): Double? {
        val lm = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
            ?: return null
        var best: Location? = null
        for (provider in listOf(
            LocationManager.PASSIVE_PROVIDER,
            LocationManager.NETWORK_PROVIDER,
            LocationManager.GPS_PROVIDER,
        )) {
            val candidate = try {
                lm.getLastKnownLocation(provider)
            } catch (_: SecurityException) {
                null
            }
            if (candidate != null && (best == null || candidate.time > best.time)) {
                best = candidate
            }
        }
        return best?.longitude
    }
}

// Solar time = UTC + 4 minutes per degree east. Java treats "GMT±HH:MM" as a
// fixed-offset zone, which is exactly what TextClock needs in order to render
// the longitude-shifted clock without any per-tick wakeups from us.
private fun solarTimeZoneId(longitude: Double?): String {
    val totalMinutes = ((longitude ?: 0.0) * 4.0).roundToInt()
    val sign = if (totalMinutes >= 0) "+" else "-"
    val mag = abs(totalMinutes)
    return "GMT%s%02d:%02d".format(sign, mag / 60, mag % 60)
}

private fun longitudeLabel(longitude: Double?): String {
    if (longitude == null) return "Longitude unknown"
    return "%.2f° %s".format(abs(longitude), if (longitude >= 0) "E" else "W")
}
