package loonybin.true_local_time

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

data class LatLng(val lat: Double, val lon: Double)

class GlobeGeometry(
    val boundaryLines: List<List<LatLng>>,
    val timezoneRings: List<List<LatLng>>,
) {
    companion object {
        @Volatile private var cached: GlobeGeometry? = null

        fun load(context: Context): GlobeGeometry =
            cached ?: synchronized(this) {
                cached ?: GlobeGeometry(
                    boundaryLines = loadLines(
                        context, "flutter_assets/assets/geo/boundaries_undisputed.geojson",
                    ),
                    timezoneRings = loadLines(
                        context, "flutter_assets/assets/geo/timezones_simplified.geojson",
                    ),
                ).also { cached = it }
            }

        private fun loadLines(context: Context, path: String): List<List<LatLng>> {
            val text = context.assets.open(path).bufferedReader().use { it.readText() }
            val out = mutableListOf<List<LatLng>>()
            collectLines(JSONObject(text), out)
            return out
        }

        private fun collectLines(geo: JSONObject, out: MutableList<List<LatLng>>) {
            when (geo.optString("type")) {
                "FeatureCollection" -> geo.getJSONArray("features").forEachObj { collectLines(it, out) }
                "Feature" -> collectLines(geo.getJSONObject("geometry"), out)
                "GeometryCollection" -> geo.getJSONArray("geometries").forEachObj { collectLines(it, out) }
                "LineString" -> out += parseCoords(geo.getJSONArray("coordinates"))
                "MultiLineString" -> geo.getJSONArray("coordinates").forEachArr { out += parseCoords(it) }
                "Polygon" -> geo.getJSONArray("coordinates").forEachArr { out += parseCoords(it) }
                "MultiPolygon" -> geo.getJSONArray("coordinates").forEachArr { poly ->
                    poly.forEachArr { out += parseCoords(it) }
                }
            }
        }

        private fun parseCoords(coords: JSONArray): List<LatLng> {
            val out = ArrayList<LatLng>(coords.length())
            for (i in 0 until coords.length()) {
                val c = coords.getJSONArray(i)
                out.add(LatLng(c.getDouble(1), c.getDouble(0)))
            }
            return out
        }
    }
}

private inline fun JSONArray.forEachObj(block: (JSONObject) -> Unit) {
    for (i in 0 until length()) block(getJSONObject(i))
}

private inline fun JSONArray.forEachArr(block: (JSONArray) -> Unit) {
    for (i in 0 until length()) block(getJSONArray(i))
}

private fun wrap180(degrees: Double): Double {
    var d = (degrees + 180) % 360
    if (d < 0) d += 360
    return d - 180
}

private data class Projected(val x: Float, val y: Float, val cosc: Double)

// Orthographic projection of the globe, ported from lib/main.dart#GlobePainter
// so the widget's bitmap matches what the app's CustomPaint draws.
fun renderGlobe(
    geometry: GlobeGeometry,
    centerLon: Double,
    userLat: Double?,
    userLon: Double?,
    sizePx: Int,
): Bitmap {
    val bmp = Bitmap.createBitmap(sizePx, sizePx, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bmp)
    val cx = sizePx / 2f
    val cy = sizePx / 2f
    val r = (sizePx / 2f) - 2f

    fun project(lat: Double, lon: Double): Projected {
        val dLon = wrap180(lon - centerLon) * PI / 180.0
        val latRad = lat * PI / 180.0
        val cosLat = cos(latRad)
        return Projected(
            x = (cx + r * cosLat * sin(dLon)).toFloat(),
            y = (cy - r * sin(latRad)).toFloat(),
            cosc = cosLat * cos(dLon),
        )
    }

    fun horizon(a: Projected, b: Projected): Pair<Float, Float> {
        val t = (a.cosc / (a.cosc - b.cosc)).toFloat()
        var x = a.x + (b.x - a.x) * t
        var y = a.y + (b.y - a.y) * t
        val dx = x - cx
        val dy = y - cy
        val d = sqrt(dx * dx + dy * dy)
        if (d > 0) {
            x = cx + dx / d * r
            y = cy + dy / d * r
        }
        return x to y
    }

    fun addRing(path: Path, ring: List<LatLng>) {
        var prev: Projected? = null
        for (pt in ring) {
            val cur = project(pt.lat, pt.lon)
            val curVis = cur.cosc > 0
            val prevVal = prev
            if (prevVal == null) {
                if (curVis) path.moveTo(cur.x, cur.y)
            } else {
                val prevVis = prevVal.cosc > 0
                when {
                    prevVis && curVis -> path.lineTo(cur.x, cur.y)
                    prevVis && !curVis -> {
                        val (hx, hy) = horizon(prevVal, cur)
                        path.lineTo(hx, hy)
                    }
                    !prevVis && curVis -> {
                        val (hx, hy) = horizon(prevVal, cur)
                        path.moveTo(hx, hy)
                        path.lineTo(cur.x, cur.y)
                    }
                }
            }
            prev = cur
        }
    }

    fun buildPath(rings: List<List<LatLng>>): Path {
        val p = Path()
        for (ring in rings) addRing(p, ring)
        return p
    }

    canvas.drawCircle(cx, cy, r, Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xFF0A1B2E.toInt()
    })

    canvas.save()
    canvas.clipPath(Path().apply { addCircle(cx, cy, r, Path.Direction.CW) })

    canvas.drawPath(
        buildPath(geometry.boundaryLines),
        Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = 0.6f
            color = 0x3DFFFFFF.toInt()
        },
    )
    canvas.drawPath(
        buildPath(geometry.timezoneRings),
        Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = 1.3f
            color = 0xFF7FB3D5.toInt()
        },
    )

    // Faint meridian for the longitude facing the viewer; in orthographic this
    // is exactly the vertical diameter.
    canvas.drawLine(cx, cy - r, cx, cy + r, Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 1.0f
        color = 0x1FFFFFFF.toInt()
    })

    if (userLat != null && userLon != null) {
        val meridian = mutableListOf<LatLng>()
        var lat = -90.0
        while (lat <= 90.0) {
            meridian += LatLng(lat, userLon)
            lat += 2.0
        }
        val meridianPath = Path()
        addRing(meridianPath, meridian)
        canvas.drawPath(meridianPath, Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = 1.6f
            color = 0xFF40C4FF.toInt()
        })

        val marker = project(userLat, userLon)
        if (marker.cosc > 0) {
            canvas.drawCircle(marker.x, marker.y, 9f, Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.STROKE
                strokeWidth = 2f
                color = 0xFF40C4FF.toInt()
            })
            canvas.drawCircle(marker.x, marker.y, 3.5f, Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = 0xFF40C4FF.toInt()
            })
        }
    }

    canvas.restore()

    canvas.drawCircle(cx, cy, r, Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 1.5f
        color = Color.WHITE
    })

    return bmp
}
