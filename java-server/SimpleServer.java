///usr/bin/env jbang "$0" "$@" ; exit $?
//REPOS mavencentral,jitpack=https://jitpack.io
//DEPS com.github.TeamNewPipe:NewPipeExtractor:v0.25.1
//DEPS com.google.code.gson:gson:2.10.1
//DEPS com.squareup.okhttp3:okhttp:4.12.0

import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpServer;
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

import java.io.*;
import java.net.InetSocketAddress;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;
import java.util.regex.*;

/**
 * MediaTube Java Server - Using built-in HttpServer
 * Uses NewPipe Extractor for YouTube video extraction
 */
public class SimpleServer {
    
    private static final int PORT = 5000;
    private static final Gson gson = new GsonBuilder().setPrettyPrinting().create();
    private static final File DOWNLOADS_DIR = new File("downloads");
    private static final Map<String, DownloadProgress> activeDownloads = new ConcurrentHashMap<>();
    private static final ExecutorService executor = Executors.newFixedThreadPool(4);
    private static final OkHttpClient httpClient = new OkHttpClient.Builder()
            .connectTimeout(60, TimeUnit.SECONDS)
            .readTimeout(300, TimeUnit.SECONDS)
            .writeTimeout(60, TimeUnit.SECONDS)
            .followRedirects(true)
            .build();
    
    public static void main(String[] args) throws Exception {
        System.out.println("🚀 Starting MediaTube Java Server...");
        
        // Initialize NewPipe Extractor
        try {
            NewPipe.init(new CustomDownloader());
            System.out.println("✅ NewPipe Extractor initialized");
        } catch (Exception e) {
            System.err.println("❌ Failed to initialize NewPipe: " + e.getMessage());
        }
        
        // Create downloads directory
        if (!DOWNLOADS_DIR.exists()) {
            DOWNLOADS_DIR.mkdirs();
        }
        
        // Create HTTP Server
        HttpServer server = HttpServer.create(new InetSocketAddress(PORT), 0);
        
        // Health check
        server.createContext("/health", exchange -> {
            setCors(exchange);
            if (exchange.getRequestMethod().equalsIgnoreCase("OPTIONS")) {
                exchange.sendResponseHeaders(200, -1);
                return;
            }
            String response = "{\"status\":\"ok\",\"server\":\"MediaTube Java\",\"version\":\"1.0.0\"}";
            sendJson(exchange, 200, response);
        });
        
        // Get formats
        server.createContext("/formats", exchange -> {
            setCors(exchange);
            if (exchange.getRequestMethod().equalsIgnoreCase("OPTIONS")) {
                exchange.sendResponseHeaders(200, -1);
                return;
            }
            
            String query = exchange.getRequestURI().getQuery();
            String url = getQueryParam(query, "url");
            
            if (url == null || url.isEmpty()) {
                sendJson(exchange, 400, "{\"error\":\"Missing url parameter\"}");
                return;
            }
            
            try {
                Map<String, Object> info = getVideoInfo(url);
                sendJson(exchange, 200, gson.toJson(info));
            } catch (Exception e) {
                System.err.println("❌ Error: " + e.getMessage());
                sendJson(exchange, 500, "{\"error\":\"" + e.getMessage().replace("\"", "'") + "\"}");
            }
        });
        
        // Start download
        server.createContext("/download", exchange -> {
            setCors(exchange);
            if (exchange.getRequestMethod().equalsIgnoreCase("OPTIONS")) {
                exchange.sendResponseHeaders(200, -1);
                return;
            }
            
            if (!exchange.getRequestMethod().equalsIgnoreCase("POST")) {
                sendJson(exchange, 405, "{\"error\":\"Method not allowed\"}");
                return;
            }
            
            String body = new String(exchange.getRequestBody().readAllBytes(), StandardCharsets.UTF_8);
            Map<String, Object> request = gson.fromJson(body, Map.class);
            
            String url = (String) request.get("url");
            String quality = (String) request.getOrDefault("quality", "best");
            
            if (url == null || url.isEmpty()) {
                sendJson(exchange, 400, "{\"error\":\"Missing url parameter\"}");
                return;
            }
            
            String taskId = UUID.randomUUID().toString().substring(0, 8);
            System.out.println("📥 Download request: " + taskId + ", quality=" + quality);
            
            DownloadProgress progress = new DownloadProgress(taskId, quality);
            activeDownloads.put(taskId, progress);
            
            executor.submit(() -> executeDownload(taskId, url, quality));
            
            sendJson(exchange, 200, "{\"task_id\":\"" + taskId + "\",\"message\":\"Download started\"}");
        });
        
        // Get progress
        server.createContext("/progress/", exchange -> {
            setCors(exchange);
            if (exchange.getRequestMethod().equalsIgnoreCase("OPTIONS")) {
                exchange.sendResponseHeaders(200, -1);
                return;
            }
            
            String path = exchange.getRequestURI().getPath();
            String taskId = path.substring("/progress/".length());
            
            DownloadProgress progress = activeDownloads.get(taskId);
            if (progress == null) {
                sendJson(exchange, 404, "{\"error\":\"Task not found\"}");
                return;
            }
            
            sendJson(exchange, 200, gson.toJson(progress));
        });
        
        // Get file
        server.createContext("/file/", exchange -> {
            setCors(exchange);
            String path = exchange.getRequestURI().getPath();
            String taskId = path.substring("/file/".length());
            
            DownloadProgress progress = activeDownloads.get(taskId);
            if (progress == null || progress.filePath == null) {
                exchange.sendResponseHeaders(404, 0);
                exchange.close();
                return;
            }
            
            File file = new File(progress.filePath);
            if (!file.exists()) {
                exchange.sendResponseHeaders(404, 0);
                exchange.close();
                return;
            }
            
            exchange.getResponseHeaders().set("Content-Type", "video/mp4");
            exchange.getResponseHeaders().set("Content-Disposition", "attachment; filename=\"" + file.getName() + "\"");
            exchange.sendResponseHeaders(200, file.length());
            
            try (InputStream is = new FileInputStream(file);
                 OutputStream os = exchange.getResponseBody()) {
                is.transferTo(os);
            }
        });
        
        // Get direct URLs for client-side download (FAST!)
        server.createContext("/direct", exchange -> {
            setCors(exchange);
            if (exchange.getRequestMethod().equalsIgnoreCase("OPTIONS")) {
                exchange.sendResponseHeaders(200, -1);
                return;
            }
            
            String query = exchange.getRequestURI().getQuery();
            String url = getQueryParam(query, "url");
            String quality = getQueryParam(query, "quality");
            if (quality == null) quality = "best";
            
            if (url == null || url.isEmpty()) {
                sendJson(exchange, 400, "{\"error\":\"Missing url parameter\"}");
                return;
            }
            
            try {
                Map<String, Object> result = getDirectUrls(url, quality);
                sendJson(exchange, 200, gson.toJson(result));
            } catch (Exception e) {
                System.err.println("❌ Error getting direct URLs: " + e.getMessage());
                sendJson(exchange, 500, "{\"error\":\"" + e.getMessage().replace("\"", "'") + "\"}");
            }
        });
        
        // Cleanup
        server.createContext("/cleanup/", exchange -> {
            setCors(exchange);
            if (exchange.getRequestMethod().equalsIgnoreCase("OPTIONS")) {
                exchange.sendResponseHeaders(200, -1);
                return;
            }
            
            String path = exchange.getRequestURI().getPath();
            String taskId = path.substring("/cleanup/".length());
            
            DownloadProgress progress = activeDownloads.remove(taskId);
            if (progress != null && progress.filePath != null) {
                new File(progress.filePath).delete();
            }
            
            sendJson(exchange, 200, "{\"message\":\"Cleaned up\"}");
        });
        
        server.setExecutor(Executors.newCachedThreadPool());
        server.start();
        
        System.out.println("✅ Server running on port " + PORT);
        System.out.println("📁 Downloads: " + DOWNLOADS_DIR.getAbsolutePath());
        System.out.println("Press Ctrl+C to stop...");
        
        // Shutdown hook for cleanup
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            System.out.println("\n🛑 Shutting down server...");
            server.stop(1);
            executor.shutdownNow();
        }));
        
        // Keep running - use Object.wait() which properly blocks
        Object lock = new Object();
        synchronized (lock) {
            lock.wait();
        }
    }
    
    static void setCors(HttpExchange exchange) {
        exchange.getResponseHeaders().set("Access-Control-Allow-Origin", "*");
        exchange.getResponseHeaders().set("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS");
        exchange.getResponseHeaders().set("Access-Control-Allow-Headers", "Content-Type");
    }
    
    static void sendJson(HttpExchange exchange, int status, String json) throws IOException {
        exchange.getResponseHeaders().set("Content-Type", "application/json");
        byte[] bytes = json.getBytes(StandardCharsets.UTF_8);
        exchange.sendResponseHeaders(status, bytes.length);
        try (OutputStream os = exchange.getResponseBody()) {
            os.write(bytes);
        }
    }
    
    static String getQueryParam(String query, String param) {
        if (query == null) return null;
        for (String pair : query.split("&")) {
            String[] parts = pair.split("=", 2);
            if (parts.length == 2 && parts[0].equals(param)) {
                return URLDecoder.decode(parts[1], StandardCharsets.UTF_8);
            }
        }
        return null;
    }
    
    static Map<String, Object> getVideoInfo(String url) throws Exception {
        String videoId = extractVideoId(url);
        if (videoId == null) throw new Exception("Invalid YouTube URL");
        
        String videoUrl = "https://www.youtube.com/watch?v=" + videoId;
        YoutubeService service = (YoutubeService) ServiceList.YouTube;
        StreamExtractor extractor = service.getStreamExtractor(videoUrl);
        extractor.fetchPage();
        
        Map<String, Object> info = new HashMap<>();
        info.put("videoId", videoId);
        info.put("title", extractor.getName());
        info.put("duration", extractor.getLength());
        info.put("uploader", extractor.getUploaderName());
        
        List<Map<String, Object>> formats = new ArrayList<>();
        
        // Video streams
        for (VideoStream stream : extractor.getVideoStreams()) {
            Map<String, Object> fmt = new HashMap<>();
            fmt.put("resolution", stream.getResolution());
            fmt.put("format", stream.getFormat().getName());
            fmt.put("url", stream.getContent());
            fmt.put("isVideoOnly", false);
            formats.add(fmt);
        }
        
        // Video-only streams
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
        
        List<Map<String, Object>> audioFormats = new ArrayList<>();
        for (AudioStream stream : extractor.getAudioStreams()) {
            Map<String, Object> fmt = new HashMap<>();
            fmt.put("format", stream.getFormat().getName());
            fmt.put("bitrate", stream.getBitrate());
            fmt.put("url", stream.getContent());
            audioFormats.add(fmt);
        }
        info.put("audioFormats", audioFormats);
        
        System.out.println("📹 Found " + formats.size() + " video, " + audioFormats.size() + " audio formats");
        
        return info;
    }
    
    // Get direct URLs for client-side download (FAST - no proxy through server)
    static Map<String, Object> getDirectUrls(String url, String quality) throws Exception {
        String videoId = extractVideoId(url);
        if (videoId == null) throw new Exception("Invalid YouTube URL");
        
        String videoUrl = "https://www.youtube.com/watch?v=" + videoId;
        YoutubeService service = (YoutubeService) ServiceList.YouTube;
        StreamExtractor extractor = service.getStreamExtractor(videoUrl);
        extractor.fetchPage();
        
        int targetHeight = parseQuality(quality);
        String title = sanitize(extractor.getName());
        
        Map<String, Object> result = new HashMap<>();
        result.put("videoId", videoId);
        result.put("title", title);
        result.put("duration", extractor.getLength());
        
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
            if (h <= targetHeight && h > bestVideoOnlyHeight) {
                bestVideoOnly = stream;
                bestVideoOnlyHeight = h;
            }
        }
        
        // Find best audio stream
        AudioStream bestAudio = null;
        int bestAudioBitrate = 0;
        
        for (AudioStream stream : extractor.getAudioStreams()) {
            if (stream.getBitrate() > bestAudioBitrate) {
                bestAudio = stream;
                bestAudioBitrate = stream.getBitrate();
            }
        }
        
        // Prefer video-only + audio if it gives higher quality, otherwise use combined
        if (bestVideoOnlyHeight > bestCombinedHeight && bestAudio != null) {
            // Use DASH - separate video + audio (needs merge on client)
            result.put("needsMerge", true);
            result.put("videoUrl", bestVideoOnly.getContent());
            result.put("audioUrl", bestAudio.getContent());
            result.put("videoFormat", bestVideoOnly.getFormat().getName());
            result.put("audioFormat", bestAudio.getFormat().getName());
            result.put("actualQuality", bestVideoOnlyHeight + "p");
            System.out.println("🎬 Direct URLs: " + bestVideoOnlyHeight + "p DASH (needs merge)");
        } else if (bestCombined != null) {
            // Use combined stream (no merge needed)
            result.put("needsMerge", false);
            result.put("videoUrl", bestCombined.getContent());
            result.put("audioUrl", null);
            result.put("videoFormat", bestCombined.getFormat().getName());
            result.put("actualQuality", bestCombinedHeight + "p");
            System.out.println("🎬 Direct URLs: " + bestCombinedHeight + "p combined (no merge)");
        } else {
            throw new Exception("No suitable video stream found");
        }
        
        return result;
    }
    
    static void executeDownload(String taskId, String url, String quality) {
        DownloadProgress progress = activeDownloads.get(taskId);
        
        try {
            progress.status = "extracting";
            System.out.println("🎬 Starting: " + taskId);
            
            String videoId = extractVideoId(url);
            if (videoId == null) throw new Exception("Invalid URL");
            
            String videoUrl = "https://www.youtube.com/watch?v=" + videoId;
            YoutubeService service = (YoutubeService) ServiceList.YouTube;
            StreamExtractor extractor = service.getStreamExtractor(videoUrl);
            extractor.fetchPage();
            
            String title = sanitize(extractor.getName());
            int targetHeight = parseQuality(quality);
            
            // Find best video stream
            VideoStream bestVideo = null;
            int bestHeight = 0;
            boolean needsMerge = false;
            
            // Try combined streams first
            for (VideoStream stream : extractor.getVideoStreams()) {
                int h = extractHeight(stream.getResolution());
                if (h <= targetHeight && h > bestHeight) {
                    bestVideo = stream;
                    bestHeight = h;
                    needsMerge = false;
                }
            }
            
            // Try video-only for higher quality
            for (VideoStream stream : extractor.getVideoOnlyStreams()) {
                int h = extractHeight(stream.getResolution());
                if (h <= targetHeight && h > bestHeight) {
                    bestVideo = stream;
                    bestHeight = h;
                    needsMerge = true;
                }
            }
            
            if (bestVideo == null) throw new Exception("No video stream found");
            
            progress.actualHeight = bestHeight;
            System.out.println("📹 Selected: " + bestVideo.getResolution());
            
            if (needsMerge) {
                // Get best audio
                AudioStream bestAudio = null;
                int bestBitrate = 0;
                for (AudioStream stream : extractor.getAudioStreams()) {
                    if (stream.getBitrate() > bestBitrate) {
                        bestAudio = stream;
                        bestBitrate = stream.getBitrate();
                    }
                }
                
                if (bestAudio != null) {
                    downloadAndMerge(taskId, bestVideo, bestAudio, title, progress);
                } else {
                    downloadDirect(taskId, bestVideo.getContent(), title, "mp4", progress);
                }
            } else {
                downloadDirect(taskId, bestVideo.getContent(), title, bestVideo.getFormat().getSuffix(), progress);
            }
            
        } catch (Exception e) {
            System.err.println("❌ Download failed: " + e.getMessage());
            e.printStackTrace();
            progress.status = "failed";
            progress.error = e.getMessage();
        }
    }
    
    static void downloadAndMerge(String taskId, VideoStream video, AudioStream audio, String title, DownloadProgress progress) throws Exception {
        File videoFile = new File(DOWNLOADS_DIR, taskId + "_video.mp4");
        File audioFile = new File(DOWNLOADS_DIR, taskId + "_audio.m4a");
        File outputFile = new File(DOWNLOADS_DIR, taskId + "_" + title + ".mp4");
        
        try {
            progress.status = "downloading_video";
            System.out.println("📥 Downloading video...");
            downloadFile(video.getContent(), videoFile, progress, 0.0, 0.45);
            
            progress.status = "downloading_audio";
            System.out.println("📥 Downloading audio...");
            downloadFile(audio.getContent(), audioFile, progress, 0.45, 0.85);
            
            progress.status = "merging";
            progress.progress = 0.9;
            System.out.println("🔀 Merging...");
            
            ProcessBuilder pb = new ProcessBuilder(
                    "ffmpeg", "-y",
                    "-i", videoFile.getAbsolutePath(),
                    "-i", audioFile.getAbsolutePath(),
                    "-c:v", "copy", "-c:a", "aac",
                    outputFile.getAbsolutePath()
            );
            pb.redirectErrorStream(true);
            Process p = pb.start();
            new BufferedReader(new InputStreamReader(p.getInputStream())).lines().forEach(l -> {});
            if (p.waitFor() != 0) throw new Exception("FFmpeg failed");
            
            videoFile.delete();
            audioFile.delete();
            
            progress.status = "completed";
            progress.progress = 1.0;
            progress.filePath = outputFile.getAbsolutePath();
            progress.filename = outputFile.getName();
            
            System.out.println("✅ Done: " + outputFile.getName());
            
        } catch (Exception e) {
            videoFile.delete();
            audioFile.delete();
            outputFile.delete();
            throw e;
        }
    }
    
    static void downloadDirect(String taskId, String url, String title, String ext, DownloadProgress progress) throws Exception {
        File outputFile = new File(DOWNLOADS_DIR, taskId + "_" + title + "." + ext);
        
        progress.status = "downloading";
        System.out.println("📥 Downloading...");
        
        downloadFile(url, outputFile, progress, 0.0, 1.0);
        
        progress.status = "completed";
        progress.progress = 1.0;
        progress.filePath = outputFile.getAbsolutePath();
        progress.filename = outputFile.getName();
        
        System.out.println("✅ Done: " + outputFile.getName());
    }
    
    static void downloadFile(String url, File output, DownloadProgress progress, double pStart, double pEnd) throws Exception {
        okhttp3.Request request = new okhttp3.Request.Builder()
                .url(url)
                .header("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
                .header("Accept", "*/*")
                .header("Accept-Encoding", "identity")
                .header("Connection", "keep-alive")
                .build();
        
        try (okhttp3.Response response = httpClient.newCall(request).execute()) {
            if (!response.isSuccessful()) throw new IOException("HTTP " + response.code());
            
            long total = response.body().contentLength();
            progress.totalBytes = total;
            
            // Use larger buffer (64KB) for faster downloads
            try (InputStream in = response.body().byteStream();
                 OutputStream out = new BufferedOutputStream(new FileOutputStream(output), 65536)) {
                
                byte[] buf = new byte[65536]; // 64KB buffer
                long downloaded = 0;
                int n;
                
                while ((n = in.read(buf)) != -1) {
                    out.write(buf, 0, n);
                    downloaded += n;
                    progress.downloadedBytes = downloaded;
                    
                    if (total > 0) {
                        progress.progress = pStart + ((double) downloaded / total) * (pEnd - pStart);
                    }
                }
            }
        }
    }
    
    static String extractVideoId(String url) {
        Matcher m = Pattern.compile("(?:v=|/v/|youtu\\.be/|/embed/|/shorts/)([a-zA-Z0-9_-]{11})").matcher(url);
        return m.find() ? m.group(1) : null;
    }
    
    static int extractHeight(String res) {
        if (res == null) return 0;
        Matcher m = Pattern.compile("(\\d+)p").matcher(res);
        return m.find() ? Integer.parseInt(m.group(1)) : 0;
    }
    
    static int parseQuality(String q) {
        if (q == null || q.equals("best")) return 9999;
        return switch (q.toLowerCase()) {
            case "360p" -> 360;
            case "480p" -> 480;
            case "720p" -> 720;
            case "1080p" -> 1080;
            case "1440p" -> 1440;
            case "2160p", "4k" -> 2160;
            default -> {
                try { yield Integer.parseInt(q.replace("p", "")); }
                catch (Exception e) { yield 1080; }
            }
        };
    }
    
    static String sanitize(String s) {
        if (s == null) return "video";
        String r = s.replaceAll("[<>:\"/\\\\|?*]", "_").trim();
        return r.length() > 80 ? r.substring(0, 80) : r;
    }
    
    // Progress tracking class
    static class DownloadProgress {
        String taskId, status = "pending", filename, filePath, error, requestedQuality;
        double progress = 0;
        long downloadedBytes = 0, totalBytes = 0;
        Integer actualHeight;
        
        DownloadProgress(String id, String quality) {
            this.taskId = id;
            this.requestedQuality = quality;
        }
    }
    
    // Custom HTTP downloader for NewPipe
    static class CustomDownloader extends Downloader {
        private final OkHttpClient client = new OkHttpClient.Builder()
                .connectTimeout(30, TimeUnit.SECONDS)
                .readTimeout(30, TimeUnit.SECONDS)
                .followRedirects(true)
                .build();
        
        @Override
        public Response execute(Request request) throws IOException, ReCaptchaException {
            okhttp3.Request.Builder rb = new okhttp3.Request.Builder()
                    .url(request.url())
                    .header("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36");
            
            if (request.headers() != null) {
                request.headers().forEach((k, v) -> { if (v != null && !v.isEmpty()) rb.header(k, v.get(0)); });
            }
            
            if (request.dataToSend() != null) {
                rb.post(RequestBody.create(request.dataToSend(), MediaType.parse("application/json")));
            }
            
            okhttp3.Response res = client.newCall(rb.build()).execute();
            
            if (res.code() == 429) {
                res.close();
                throw new ReCaptchaException("reCAPTCHA", request.url());
            }
            
            String body = res.body() != null ? res.body().string() : "";
            Map<String, List<String>> headers = new HashMap<>();
            res.headers().names().forEach(n -> headers.put(n, res.headers().values(n)));
            
            return new Response(res.code(), res.message(), headers, body, request.url());
        }
    }
}
