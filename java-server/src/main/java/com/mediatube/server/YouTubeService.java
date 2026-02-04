package com.mediatube.server;

import org.schabi.newpipe.extractor.ServiceList;
import org.schabi.newpipe.extractor.services.youtube.YoutubeService;
import org.schabi.newpipe.extractor.stream.AudioStream;
import org.schabi.newpipe.extractor.stream.StreamExtractor;
import org.schabi.newpipe.extractor.stream.VideoStream;

import java.util.ArrayList;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Service for extracting YouTube video information using NewPipe Extractor
 * Note: Only provides URL extraction. Downloads and merging handled by the app.
 */
public class YouTubeService {
    
    private final YoutubeService service;
    
    public YouTubeService() {
        this.service = (YoutubeService) ServiceList.YouTube;
    }
    
    /**
     * Extract video ID from various YouTube URL formats
     */
    public String extractVideoId(String url) {
        Pattern[] patterns = {
            Pattern.compile("(?:v=|/v/|youtu\\.be/|/embed/|/shorts/)([a-zA-Z0-9_-]{11})"),
            Pattern.compile("^([a-zA-Z0-9_-]{11})$")
        };
        
        for (Pattern pattern : patterns) {
            Matcher matcher = pattern.matcher(url);
            if (matcher.find()) {
                return matcher.group(1);
            }
        }
        return null;
    }
    
    /**
     * Get video information including available formats
     */
    public VideoInfo getVideoInfo(String url) throws Exception {
        String videoId = extractVideoId(url);
        if (videoId == null) {
            throw new IllegalArgumentException("Invalid YouTube URL");
        }
        
        String videoUrl = "https://www.youtube.com/watch?v=" + videoId;
        
        StreamExtractor extractor = service.getStreamExtractor(videoUrl);
        extractor.fetchPage();
        
        VideoInfo info = new VideoInfo();
        info.videoId = videoId;
        info.title = extractor.getName();
        info.duration = extractor.getLength();
        info.thumbnailUrl = extractor.getThumbnails().isEmpty() ? null : extractor.getThumbnails().get(0).getUrl();
        info.uploaderName = extractor.getUploaderName();
        info.formats = new ArrayList<>();
        
        // Get video streams (combined video+audio)
        List<VideoStream> videoStreams = extractor.getVideoStreams();
        for (VideoStream stream : videoStreams) {
            VideoFormat format = new VideoFormat();
            format.formatId = stream.getFormat().getName() + "_" + stream.getResolution();
            format.extension = stream.getFormat().getSuffix();
            format.resolution = stream.getResolution();
            format.height = extractHeight(stream.getResolution());
            format.url = stream.getContent();
            format.isVideoOnly = false;
            format.codec = stream.getCodec();
            info.formats.add(format);
        }
        
        // Get video-only streams (for higher quality - needs separate audio)
        List<VideoStream> videoOnlyStreams = extractor.getVideoOnlyStreams();
        for (VideoStream stream : videoOnlyStreams) {
            VideoFormat format = new VideoFormat();
            format.formatId = stream.getFormat().getName() + "_" + stream.getResolution() + "_video";
            format.extension = stream.getFormat().getSuffix();
            format.resolution = stream.getResolution();
            format.height = extractHeight(stream.getResolution());
            format.url = stream.getContent();
            format.isVideoOnly = true;
            format.codec = stream.getCodec();
            format.bitrate = stream.getBitrate();
            info.formats.add(format);
        }
        
        // Get audio streams
        info.audioFormats = new ArrayList<>();
        List<AudioStream> audioStreams = extractor.getAudioStreams();
        for (AudioStream stream : audioStreams) {
            AudioFormat format = new AudioFormat();
            format.formatId = stream.getFormat().getName() + "_audio";
            format.extension = stream.getFormat().getSuffix();
            format.url = stream.getContent();
            format.bitrate = stream.getBitrate();
            format.codec = stream.getCodec();
            info.audioFormats.add(format);
        }
        
        // Sort formats by height (highest first)
        info.formats.sort((a, b) -> Integer.compare(b.height, a.height));
        // Sort audio by bitrate (highest first)
        info.audioFormats.sort((a, b) -> Integer.compare(b.bitrate, a.bitrate));
        
        System.out.println("📹 Found " + info.formats.size() + " video formats, " + info.audioFormats.size() + " audio formats");
        
        return info;
    }
    
    /**
     * Get direct download URLs for a specific quality
     * Used by the app to download directly from YouTube's CDN
     */
    public DirectUrls getDirectUrls(String url, String quality) throws Exception {
        String videoId = extractVideoId(url);
        if (videoId == null) {
            throw new IllegalArgumentException("Invalid YouTube URL");
        }
        
        String videoUrl = "https://www.youtube.com/watch?v=" + videoId;
        
        StreamExtractor extractor = service.getStreamExtractor(videoUrl);
        extractor.fetchPage();
        
        DirectUrls result = new DirectUrls();
        result.videoId = videoId;
        result.title = extractor.getName();
        
        // Parse requested quality
        int requestedHeight = parseQuality(quality);
        
        // First, try to find a combined stream (muxed video+audio) at requested quality
        List<VideoStream> videoStreams = extractor.getVideoStreams();
        VideoStream bestMuxed = null;
        
        for (VideoStream stream : videoStreams) {
            int height = extractHeight(stream.getResolution());
            if (bestMuxed == null || 
                (Math.abs(height - requestedHeight) < Math.abs(extractHeight(bestMuxed.getResolution()) - requestedHeight))) {
                bestMuxed = stream;
            }
        }
        
        // Get video-only streams for higher quality options
        List<VideoStream> videoOnlyStreams = extractor.getVideoOnlyStreams();
        VideoStream bestVideoOnly = null;
        
        for (VideoStream stream : videoOnlyStreams) {
            int height = extractHeight(stream.getResolution());
            if (height <= requestedHeight || quality.equals("best")) {
                if (bestVideoOnly == null || extractHeight(stream.getResolution()) > extractHeight(bestVideoOnly.getResolution())) {
                    bestVideoOnly = stream;
                }
            }
        }
        
        // Get best audio stream
        List<AudioStream> audioStreams = extractor.getAudioStreams();
        AudioStream bestAudio = audioStreams.isEmpty() ? null : audioStreams.get(0);
        for (AudioStream stream : audioStreams) {
            if (bestAudio == null || stream.getBitrate() > bestAudio.getBitrate()) {
                bestAudio = stream;
            }
        }
        
        // Decide whether to use muxed or video-only + audio
        // Use video-only if it has higher quality than best muxed
        boolean useVideoOnly = false;
        if (bestVideoOnly != null && bestAudio != null) {
            int videoOnlyHeight = extractHeight(bestVideoOnly.getResolution());
            int muxedHeight = bestMuxed != null ? extractHeight(bestMuxed.getResolution()) : 0;
            
            // Use video-only if it's higher quality OR if requested quality is higher than muxed
            if (videoOnlyHeight > muxedHeight || requestedHeight > muxedHeight) {
                useVideoOnly = true;
            }
        }
        
        if (useVideoOnly && bestVideoOnly != null && bestAudio != null) {
            // Separate video + audio (requires merge)
            result.videoUrl = bestVideoOnly.getContent();
            result.audioUrl = bestAudio.getContent();
            result.needsMerge = true;
            result.actualQuality = bestVideoOnly.getResolution();
            result.videoFormat = bestVideoOnly.getFormat().getSuffix();
            result.audioFormat = bestAudio.getFormat().getSuffix();
            System.out.println("📥 Direct URLs: " + result.actualQuality + " (DASH - needs merge)");
        } else if (bestMuxed != null) {
            // Combined stream (no merge needed)
            result.videoUrl = bestMuxed.getContent();
            result.audioUrl = null;
            result.needsMerge = false;
            result.actualQuality = bestMuxed.getResolution();
            result.videoFormat = bestMuxed.getFormat().getSuffix();
            result.audioFormat = null;
            System.out.println("📥 Direct URLs: " + result.actualQuality + " (muxed - no merge)");
        } else {
            throw new Exception("No suitable video stream found");
        }
        
        return result;
    }
    
    /**
     * Parse quality string to height in pixels
     */
    private int parseQuality(String quality) {
        if (quality == null || quality.equals("best")) {
            return 9999; // Will select highest available
        }
        if (quality.equals("audio")) {
            return 0;
        }
        // Parse "1080p", "720p", etc.
        Pattern pattern = Pattern.compile("(\\d+)");
        Matcher matcher = pattern.matcher(quality);
        if (matcher.find()) {
            return Integer.parseInt(matcher.group(1));
        }
        return 720; // Default
    }
    
    private int extractHeight(String resolution) {
        if (resolution == null) return 0;
        Pattern pattern = Pattern.compile("(\\d+)p");
        Matcher matcher = pattern.matcher(resolution);
        if (matcher.find()) {
            return Integer.parseInt(matcher.group(1));
        }
        return 0;
    }
}
