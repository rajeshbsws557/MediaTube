package com.example.media_tube

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var nativeDownloader: NativeDownloader? = null
    private var youtubeExtractor: YoutubeExtractor? = null
    
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        nativeDownloader = NativeDownloader(this, flutterEngine)
        youtubeExtractor = YoutubeExtractor(this, flutterEngine)
    }
    
    override fun onDestroy() {
        nativeDownloader?.dispose()
        youtubeExtractor?.dispose()
        super.onDestroy()
    }
}

