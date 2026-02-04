package com.mediatube.server;

import java.util.List;

/**
 * Video information extracted from YouTube
 */
public class VideoInfo {
    public String videoId;
    public String title;
    public long duration;
    public String thumbnailUrl;
    public String uploaderName;
    public List<VideoFormat> formats;
    public List<AudioFormat> audioFormats;
}
