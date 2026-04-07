package com.example.media_tube

import android.app.PictureInPictureParams
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.util.Rational
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class PlaybackPlatformBridge(
    private val activity: FlutterFragmentActivity,
    flutterEngine: FlutterEngine,
) : EventChannel.StreamHandler {
    companion object {
        private const val METHOD_CHANNEL_NAME = "com.rajesh.mediatube/playback_native"
        private const val EVENT_CHANNEL_NAME = "com.rajesh.mediatube/playback_native_events"
    }

    private val methodChannel = MethodChannel(
        flutterEngine.dartExecutor.binaryMessenger,
        METHOD_CHANNEL_NAME,
    )
    private val eventChannel = EventChannel(
        flutterEngine.dartExecutor.binaryMessenger,
        EVENT_CHANNEL_NAME,
    )

    private var eventSink: EventChannel.EventSink? = null
    private var isReceiverRegistered = false

    private var pipEnabled = false
    private var autoEnterPip = true
    private var pipAspectRatio = Rational(16, 9)

    private val playbackActionsReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != MediaPlaybackService.ACTION_PLAYBACK_CONTROL_BROADCAST) {
                return
            }

            val action = intent.getStringExtra(MediaPlaybackService.EXTRA_EVENT_ACTION)
            if (action.isNullOrBlank()) {
                return
            }

            val event = hashMapOf<String, Any>(
                "event" to "mediaControl",
                "action" to action,
            )

            if (intent.hasExtra(MediaPlaybackService.EXTRA_EVENT_POSITION_MS)) {
                event["positionMs"] = intent.getLongExtra(
                    MediaPlaybackService.EXTRA_EVENT_POSITION_MS,
                    0L,
                )
            }

            activity.runOnUiThread {
                eventSink?.success(event)
            }
        }
    }

    init {
        eventChannel.setStreamHandler(this)
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "configurePip" -> {
                    pipEnabled = call.argument<Boolean>("enabled") == true
                    autoEnterPip = call.argument<Boolean>("autoEnter") != false

                    val aspectWidth = (call.argument<Number>("aspectWidth")?.toInt() ?: 16)
                        .coerceAtLeast(1)
                    val aspectHeight = (call.argument<Number>("aspectHeight")?.toInt() ?: 9)
                        .coerceAtLeast(1)
                    pipAspectRatio = Rational(aspectWidth, aspectHeight)

                    applyPipParameters()
                    result.success(null)
                }

                "enterPipNow" -> {
                    result.success(enterPipNow())
                }

                "isInPipMode" -> {
                    val inPip = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                        activity.isInPictureInPictureMode
                    } else {
                        false
                    }
                    result.success(inPip)
                }

                "updateMediaSession" -> {
                    updateMediaSession(
                        title = call.argument<String>("title") ?: "MediaTube",
                        subtitle = call.argument<String>("subtitle") ?: "",
                        durationMs = call.argument<Number>("durationMs")?.toLong() ?: 0L,
                        positionMs = call.argument<Number>("positionMs")?.toLong() ?: 0L,
                        isPlaying = call.argument<Boolean>("isPlaying") == true,
                        isVideo = call.argument<Boolean>("isVideo") != false,
                        artworkUri = call.argument<String>("artworkUri"),
                        mimeType = call.argument<String>("mimeType") ?: "video/mp4",
                    )
                    result.success(null)
                }

                "stopMediaSession" -> {
                    stopMediaSession()
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }

        registerPlaybackActionsReceiver()
    }

    private fun updateMediaSession(
        title: String,
        subtitle: String,
        durationMs: Long,
        positionMs: Long,
        isPlaying: Boolean,
        isVideo: Boolean,
        artworkUri: String?,
        mimeType: String,
    ) {
        val intent = Intent(activity, MediaPlaybackService::class.java).apply {
            action = MediaPlaybackService.ACTION_UPDATE_SESSION
            putExtra(MediaPlaybackService.EXTRA_TITLE, title)
            putExtra(MediaPlaybackService.EXTRA_SUBTITLE, subtitle)
            putExtra(MediaPlaybackService.EXTRA_DURATION_MS, durationMs)
            putExtra(MediaPlaybackService.EXTRA_POSITION_MS, positionMs)
            putExtra(MediaPlaybackService.EXTRA_IS_PLAYING, isPlaying)
            putExtra(MediaPlaybackService.EXTRA_IS_VIDEO, isVideo)
            putExtra(MediaPlaybackService.EXTRA_MIME_TYPE, mimeType)
            putExtra(MediaPlaybackService.EXTRA_ARTWORK_URI, artworkUri)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            ContextCompat.startForegroundService(activity, intent)
        } else {
            activity.startService(intent)
        }
    }

    private fun stopMediaSession() {
        activity.stopService(Intent(activity, MediaPlaybackService::class.java))
    }

    private fun applyPipParameters() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }

        val paramsBuilder = PictureInPictureParams.Builder()
            .setAspectRatio(pipAspectRatio)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            paramsBuilder.setAutoEnterEnabled(pipEnabled && autoEnterPip)
        }

        activity.setPictureInPictureParams(paramsBuilder.build())
    }

    private fun registerPlaybackActionsReceiver() {
        if (isReceiverRegistered) {
            return
        }

        val filter = IntentFilter(MediaPlaybackService.ACTION_PLAYBACK_CONTROL_BROADCAST)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            activity.registerReceiver(
                playbackActionsReceiver,
                filter,
                Context.RECEIVER_NOT_EXPORTED,
            )
        } else {
            @Suppress("DEPRECATION")
            activity.registerReceiver(playbackActionsReceiver, filter)
        }

        isReceiverRegistered = true
    }

    fun onUserLeaveHint() {
        if (!pipEnabled || Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S || !autoEnterPip) {
            enterPipNow()
        } else {
            applyPipParameters()
        }
    }

    private fun enterPipNow(): Boolean {
        if (!pipEnabled || Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return false
        }

        val params = PictureInPictureParams.Builder()
            .setAspectRatio(pipAspectRatio)
            .build()

        return activity.enterPictureInPictureMode(params)
    }

    fun onPictureInPictureModeChanged(inPictureInPictureMode: Boolean) {
        val event = hashMapOf<String, Any>(
            "event" to "pipChanged",
            "inPip" to inPictureInPictureMode,
        )
        activity.runOnUiThread {
            eventSink?.success(event)
        }
    }

    fun dispose() {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)

        if (isReceiverRegistered) {
            activity.unregisterReceiver(playbackActionsReceiver)
            isReceiverRegistered = false
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }
}
