package com.mediatube.server;

import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import org.schabi.newpipe.extractor.NewPipe;

import static spark.Spark.*;

/**
 * MediaTube Java Backend Server
 * Uses NewPipe Extractor for YouTube video extraction
 * Note: Downloads are handled directly by the app; this server only provides URL extraction
 */
public class MediaTubeServer {
    
    private static final int PORT = 5000;
    private static final Gson gson = new GsonBuilder().setPrettyPrinting().create();
    private static YouTubeService youtubeService;
    
    public static void main(String[] args) {
        System.out.println("🚀 Starting MediaTube Java Server...");
        
        // Initialize NewPipe Extractor
        initNewPipe();
        
        // Initialize services
        youtubeService = new YouTubeService();
        
        // Configure Spark
        port(PORT);
        
        // Enable CORS
        before((request, response) -> {
            response.header("Access-Control-Allow-Origin", "*");
            response.header("Access-Control-Allow-Methods", "GET, OPTIONS");
            response.header("Access-Control-Allow-Headers", "Content-Type, Authorization");
        });
        
        options("/*", (request, response) -> {
            response.header("Access-Control-Allow-Origin", "*");
            response.header("Access-Control-Allow-Methods", "GET, OPTIONS");
            response.header("Access-Control-Allow-Headers", "Content-Type");
            return "OK";
        });
        
        // Health check endpoint
        get("/health", (req, res) -> {
            res.type("application/json");
            return gson.toJson(new HealthResponse("ok", "MediaTube Java Server", "2.0.0"));
        });
        
        // ============================================================
        // App Version Check Endpoint for Auto-Update Feature
        // Update these values manually when releasing a new APK
        // ============================================================
        get("/api/app-version", (req, res) -> {
            res.type("application/json");
            
            // TODO: Update these values when releasing a new version
            String currentVersion = "1.0.0";
            String changelog = "Initial release with media detection and download capabilities.";
            String downloadUrl = "https://github.com/YOUR_USERNAME/MediaTube/releases/download/v1.0.0/app-release.apk";
            
            return gson.toJson(new AppVersionResponse(currentVersion, changelog, downloadUrl));
        });
        
        // Get available formats for a video (main endpoint used by app)
        get("/formats", (req, res) -> {
            res.type("application/json");
            String url = req.queryParams("url");
            
            if (url == null || url.isEmpty()) {
                res.status(400);
                return gson.toJson(new ErrorResponse("Missing 'url' parameter"));
            }
            
            try {
                VideoInfo info = youtubeService.getVideoInfo(url);
                return gson.toJson(info);
            } catch (Exception e) {
                System.err.println("❌ Error getting formats: " + e.getMessage());
                e.printStackTrace();
                res.status(500);
                return gson.toJson(new ErrorResponse("Failed to get formats: " + e.getMessage()));
            }
        });
        
        // Get direct download URLs for a specific quality
        // This is what the app calls to get the actual URLs to download from
        get("/direct", (req, res) -> {
            res.type("application/json");
            String url = req.queryParams("url");
            String quality = req.queryParams("quality");
            
            if (url == null || url.isEmpty()) {
                res.status(400);
                return gson.toJson(new ErrorResponse("Missing 'url' parameter"));
            }
            
            if (quality == null || quality.isEmpty()) {
                quality = "best";
            }
            
            try {
                DirectUrls urls = youtubeService.getDirectUrls(url, quality);
                return gson.toJson(urls);
            } catch (Exception e) {
                System.err.println("❌ Error getting direct URLs: " + e.getMessage());
                e.printStackTrace();
                res.status(500);
                return gson.toJson(new ErrorResponse("Failed to get direct URLs: " + e.getMessage()));
            }
        });
        
        System.out.println("✅ MediaTube Java Server running on port " + PORT);
        System.out.println("ℹ️  This server provides URL extraction only. Downloads handled by app.");
    }
    
    private static void initNewPipe() {
        try {
            NewPipe.init(new CustomDownloader());
            System.out.println("✅ NewPipe Extractor initialized");
        } catch (Exception e) {
            System.err.println("❌ Failed to initialize NewPipe: " + e.getMessage());
            e.printStackTrace();
        }
    }
    
    // Response classes
    static class HealthResponse {
        String status;
        String server;
        String version;
        
        HealthResponse(String status, String server, String version) {
            this.status = status;
            this.server = server;
            this.version = version;
        }
    }
    
    static class ErrorResponse {
        String error;
        
        ErrorResponse(String error) {
            this.error = error;
        }
    }
    
    /**
     * Response class for app version check endpoint
     * Used by the Flutter app's auto-update feature
     */
    static class AppVersionResponse {
        String version;
        String changelog;
        String downloadUrl;
        
        AppVersionResponse(String version, String changelog, String downloadUrl) {
            this.version = version;
            this.changelog = changelog;
            this.downloadUrl = downloadUrl;
        }
    }
}
