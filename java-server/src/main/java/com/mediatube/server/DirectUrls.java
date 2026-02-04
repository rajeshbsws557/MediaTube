package com.mediatube.server;

/**
 * Response class containing direct download URLs
 * The app uses these URLs to download directly from YouTube's CDN
 */
public class DirectUrls {
    public String videoId;
    public String title;
    public String videoUrl;
    public String audioUrl;
    public boolean needsMerge;
    public String actualQuality;
    public String videoFormat;
    public String audioFormat;
}
