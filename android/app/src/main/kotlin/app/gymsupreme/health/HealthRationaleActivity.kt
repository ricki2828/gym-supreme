package app.gymsupreme.health

import android.app.Activity
import android.os.Bundle
import android.widget.ScrollView
import android.widget.TextView

/**
 * The privacy screen Health Connect opens from its permission page (0.3 H1): Android 13 and older
 * start it by `ACTION_SHOW_PERMISSIONS_RATIONALE`, Android 14+ by the `ViewPermissionUsageActivity`
 * alias. Gym Supreme has no INTERNET permission and no policy page, so it says it here.
 */
class HealthRationaleActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setTitle("Gym Supreme and Health Connect")
        val pad = (20 * resources.displayMetrics.density).toInt()
        val text = TextView(this).apply {
            setPadding(pad, pad, pad, pad)
            textSize = 16f
            text = TEXT
        }
        setContentView(ScrollView(this).apply { addView(text) })
    }

    companion object {
        const val TEXT =
            "Gym Supreme writes each finished workout to Health Connect as one strength-training " +
                "session: its type as the title, its start and end time, and nothing else. No sets, " +
                "weights or heart rate.\n\n" +
                "It reads nothing from Health Connect. When you delete a workout in Gym Supreme, its " +
                "session is deleted from Health Connect too; an edit rewrites it.\n\n" +
                "It only writes while the Health Connect switch in Diagnostics is on. Gym Supreme has " +
                "no internet permission: nothing leaves your phone."
    }
}
