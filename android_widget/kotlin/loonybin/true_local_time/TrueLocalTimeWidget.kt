package loonybin.true_local_time

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.location.Location
import android.location.LocationManager
import android.os.Bundle
import android.util.Log
import android.widget.RemoteViews
import kotlin.math.abs
import kotlin.math.roundToInt

class TrueLocalTimeWidget : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        renderAsync {
            appWidgetIds.forEach { render(context, appWidgetManager, it) }
        }
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle,
    ) {
        renderAsync {
            render(context, appWidgetManager, appWidgetId)
        }
    }

    // BroadcastReceiver.onReceive callbacks have ~10s before they're killed,
    // and AppWidgetProvider.onUpdate runs on the main thread. goAsync() keeps
    // the receiver alive while we read GeoJSON and rasterise off-main.
    private fun renderAsync(work: () -> Unit) {
        val pending = goAsync()
        Thread {
            try {
                work()
            } catch (t: Throwable) {
                Log.e(TAG, "widget update failed", t)
            } finally {
                pending.finish()
            }
        }.start()
    }

    private fun render(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
    ) {
        val fix = lastKnownFix(context)
        val tzId = solarTimeZoneId(fix?.longitude)

        val opts = appWidgetManager.getAppWidgetOptions(appWidgetId)
        val widthDp = opts.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 0)
        val heightDp = opts.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, 0)
        val landscape = widthDp > 0 && heightDp > 0 && widthDp > heightDp * 1.4

        val layoutRes = if (landscape) R.layout.true_local_time_widget_wide
        else R.layout.true_local_time_widget

        val views = RemoteViews(context.packageName, layoutRes).apply {
            setString(R.id.tlt_widget_date, "setTimeZone", tzId)
            setString(R.id.tlt_widget_time, "setTimeZone", tzId)
            setTextViewText(R.id.tlt_widget_longitude, longitudeLabel(fix?.longitude))
            attachGlobe(context, this, fix, landscape, widthDp, heightDp)
            launchAppOnTap(context, this)
        }
        appWidgetManager.updateAppWidget(appWidgetId, views)
    }

    private fun attachGlobe(
        context: Context,
        views: RemoteViews,
        fix: Fix?,
        landscape: Boolean,
        widthDp: Int,
        heightDp: Int,
    ) {
        val geometry = try {
            GlobeGeometry.load(context)
        } catch (t: Throwable) {
            Log.w(TAG, "globe assets unavailable", t)
            return
        }
        val density = context.resources.displayMetrics.density
        // The globe slot is roughly the widget's short side (height for the
        // landscape layout, width for the portrait layout). Cap the bitmap so
        // the RemoteViews payload stays well under the 1.5 MB IPC limit.
        val sideDp = if (landscape) heightDp else widthDp
        val sidePx = ((if (sideDp > 0) sideDp else 140) * density)
            .toInt().coerceIn(96, 360)
        val bmp = renderGlobe(
            geometry = geometry,
            centerLon = fix?.longitude ?: 0.0,
            userLat = fix?.latitude,
            userLon = fix?.longitude,
            sizePx = sidePx,
        )
        views.setImageViewBitmap(R.id.tlt_widget_globe, bmp)
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
    private fun lastKnownFix(context: Context): Fix? {
        // The app pushes fresh fixes here via a method channel. Prefer that
        // over LocationManager since Geolocator/FusedLocationProvider keeps a
        // private cache the widget can't otherwise reach.
        WidgetBridge.loadFix(context)?.let { (lat, lon) -> return Fix(lat, lon) }

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
        return best?.let { Fix(it.latitude, it.longitude) }
    }

    companion object {
        private const val TAG = "TrueLocalTimeWidget"
    }
}

private data class Fix(val latitude: Double, val longitude: Double)

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
    if (longitude == null) return "Tap to open app"
    return "%.2f° %s".format(abs(longitude), if (longitude >= 0) "E" else "W")
}
