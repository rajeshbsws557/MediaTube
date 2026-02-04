package com.mediatube.server;

import org.schabi.newpipe.extractor.downloader.Downloader;
import org.schabi.newpipe.extractor.downloader.Request;
import org.schabi.newpipe.extractor.downloader.Response;
import org.schabi.newpipe.extractor.exceptions.ReCaptchaException;

import okhttp3.*;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.TimeUnit;

/**
 * Custom Downloader for NewPipe Extractor using OkHttp
 * Supports YouTube cookies to bypass bot detection on cloud servers
 */
public class CustomDownloader extends Downloader {
    
private static final String USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/144.0.0.0 Safari/537.36";    
    private final OkHttpClient client;
    private String youtubeCookies = null;
    
    public CustomDownloader() {
        this.client = new OkHttpClient.Builder()
                .connectTimeout(30, TimeUnit.SECONDS)
                .readTimeout(30, TimeUnit.SECONDS)
                .writeTimeout(30, TimeUnit.SECONDS)
                .followRedirects(true)
                .followSslRedirects(true)
                .build();
        
        // Try to load cookies from file
        loadCookiesFromFile();
    }
    
    /**
     * Load YouTube cookies from cookies.txt file
     * Format: Just paste the Cookie header value from browser
     */
    private void loadCookiesFromFile() {
        try {
            Path cookieFile = Paths.get("/home/ubuntu/cookies.txt");
            if (Files.exists(cookieFile)) {
                youtubeCookies = Files.readString(cookieFile).trim();
                if (!youtubeCookies.isEmpty()) {
                    System.out.println("✅ Loaded YouTube cookies from cookies.txt");
                } else {
                    youtubeCookies = null;
                }
            } else {
                System.out.println("ℹ️ No cookies.txt found - YouTube may block requests from cloud IPs");
                System.out.println("ℹ️ To fix: Create cookies.txt with your YouTube cookie header value");
            }
        } catch (Exception e) {
            System.err.println("⚠️ Error loading cookies: " + e.getMessage());
        }
    }
    
    /**
     * Set cookies programmatically
     */
    public void setCookies(String cookies) {
        this.youtubeCookies = cookies;
    }
    
    @Override
    public Response execute(Request request) throws IOException, ReCaptchaException {
        String url = request.url();
        Map<String, List<String>> headers = request.headers();
        byte[] dataToSend = request.dataToSend();
        
        okhttp3.Request.Builder requestBuilder = new okhttp3.Request.Builder()
                .url(url)
                .header("User-Agent", USER_AGENT)
                .header("Accept-Language", "en-US,en;q=0.9")
                .header("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8");
        
        // Add YouTube cookies if available (critical for cloud servers!)
        if (youtubeCookies != null && !youtubeCookies.isEmpty() && url.contains("youtube.com")) {
            requestBuilder.header("Cookie", youtubeCookies);
        }
        
        // Add custom headers
        if (headers != null) {
            for (Map.Entry<String, List<String>> entry : headers.entrySet()) {
                String headerName = entry.getKey();
                List<String> headerValues = entry.getValue();
                if (headerValues != null && !headerValues.isEmpty()) {
                    requestBuilder.header(headerName, headerValues.get(0));
                }
            }
        }
        
        // Set request method and body
        if (dataToSend != null) {
            RequestBody body = RequestBody.create(dataToSend, MediaType.parse("application/json"));
            requestBuilder.post(body);
        }
        
        okhttp3.Response response = client.newCall(requestBuilder.build()).execute();
        
        // Check for reCAPTCHA or bot detection
        if (response.code() == 429) {
            response.close();
            throw new ReCaptchaException("reCAPTCHA challenge - try adding cookies.txt", url);
        }
        
        String responseBody = response.body() != null ? response.body().string() : "";
        
        // Check for "Sign in to confirm you're not a bot" in response
        if (responseBody.contains("Sign in to confirm") || responseBody.contains("confirm that you")) {
            throw new ReCaptchaException("Bot detection triggered - add cookies.txt with YouTube cookies", url);
        }
        
        // Convert OkHttp headers to map
        Map<String, List<String>> responseHeaders = new HashMap<>();
        Headers okHeaders = response.headers();
        for (String name : okHeaders.names()) {
            responseHeaders.put(name, okHeaders.values(name));
        }
        
        return new Response(
                response.code(),
                response.message(),
                responseHeaders,
                responseBody,
                url
        );
    }
}
