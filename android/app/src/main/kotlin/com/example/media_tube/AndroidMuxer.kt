package com.example.media_tube

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import kotlin.concurrent.thread

class AndroidMuxer(flutterEngine: FlutterEngine) {
    private val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "media_muxer")

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "mergeVideoAudio" -> {
                    val videoPath = call.argument<String>("videoPath")
                    val audioPath = call.argument<String>("audioPath")
                    val outputPath = call.argument<String>("outputPath")

                    if (videoPath == null || audioPath == null || outputPath == null) {
                        result.error("INVALID_ARGUMENTS", "Paths cannot be null", null)
                        return@setMethodCallHandler
                    }

                    thread {
                        try {
                            val success = merge(videoPath, audioPath, outputPath)
                            // Switch back to main thread for result
                            android.os.Handler(android.os.Looper.getMainLooper()).post {
                                if (success) {
                                    result.success(true)
                                } else {
                                    result.error("MERGE_FAILED", "Failed to merge files", null)
                                }
                            }
                        } catch (e: Exception) {
                            Log.e("AndroidMuxer", "Merge error", e)
                            android.os.Handler(android.os.Looper.getMainLooper()).post {
                                result.error("MERGE_ERROR", e.message, null)
                            }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun merge(videoPath: String, audioPath: String, outputPath: String): Boolean {
        var videoExtractor: MediaExtractor? = null
        var audioExtractor: MediaExtractor? = null
        var muxer: MediaMuxer? = null

        try {
            val outputFile = File(outputPath)
            if (outputFile.exists()) {
                outputFile.delete()
            }

            videoExtractor = MediaExtractor()
            videoExtractor.setDataSource(videoPath)
            
            audioExtractor = MediaExtractor()
            audioExtractor.setDataSource(audioPath)

            val format = if (outputPath.endsWith(".webm", ignoreCase = true)) {
                MediaMuxer.OutputFormat.MUXER_OUTPUT_WEBM
            } else {
                MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4
            }
            muxer = MediaMuxer(outputPath, format)

            var videoTrackIndex = -1
            var audioTrackIndex = -1
            var videoMuxerTrackIndex = -1
            var audioMuxerTrackIndex = -1

            // Find video track
            for (i in 0 until videoExtractor.trackCount) {
                val format = videoExtractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME)
                if (mime?.startsWith("video/") == true) {
                    videoExtractor.selectTrack(i)
                    videoTrackIndex = i
                    videoMuxerTrackIndex = muxer.addTrack(format)
                    break
                }
            }

            // Find audio track
            for (i in 0 until audioExtractor.trackCount) {
                val format = audioExtractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME)
                if (mime?.startsWith("audio/") == true) {
                    audioExtractor.selectTrack(i)
                    audioTrackIndex = i
                    audioMuxerTrackIndex = muxer.addTrack(format)
                    break
                }
            }

            if (videoTrackIndex == -1 || audioTrackIndex == -1) {
                Log.e("AndroidMuxer", "Missing video or audio track")
                return false
            }

            muxer.start()

            // Copy video
            val videoBufferInfo = MediaCodec.BufferInfo()
            val maxVideoChunkSize = getVideoMaxChunkSize(videoExtractor, videoTrackIndex)
            val videoBuffer = ByteBuffer.allocate(maxVideoChunkSize)

            while (true) {
                val chunkSize = videoExtractor.readSampleData(videoBuffer, 0)
                if (chunkSize < 0) {
                    break
                }

                videoBufferInfo.offset = 0
                videoBufferInfo.size = chunkSize
                videoBufferInfo.presentationTimeUs = videoExtractor.sampleTime
                videoBufferInfo.flags = videoExtractor.sampleFlags

                muxer.writeSampleData(videoMuxerTrackIndex, videoBuffer, videoBufferInfo)
                videoExtractor.advance()
            }

            // Copy audio
            val audioBufferInfo = MediaCodec.BufferInfo()
            val maxAudioChunkSize = getAudioMaxChunkSize(audioExtractor, audioTrackIndex)
            val audioBuffer = ByteBuffer.allocate(maxAudioChunkSize)

            while (true) {
                val chunkSize = audioExtractor.readSampleData(audioBuffer, 0)
                if (chunkSize < 0) {
                    break
                }

                audioBufferInfo.offset = 0
                audioBufferInfo.size = chunkSize
                audioBufferInfo.presentationTimeUs = audioExtractor.sampleTime
                audioBufferInfo.flags = audioExtractor.sampleFlags

                muxer.writeSampleData(audioMuxerTrackIndex, audioBuffer, audioBufferInfo)
                audioExtractor.advance()
            }

            return true

        } catch (e: Exception) {
            Log.e("AndroidMuxer", "Error merging files", e)
            return false
        } finally {
            try { videoExtractor?.release() } catch (e: Exception) {}
            try { audioExtractor?.release() } catch (e: Exception) {}
            try { 
                muxer?.stop()
                muxer?.release() 
            } catch (e: Exception) {}
        }
    }

    private fun getVideoMaxChunkSize(extractor: MediaExtractor, trackIndex: Int): Int {
        var maxSize = 1024 * 1024 * 5 // 5MB fallback for 4K frames
        val format = extractor.getTrackFormat(trackIndex)
        if (format.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) {
            val size = format.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE)
            if (size > 0) maxSize = size
        }
        return maxSize
    }

    private fun getAudioMaxChunkSize(extractor: MediaExtractor, trackIndex: Int): Int {
        var maxSize = 1024 * 512 // 512KB fallback
        val format = extractor.getTrackFormat(trackIndex)
        if (format.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) {
            val size = format.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE)
            if (size > 0) maxSize = size
        }
        return maxSize
    }
}
