package com.example.media_tube;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

import org.schabi.newpipe.extractor.NewPipe;
import org.schabi.newpipe.extractor.ServiceList;
import org.schabi.newpipe.extractor.downloader.Downloader;
import org.schabi.newpipe.extractor.downloader.Request;
import org.schabi.newpipe.extractor.downloader.Response;
import org.schabi.newpipe.extractor.exceptions.ReCaptchaException;
import org.schabi.newpipe.extractor.services.youtube.YoutubeService;
import org.schabi.newpipe.extractor.stream.AudioStream;
import org.schabi.newpipe.extractor.stream.StreamExtractor;
import org.schabi.newpipe.extractor.stream.VideoStream;

import okhttp3.*;

import com.google.gson.Gson;
import com.google.gson.GsonBuilder;

import java.io.IOException;
import java.util.*;
import java.util.concurrent.*;
import java.util.regex.*;

/**
 * YouTube Extractor using NewPipe Extractor library.
 * Runs on-device to extract video/audio stream URLs from YouTube.
 * Uses the user's residential IP (avoids datacenter IP blocks).
 * 
 * NOTE: Initialization is LAZY - NewPipe is only initialized on first use,
 * not at app startup, to avoid blocking the UI or causing startup crashes.
 */
public class YoutubeExtractor {
    private static final String TAG = "YoutubeExtractor";
    private static final String CHANNEL_NAME = "youtube_extractor";

    private final Context context;
    private final MethodChannel channel;
    private final Handler mainHandler;
    private final ExecutorService executor;
    private final Gson gson;
    private volatile boolean initialized = false;
    private volatile boolean initializationFailed = false;
    private volatile String initializationError = null;

    public YoutubeExtractor(Context context, FlutterEngine flutterEngine) {
        this.context = context;
        this.channel = new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), CHANNEL_NAME);
        this.mainHandler = new Handler(Looper.getMainLooper());
        this.executor = Executors.newFixedThreadPool(2);
        this.gson = new GsonBuilder().create();

        setupMethodChannel();
        // NOTE: We do NOT call initializeNewPipe() here to avoid blocking startup
        // Initialization happens lazily on first use
        Log.i(TAG, "YoutubeExtractor registered (lazy init)");
    }

    /**
     * Ensure NewPipe is initialized. Called before each extraction operation.
     * Thread-safe and idempotent.
     */
    private synchronized void ensureInitialized() throws Exception {
        if (initialized)
            return;
        if (initializationFailed) {
            throw new Exception("NewPipe initialization failed: " + initializationError);
        }

        try {
            Log.i(TAG, "Initializing NewPipe Extractor...");
            NewPipe.init(new CustomDownloader());
            initialized = true;
            Log.i(TAG, "NewPipe Extractor initialized successfully");
        } catch (Exception e) {
            initializationFailed = true;
            initializationError = e.getMessage();
            Log.e(TAG, "Failed to initialize NewPipe: " + e.getMessage(), e);
            throw e;
        }
    }

    private void setupMethodChannel() {
        channel.setMethodCallHandler((call, result) -> {
            switch (call.method) {
                case "getVideoInfo": {
                    String url = call.argument("url");
                    if (url == null || url.isEmpty()) {
                        result.error("INVALID_ARGUMENT", "URL is required", null);
                        return;
                    }
                    getVideoInfoAsync(url, result);
                    break;
                }
                case "getDirectUrls": {
                    String url = call.argument("url");
                    String quality = call.argument("quality");
                    if (url == null || url.isEmpty()) {
                        result.error("INVALID_ARGUMENT", "URL is required", null);
                        return;
                    }
                    if (quality == null)
                        quality = "best";
                    getDirectUrlsAsync(url, quality, result);
                    break;
                }
                case "isInitialized": {
                    result.success(initialized);
                    break;
                }
                default:
                    result.notImplemented();
            }
        });
    }

    private void getVideoInfoAsync(String url, MethodChannel.Result result) {
        executor.execute(() -> {
            try {
                Map<String, Object> info = getVideoInfo(url);
                String json = gson.toJson(info);
                mainHandler.post(() -> result.success(json));
            } catch (Exception e) {
                Log.e(TAG, "Error getting video info: " + e.getMessage(), e);
                mainHandler.post(() -> result.error("EXTRACTION_ERROR", e.getMessage(), null));
            }
        });
    }

    private void getDirectUrlsAsync(String url, String quality, MethodChannel.Result result) {
        executor.execute(() -> {
            try {
                Map<String, Object> urls = getDirectUrls(url, quality);
                String json = gson.toJson(urls);
                mainHandler.post(() -> result.success(json));
            } catch (Exception e) {
                Log.e(TAG, "Error getting direct URLs: " + e.getMessage(), e);
                mainHandler.post(() -> result.error("EXTRACTION_ERROR", e.getMessage(), null));
            }
        });
    }

    private org.schabi.newpipe.extractor.StreamingService getStreamService(String url) {
        String lower = url.toLowerCase();
        try {
            if (lower.contains("soundcloud.com"))
                return ServiceList.SoundCloud;
            if (lower.contains("bandcamp.com"))
                return ServiceList.Bandcamp;
            if (lower.contains("media.ccc.de"))
                return ServiceList.MediaCCC;
            if (lower.contains("peertube") || lower.contains("framatube"))
                return ServiceList.PeerTube;
        } catch (Exception e) {
        }
        return ServiceList.YouTube;
    }

    /**
     * Get video info including title, duration, and available formats.
     */
    private Map<String, Object> getVideoInfo(String url) throws Exception {
        ensureInitialized();

        org.schabi.newpipe.extractor.StreamingService service = getStreamService(url);
        String streamUrl = url;
        String videoId = extractVideoId(url);

        if (service == ServiceList.YouTube) {
            if (videoId == null)
                throw new Exception("Invalid YouTube URL");
            streamUrl = "https://www.youtube.com/watch?v=" + videoId;
        } else {
            videoId = Math.abs(url.hashCode()) + "";
        }

        StreamExtractor extractor = service.getStreamExtractor(streamUrl);
        extractor.fetchPage();

        Map<String, Object> info = new HashMap<>();
        info.put("videoId", videoId);
        info.put("title", extractor.getName());
        info.put("duration", extractor.getLength());
        info.put("uploader", extractor.getUploaderName());

        // Get thumbnail
        try {
            info.put("thumbnail", extractor.getThumbnails().get(0).getUrl());
        } catch (Exception e) {
            info.put("thumbnail", null);
        }

        List<Map<String, Object>> formats = new ArrayList<>();

        // Video streams (combined - video + audio)
        for (VideoStream stream : extractor.getVideoStreams()) {
            Map<String, Object> fmt = new HashMap<>();
            fmt.put("resolution", stream.getResolution());
            fmt.put("format", stream.getFormat().getName());
            fmt.put("url", stream.getContent());
            fmt.put("isVideoOnly", false);
            formats.add(fmt);
        }

        // Video-only streams (DASH - needs audio merge)
        for (VideoStream stream : extractor.getVideoOnlyStreams()) {
            Map<String, Object> fmt = new HashMap<>();
            fmt.put("resolution", stream.getResolution());
            fmt.put("format", stream.getFormat().getName());
            fmt.put("url", stream.getContent());
            fmt.put("isVideoOnly", true);
            fmt.put("bitrate", stream.getBitrate());
            formats.add(fmt);
        }

        info.put("formats", formats);

        // Audio streams
        List<Map<String, Object>> audioFormats = new ArrayList<>();
        for (AudioStream stream : extractor.getAudioStreams()) {
            Map<String, Object> fmt = new HashMap<>();
            fmt.put("format", stream.getFormat().getName());
            fmt.put("bitrate", stream.getBitrate());
            fmt.put("url", stream.getContent());
            audioFormats.add(fmt);
        }
        info.put("audioFormats", audioFormats);

        Log.i(TAG, "Found " + formats.size() + " video, " + audioFormats.size() + " audio formats");

        return info;
    }

    /**
     * Get direct stream URLs for client-side download.
     * Returns URLs that the app can download directly from YouTube CDN.
     */
    private Map<String, Object> getDirectUrls(String url, String quality) throws Exception {
        ensureInitialized();

        org.schabi.newpipe.extractor.StreamingService service = getStreamService(url);
        String streamUrl = url;
        String videoId = extractVideoId(url);

        if (service == ServiceList.YouTube) {
            if (videoId == null)
                throw new Exception("Invalid YouTube URL");
            streamUrl = "https://www.youtube.com/watch?v=" + videoId;
        } else {
            videoId = Math.abs(url.hashCode()) + "";
        }

        StreamExtractor extractor = service.getStreamExtractor(streamUrl);
        extractor.fetchPage();

        int targetHeight = parseQuality(quality);
        String title = sanitize(extractor.getName());

        Map<String, Object> result = new HashMap<>();
        result.put("videoId", videoId);
        result.put("title", title);
        result.put("duration", extractor.getLength());

        // AUDIO-ONLY mode: return best audio stream directly
        if (targetHeight == -1) {
            AudioStream bestAudio = null;
            int bestAudioBitrate = 0;

            for (AudioStream stream : extractor.getAudioStreams()) {
                if (stream.getBitrate() > bestAudioBitrate) {
                    bestAudio = stream;
                    bestAudioBitrate = stream.getBitrate();
                }
            }

            if (bestAudio == null) {
                throw new Exception("No audio streams available");
            }

            result.put("needsMerge", false);
            result.put("videoUrl", bestAudio.getContent()); // Audio URL in videoUrl field for single-stream download
            result.put("audioUrl", null);
            result.put("videoFormat", bestAudio.getFormat().getName());
            result.put("actualQuality", "audio");
            Log.i(TAG, "Direct URLs: audio-only (" + bestAudioBitrate + " bps)");

            return result;
        }

        // Try combined streams first (video + audio together - no merge needed)
        VideoStream bestCombined = null;
        int bestCombinedHeight = 0;

        for (VideoStream stream : extractor.getVideoStreams()) {
            int h = extractHeight(stream.getResolution());
            if (h <= targetHeight && h > bestCombinedHeight) {
                bestCombined = stream;
                bestCombinedHeight = h;
            }
        }

        // Try video-only streams for higher quality
        VideoStream bestVideoOnly = null;
        int bestVideoOnlyHeight = 0;

        for (VideoStream stream : extractor.getVideoOnlyStreams()) {
            int h = extractHeight(stream.getResolution());
            if (h <= targetHeight) {
                if (h > bestVideoOnlyHeight) {
                    bestVideoOnly = stream;
                    bestVideoOnlyHeight = h;
                } else if (h == bestVideoOnlyHeight) {
                    // Prefer MPEG-4 for broader native Muxer support
                    if (stream.getFormat().getName().contains("MPEG-4")
                            && !bestVideoOnly.getFormat().getName().contains("MPEG-4")) {
                        bestVideoOnly = stream;
                    }
                }
            }
        }

        // Find best audio stream matching the video container
        AudioStream bestAudioV = null;
        int bestAudioVBitrate = 0;
        String targetAudioFormat = (bestVideoOnly != null && bestVideoOnly.getFormat().getName().contains("WebM"))
                ? "WebM"
                : "M4A";

        for (AudioStream stream : extractor.getAudioStreams()) {
            boolean matchesContainer = stream.getFormat().getName().contains(targetAudioFormat);

            if (matchesContainer) {
                if (bestAudioV == null || !bestAudioV.getFormat().getName().contains(targetAudioFormat)
                        || stream.getBitrate() > bestAudioVBitrate) {
                    bestAudioV = stream;
                    bestAudioVBitrate = stream.getBitrate();
                }
            } else if (bestAudioV == null) {
                bestAudioV = stream;
                bestAudioVBitrate = stream.getBitrate();
            }
        }

        // Prefer video-only + audio if it gives higher quality, otherwise use combined
        if (bestVideoOnlyHeight > bestCombinedHeight && bestAudioV != null) {
            // Use DASH - separate video + audio (needs merge on client)
            result.put("needsMerge", true);
            result.put("videoUrl", bestVideoOnly.getContent());
            result.put("audioUrl", bestAudioV.getContent());
            result.put("videoFormat", bestVideoOnly.getFormat().getName());
            result.put("audioFormat", bestAudioV.getFormat().getName());
            result.put("actualQuality", bestVideoOnlyHeight + "p");
            Log.i(TAG, "Direct URLs: " + bestVideoOnlyHeight + "p DASH (needs merge)");
        } else if (bestCombined != null) {
            // Use combined stream (no merge needed)
            result.put("needsMerge", false);
            result.put("videoUrl", bestCombined.getContent());
            result.put("audioUrl", null);
            result.put("videoFormat", bestCombined.getFormat().getName());
            result.put("actualQuality", bestCombinedHeight + "p");
            Log.i(TAG, "Direct URLs: " + bestCombinedHeight + "p combined (no merge)");
        } else {
            throw new Exception("No suitable video stream found");
        }

        return result;
    }

    // --- Utility Methods ---

    private String extractVideoId(String url) {
        Pattern pattern = Pattern.compile("(?:v=|/v/|youtu\\.be/|/embed/|/shorts/|/live/)([a-zA-Z0-9_-]{11})");
        Matcher m = pattern.matcher(url);
        return m.find() ? m.group(1) : null;
    }

    private int extractHeight(String res) {
        if (res == null)
            return 0;
        Matcher m = Pattern.compile("(\\d+)p").matcher(res);
        return m.find() ? Integer.parseInt(m.group(1)) : 0;
    }

    private int parseQuality(String q) {
        if (q == null || q.equals("best"))
            return 9999;
        switch (q.toLowerCase()) {
            case "audio":
                return -1; // Sentinel: audio-only mode
            case "360p":
                return 360;
            case "480p":
                return 480;
            case "720p":
                return 720;
            case "1080p":
                return 1080;
            case "1440p":
                return 1440;
            case "2160p":
            case "4k":
                return 2160;
            default:
                try {
                    return Integer.parseInt(q.replace("p", ""));
                } catch (Exception e) {
                    return 1080;
                }
        }
    }

    private String sanitize(String s) {
        if (s == null)
            return "video";
        String r = s.replaceAll("[<>:\"/\\\\|?*]", "_").trim();
        return r.length() > 80 ? r.substring(0, 80) : r;
    }

    public void dispose() {
        executor.shutdown();
    }

    // --- Custom HTTP Downloader for NewPipe ---

    private static class CustomDownloader extends Downloader {
        private final OkHttpClient client = new OkHttpClient.Builder()
                .connectTimeout(30, TimeUnit.SECONDS)
                .readTimeout(30, TimeUnit.SECONDS)
                .followRedirects(true)
                .build();

        @Override
        public Response execute(Request request) throws IOException, ReCaptchaException {
            okhttp3.Request.Builder rb = new okhttp3.Request.Builder()
                    .url(request.url())
                    .header("User-Agent",
                            "Mozilla/5.0 (Linux; Android 12; Pixel 6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36");

            // Copy headers from request
            if (request.headers() != null) {
                for (Map.Entry<String, List<String>> entry : request.headers().entrySet()) {
                    String key = entry.getKey();
                    List<String> values = entry.getValue();
                    if (values != null && !values.isEmpty()) {
                        rb.header(key, values.get(0));
                    }
                }
            }

            // Handle POST data
            if (request.dataToSend() != null) {
                rb.post(RequestBody.create(request.dataToSend(), MediaType.parse("application/json")));
            }

            okhttp3.Response res = client.newCall(rb.build()).execute();

            // Handle rate limiting / reCAPTCHA
            if (res.code() == 429) {
                res.close();
                throw new ReCaptchaException("Rate limited by YouTube", request.url());
            }

            String body = res.body() != null ? res.body().string() : "";
            Map<String, List<String>> headers = new HashMap<>();
            for (String name : res.headers().names()) {
                headers.put(name, res.headers().values(name));
            }

            return new Response(res.code(), res.message(), headers, body, request.url());
        }
    }
}
