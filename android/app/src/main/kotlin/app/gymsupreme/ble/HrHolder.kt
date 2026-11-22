package app.gymsupreme.ble

import android.content.Context

/** One strap client per process: the link screen and the workout service share it. Main thread. */
object HrHolder {
    private var client: BleHrClient? = null

    fun get(context: Context): BleHrClient = client ?: BleHrClient(context.applicationContext).also { client = it }
}
