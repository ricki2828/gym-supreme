package app.gymsupreme.core.ble

/** One heart-rate reading: [t] is elapsedRealtime in ms at receipt, [bpm] never 0. */
data class HrReading(val t: Long, val bpm: Int)
