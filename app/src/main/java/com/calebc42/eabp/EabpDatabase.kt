package com.calebc42.eabp

import android.content.Context
import androidx.room.Dao
import androidx.room.Database
import androidx.room.Delete
import androidx.room.Entity
import androidx.room.Insert
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.Transaction
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase

/**
 * One queued event, stored shape-preserving: `kind` + the full `payload`
 * JSON exactly as it would have been sent live. Replay therefore can't
 * mutate an event's shape (the v1 bug where a queued state.changed came
 * back disguised as an event.action).
 *
 * The legacy v1 columns remain so a v1 row can still be replayed after
 * migration; new inserts leave them at their defaults.
 */
@Entity(tableName = "queued_events")
data class QueuedEvent(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val kind: String = "event.action",
    val payload: String = "",
    /** Later events with the same key replace earlier ones (spec dedupe). */
    val dedupeKey: String? = null,
    /** Seconds after which the event expires unreplayed (spec per-event TTL). */
    val ttlS: Long? = null,
    // ── legacy v1 columns ──
    val surface: String = "",
    val revisionSeen: Int = 0,
    val action: String = "",
    val args: String = "{}",
    val queuedAt: Long = System.currentTimeMillis(),
)

@Dao
interface EventDao {
    @Insert
    fun insertRaw(event: QueuedEvent): Long

    @Query("DELETE FROM queued_events WHERE dedupeKey = :key")
    fun deleteByDedupe(key: String)

    /**
     * Dedupe-aware insert: a checkbox toggled five times while offline
     * delivers once, with the final state.
     */
    @Transaction
    fun insert(event: QueuedEvent): Long {
        event.dedupeKey?.let { deleteByDedupe(it) }
        return insertRaw(event)
    }

    @Query("SELECT * FROM queued_events ORDER BY queuedAt ASC")
    fun getAllChronological(): List<QueuedEvent>

    @Delete
    fun delete(event: QueuedEvent)

    @Query("SELECT COUNT(*) FROM queued_events")
    fun count(): Int
}

@Database(entities = [QueuedEvent::class], version = 2, exportSchema = false)
abstract class EabpDatabase : RoomDatabase() {
    abstract fun eventDao(): EventDao

    companion object {
        @Volatile
        private var INSTANCE: EabpDatabase? = null

        private val MIGRATION_1_2 = object : Migration(1, 2) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE queued_events ADD COLUMN kind TEXT NOT NULL DEFAULT 'event.action'")
                db.execSQL("ALTER TABLE queued_events ADD COLUMN payload TEXT NOT NULL DEFAULT ''")
                db.execSQL("ALTER TABLE queued_events ADD COLUMN dedupeKey TEXT")
                db.execSQL("ALTER TABLE queued_events ADD COLUMN ttlS INTEGER")
            }
        }

        fun getDatabase(context: Context): EabpDatabase {
            return INSTANCE ?: synchronized(this) {
                val instance = Room.databaseBuilder(
                    context.applicationContext,
                    EabpDatabase::class.java,
                    "eabp_queue.db"
                ).addMigrations(MIGRATION_1_2).build()
                INSTANCE = instance
                instance
            }
        }
    }
}