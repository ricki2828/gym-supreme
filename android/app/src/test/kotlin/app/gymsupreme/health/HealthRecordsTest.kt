package app.gymsupreme.health

import androidx.health.connect.client.records.ExerciseSessionRecord
import app.gymsupreme.platform.HealthExerciseKind
import app.gymsupreme.platform.HealthSession
import java.time.Instant
import java.time.ZoneOffset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** 0.3 H1: a finished workout as one Health Connect strength-training session. */
class HealthRecordsTest {
    private val t0 = 1_795_000_000_000L
    private val uuid = "0f8fad5b-d9cb-469f-a165-70867728950e"

    private fun session(
        start: Long = t0,
        end: Long = t0 + 3_600_000,
        offsetS: Long = 13 * 3600,
        version: Long = 0,
        title: String = "Push",
        kind: HealthExerciseKind = HealthExerciseKind.STRENGTH,
    ) = HealthSession(uuid, version, title, start, end, offsetS, kind)

    @Test
    fun `conditioning (Engine) is HIIT, never strength training`() {
        val r = HealthRecords.toRecord(session(title = "Engine", kind = HealthExerciseKind.CONDITIONING))
        assertEquals(ExerciseSessionRecord.EXERCISE_TYPE_HIGH_INTENSITY_INTERVAL_TRAINING, r.exerciseType)
        assertTrue(r.exerciseType != ExerciseSessionRecord.EXERCISE_TYPE_STRENGTH_TRAINING)
        assertEquals("Engine", r.title)
    }

    @Test
    fun `strength session with the workout's own times, offset and title`() {
        val r = HealthRecords.toRecord(session())
        assertEquals(ExerciseSessionRecord.EXERCISE_TYPE_STRENGTH_TRAINING, r.exerciseType)
        assertEquals(Instant.ofEpochMilli(t0), r.startTime)
        assertEquals(Instant.ofEpochMilli(t0 + 3_600_000), r.endTime)
        assertEquals(ZoneOffset.ofHours(13), r.startZoneOffset)
        assertEquals(ZoneOffset.ofHours(13), r.endZoneOffset)
        assertEquals("Push", r.title)
        assertTrue(r.segments.isEmpty())
        assertTrue(r.laps.isEmpty())
    }

    @Test
    fun `clientRecordId is the workout uuid, version is edited_at`() {
        val first = HealthRecords.toRecord(session(version = 0))
        assertEquals(uuid, first.metadata.clientRecordId)
        assertEquals(0L, first.metadata.clientRecordVersion)
        val edited = HealthRecords.toRecord(session(version = t0 + 86_400_000))
        assertEquals(uuid, edited.metadata.clientRecordId)
        assertEquals(t0 + 86_400_000, edited.metadata.clientRecordVersion)
        assertTrue(edited.metadata.clientRecordVersion > first.metadata.clientRecordVersion)
        assertEquals(0L, HealthRecords.toRecord(session(version = -5)).metadata.clientRecordVersion)
    }

    @Test
    fun `negative, half-hour and out-of-range offsets`() {
        assertEquals(ZoneOffset.ofHours(-5), HealthRecords.toRecord(session(offsetS = -5 * 3600)).startZoneOffset)
        assertEquals(ZoneOffset.ofHoursMinutes(5, 30), HealthRecords.toRecord(session(offsetS = 5 * 3600 + 1800)).startZoneOffset)
        assertEquals(ZoneOffset.ofHoursMinutes(13, 45), HealthRecords.toRecord(session(offsetS = 13 * 3600 + 2700)).endZoneOffset)
        assertEquals(ZoneOffset.ofHours(18), HealthRecords.toRecord(session(offsetS = 30 * 3600)).startZoneOffset)
        assertEquals(ZoneOffset.ofHours(-18), HealthRecords.toRecord(session(offsetS = -30 * 3600)).startZoneOffset)
    }

    @Test
    fun `paused time stays inside the session, a zero-length one gets 1 s`() {
        // The store keeps only the paused total, not when: the session spans start to end as
        // logged and carries no pause segments (a made-up pause time would be wrong).
        val withPause = HealthRecords.toRecord(session(start = t0, end = t0 + 5_400_000))
        assertEquals(Instant.ofEpochMilli(t0 + 5_400_000), withPause.endTime)
        assertTrue(withPause.segments.isEmpty())
        val zero = HealthRecords.toRecord(session(start = t0, end = t0))
        assertEquals(Instant.ofEpochMilli(t0 + 1000), zero.endTime)
        val backwards = HealthRecords.toRecord(session(start = t0, end = t0 - 60_000))
        assertTrue(backwards.endTime.isAfter(backwards.startTime))
    }

    @Test
    fun `blank title falls back`() {
        assertEquals(HealthRecords.DEFAULT_TITLE, HealthRecords.toRecord(session(title = "  ")).title)
    }
}
