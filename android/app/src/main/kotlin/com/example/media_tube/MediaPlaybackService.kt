package com.example.media_tube

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import androidx.media.app.NotificationCompat.MediaStyle
import java.io.File
import java.net.URL
import java.util.concurrent.Executors

class MediaPlaybackService : Service() {
    companion object {
        const val ACTION_UPDATE_SESSION = "com.rajesh.mediatube.action.UPDATE_MEDIA_SESSION"
        const val ACTION_STOP_SESSION = "com.rajesh.mediatube.action.STOP_MEDIA_SESSION"
        const val ACTION_CONTROL = "com.rajesh.mediatube.action.MEDIA_CONTROL"

        const val CONTROL_PLAY = "play"
        const val CONTROL_PAUSE = "pause"
        const val CONTROL_TOGGLE = "toggle"
        const val CONTROL_STOP = "stop"
        const val CONTROL_SEEK = "seek"

        const val ACTION_PLAYBACK_CONTROL_BROADCAST = "com.rajesh.mediatube.action.PLAYBACK_CONTROL"
        const val EXTRA_EVENT_ACTION = "eventAction"
        const val EXTRA_EVENT_POSITION_MS = "eventPositionMs"

        const val EXTRA_TITLE = "title"
        const val EXTRA_SUBTITLE = "subtitle"
        const val EXTRA_DURATION_MS = "durationMs"
        const val EXTRA_POSITION_MS = "positionMs"
        const val EXTRA_IS_PLAYING = "isPlaying"
        const val EXTRA_IS_VIDEO = "isVideo"
        const val EXTRA_ARTWORK_URI = "artworkUri"
        const val EXTRA_MIME_TYPE = "mimeType"
        const val EXTRA_CONTROL_ACTION = "controlAction"

        private const val CHANNEL_ID = "mediatube_native_playback"
        private const val CHANNEL_NAME = "Media Playback"
        private const val CHANNEL_DESCRIPTION = "System media controls for lock screen and notification shade"
        private const val NOTIFICATION_ID = 90501
    }

    private val artworkExecutor = Executors.newSingleThreadExecutor()
    private var mediaSession: MediaSessionCompat? = null
    private var notificationManager: NotificationManager? = null

    private var currentTitle: String = "MediaTube"
    private var currentSubtitle: String = ""
    private var currentDurationMs: Long = 0L
    private var currentPositionMs: Long = 0L
    private var currentMimeType: String = "video/mp4"
    private var isPlaying: Boolean = false
    private var isVideo: Boolean = true
    private var currentArtworkUri: String? = null
    private var artworkBitmap: Bitmap? = null
    private var isForeground: Boolean = false
    private var artworkRequestToken: Long = 0L

    override fun onCreate() {
        super.onCreate()
        notificationManager = getSystemService(NotificationManager::class.java)
        createNotificationChannel()
        setupMediaSession()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) {
            return START_NOT_STICKY
        }

        when (intent.action) {
            ACTION_UPDATE_SESSION -> {
                updateSession(intent)
                publishPlaybackSurface()
            }

            ACTION_STOP_SESSION -> {
                clearSession(resetState = true)
                stopSelfResult(startId)
            }

            ACTION_CONTROL -> {
                val action = intent.getStringExtra(EXTRA_CONTROL_ACTION)
                if (!action.isNullOrBlank()) {
                    forwardControlAction(action)

                    if (action == CONTROL_STOP) {
                        clearSession(resetState = true)
                        stopSelfResult(startId)
                    }
                }
            }
        }

        return START_NOT_STICKY
    }

    private fun setupMediaSession() {
        mediaSession = MediaSessionCompat(this, "MediaTubePlaybackSession").apply {
            setFlags(
                MediaSessionCompat.FLAG_HANDLES_MEDIA_BUTTONS or
                    MediaSessionCompat.FLAG_HANDLES_TRANSPORT_CONTROLS,
            )
            setCallback(
                object : MediaSessionCompat.Callback() {
                    override fun onPlay() {
                        forwardControlAction(CONTROL_PLAY)
                    }

                    override fun onPause() {
                        forwardControlAction(CONTROL_PAUSE)
                    }

                    override fun onStop() {
                        forwardControlAction(CONTROL_STOP)
                    }

                    override fun onSeekTo(pos: Long) {
                        val payload = Intent(ACTION_PLAYBACK_CONTROL_BROADCAST).apply {
                            setPackage(packageName)
                            putExtra(EXTRA_EVENT_ACTION, CONTROL_SEEK)
                            putExtra(EXTRA_EVENT_POSITION_MS, pos)
                        }
                        sendBroadcast(payload)
                    }
                },
            )
            isActive = true
        }

        updatePlaybackState()
        updateMetadata()
    }

    private fun updateSession(intent: Intent) {
        currentTitle = intent.getStringExtra(EXTRA_TITLE) ?: currentTitle
        currentSubtitle = intent.getStringExtra(EXTRA_SUBTITLE) ?: currentSubtitle
        currentDurationMs = intent.getLongExtra(EXTRA_DURATION_MS, currentDurationMs).coerceAtLeast(0L)
        currentPositionMs = intent.getLongExtra(EXTRA_POSITION_MS, currentPositionMs).coerceAtLeast(0L)
        currentMimeType = intent.getStringExtra(EXTRA_MIME_TYPE) ?: currentMimeType
        isPlaying = intent.getBooleanExtra(EXTRA_IS_PLAYING, isPlaying)
        isVideo = intent.getBooleanExtra(EXTRA_IS_VIDEO, isVideo)

        val nextArtwork = intent.getStringExtra(EXTRA_ARTWORK_URI)
        if (nextArtwork != currentArtworkUri) {
            currentArtworkUri = nextArtwork
            fetchArtworkAsync(nextArtwork)
        }
    }

    private fun fetchArtworkAsync(uri: String?) {
        val requestToken = ++artworkRequestToken

        if (uri.isNullOrBlank()) {
            artworkBitmap = null
            publishPlaybackSurface()
            return
        }

        artworkExecutor.execute {
            val loaded = runCatching { loadArtwork(uri) }.getOrNull()

            if (requestToken != artworkRequestToken) {
                return@execute
            }

            artworkBitmap = loaded
            publishPlaybackSurface()
        }
    }

    private fun loadArtwork(uri: String): Bitmap? {
        return when {
            uri.startsWith("http://", ignoreCase = true) || uri.startsWith("https://", ignoreCase = true) -> {
                URL(uri).openStream().use { stream ->
                    BitmapFactory.decodeStream(stream)
                }
            }

            uri.startsWith("file://", ignoreCase = true) -> {
                BitmapFactory.decodeFile(uri.removePrefix("file://"))
            }

            File(uri).exists() -> {
                BitmapFactory.decodeFile(uri)
            }

            else -> null
        }
    }

    private fun forwardControlAction(action: String) {
        val payload = Intent(ACTION_PLAYBACK_CONTROL_BROADCAST).apply {
            setPackage(packageName)
            putExtra(EXTRA_EVENT_ACTION, action)
        }
        sendBroadcast(payload)
    }

    private fun updatePlaybackState() {
        val session = mediaSession ?: return
        val actions = PlaybackStateCompat.ACTION_PLAY or
            PlaybackStateCompat.ACTION_PAUSE or
            PlaybackStateCompat.ACTION_PLAY_PAUSE or
            PlaybackStateCompat.ACTION_STOP or
            PlaybackStateCompat.ACTION_SEEK_TO

        val state = if (isPlaying) {
            PlaybackStateCompat.STATE_PLAYING
        } else {
            PlaybackStateCompat.STATE_PAUSED
        }

        val speed = if (isPlaying) 1f else 0f

        session.setPlaybackState(
            PlaybackStateCompat.Builder()
                .setActions(actions)
                .setState(state, currentPositionMs, speed, SystemClock.elapsedRealtime())
                .build(),
        )
    }

    private fun updateMetadata() {
        val session = mediaSession ?: return

        val metadata = MediaMetadataCompat.Builder()
            .putString(MediaMetadataCompat.METADATA_KEY_TITLE, currentTitle)
            .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, currentSubtitle.ifBlank { "MediaTube" })
            .putLong(MediaMetadataCompat.METADATA_KEY_DURATION, currentDurationMs)

        artworkBitmap?.let {
            metadata.putBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART, it)
            metadata.putBitmap(MediaMetadataCompat.METADATA_KEY_ART, it)
        }

        session.setMetadata(metadata.build())
    }

    private fun publishPlaybackSurface() {
        updatePlaybackState()
        updateMetadata()
        showPlaybackNotification()
    }

    private fun showPlaybackNotification() {
        val session = mediaSession ?: return

        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }

        val openAppPendingIntent = PendingIntent.getActivity(
            this,
            701,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val toggleIntent = Intent(this, MediaPlaybackService::class.java).apply {
            action = ACTION_CONTROL
            putExtra(EXTRA_CONTROL_ACTION, if (isPlaying) CONTROL_PAUSE else CONTROL_PLAY)
        }
        val togglePendingIntent = PendingIntent.getService(
            this,
            702,
            toggleIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val stopIntent = Intent(this, MediaPlaybackService::class.java).apply {
            action = ACTION_CONTROL
            putExtra(EXTRA_CONTROL_ACTION, CONTROL_STOP)
        }
        val stopPendingIntent = PendingIntent.getService(
            this,
            703,
            stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_headset)
            .setContentTitle(currentTitle)
            .setContentText(if (currentSubtitle.isNotBlank()) currentSubtitle else if (isVideo) "Video" else "Audio")
            .setSubText(if (isPlaying) "Playing" else "Paused")
            .setContentIntent(openAppPendingIntent)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setOngoing(isPlaying)
            .setLargeIcon(artworkBitmap)
            .addAction(
                NotificationCompat.Action(
                    if (isPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
                    if (isPlaying) "Pause" else "Play",
                    togglePendingIntent,
                ),
            )
            .addAction(
                NotificationCompat.Action(
                    android.R.drawable.ic_menu_close_clear_cancel,
                    "Stop",
                    stopPendingIntent,
                ),
            )
            .setStyle(
                MediaStyle()
                    .setMediaSession(session.sessionToken)
                    .setShowActionsInCompactView(0, 1),
            )
            .build()

        if (isPlaying && !isForeground) {
            startForeground(NOTIFICATION_ID, notification)
            isForeground = true
            return
        }

        if (isPlaying) {
            notificationManager?.notify(NOTIFICATION_ID, notification)
            return
        }

        if (isForeground) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_DETACH)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(false)
            }
            isForeground = false
        }

        notificationManager?.notify(NOTIFICATION_ID, notification)
    }

    private fun clearSession(resetState: Boolean = false) {
        if (isForeground) {
            stopForeground(true)
            isForeground = false
        } else {
            notificationManager?.cancel(NOTIFICATION_ID)
        }

        if (!resetState) {
            return
        }

        artworkRequestToken++
        currentTitle = "MediaTube"
        currentSubtitle = ""
        currentDurationMs = 0L
        currentPositionMs = 0L
        currentMimeType = "video/mp4"
        isPlaying = false
        isVideo = true
        currentArtworkUri = null
        artworkBitmap = null

        mediaSession?.setPlaybackState(
            PlaybackStateCompat.Builder()
                .setActions(
                    PlaybackStateCompat.ACTION_PLAY or
                        PlaybackStateCompat.ACTION_PAUSE or
                        PlaybackStateCompat.ACTION_PLAY_PAUSE or
                        PlaybackStateCompat.ACTION_STOP or
                        PlaybackStateCompat.ACTION_SEEK_TO,
                )
                .setState(
                    PlaybackStateCompat.STATE_STOPPED,
                    0L,
                    0f,
                    SystemClock.elapsedRealtime(),
                )
                .build(),
        )

        mediaSession?.setMetadata(
            MediaMetadataCompat.Builder()
                .putString(MediaMetadataCompat.METADATA_KEY_TITLE, "MediaTube")
                .putLong(MediaMetadataCompat.METADATA_KEY_DURATION, 0L)
                .build(),
        )
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }

        val channel = NotificationChannel(
            CHANNEL_ID,
            CHANNEL_NAME,
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = CHANNEL_DESCRIPTION
            lockscreenVisibility = NotificationCompat.VISIBILITY_PUBLIC
        }

        notificationManager?.createNotificationChannel(channel)
    }

    override fun onDestroy() {
        clearSession(resetState = true)
        mediaSession?.isActive = false
        mediaSession?.release()
        mediaSession = null
        artworkExecutor.shutdownNow()
        super.onDestroy()
    }
}
