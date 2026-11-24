package app.gymsupreme.health

import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.records.metadata.Device
import androidx.health.connect.client.records.metadata.Metadata
import app.gymsupreme.platform.HealthExerciseKind
import app.gymsupreme.platform.HealthSession
import java.time.Instant
import java.time.ZoneOffset

/**
 * A finished workout ([HealthSession], built by Dart from the stored record) as one Health Connect
 * exercise session (0.3 H1): strength training, or HIIT for the Engine (conditioning) type, which
 * must not count toward Body Age's strength factor. No sets, no heart rate, no pause segments in v1: the store
 * keeps only the paused total, not the pause times, so the session spans start to end as logged.
 * `clientRecordId` is the workout uuid and `clientRecordVersion` is `edited_at_ms ?? 0`, so a
 * rewrite after an edit replaces the record and a repeat of the same version is ignored.
 */
object HealthRecords {
    /** Health Connect refuses offsets outside ±18 h. */
    private const val MAX_OFFSET_S = 18 * 3600

    /** A session must end after it starts; a zero-length one is stretched to 1 s. */
    private const val MIN_LENGTH_MS = 1000L

    const val DEFAULT_TITLE = "Strength training"

    fun exerciseType(kind: HealthExerciseKind): Int = when (kind) {
        HealthExerciseKind.STRENGTH -> ExerciseSessionRecord.EXERCISE_TYPE_STRENGTH_TRAINING
        HealthExerciseKind.CONDITIONING -> ExerciseSessionRecord.EXERCISE_TYPE_HIGH_INTENSITY_INTERVAL_TRAINING
    }

    fun offset(utcOffsetSeconds: Long): ZoneOffset =
        ZoneOffset.ofTotalSeconds(utcOffsetSeconds.coerceIn(-MAX_OFFSET_S.toLong(), MAX_OFFSET_S.toLong()).toInt())

    fun toRecord(s: HealthSession): ExerciseSessionRecord {
        val zone = offset(s.utcOffsetSeconds)
        val start = Instant.ofEpochMilli(s.startEpochMs)
        val end = Instant.ofEpochMilli(maxOf(s.endEpochMs, s.startEpochMs + MIN_LENGTH_MS))
        return ExerciseSessionRecord(
            startTime = start,
            startZoneOffset = zone,
            endTime = end,
            endZoneOffset = zone,
            metadata = Metadata.activelyRecorded(Device(type = Device.TYPE_PHONE), s.clientRecordId, s.version.coerceAtLeast(0)),
            exerciseType = exerciseType(s.kind),
            title = s.title.trim().ifEmpty { DEFAULT_TITLE },
            notes = null,
            segments = emptyList(),
            laps = emptyList(),
            exerciseRoute = null,
        )
    }
}
