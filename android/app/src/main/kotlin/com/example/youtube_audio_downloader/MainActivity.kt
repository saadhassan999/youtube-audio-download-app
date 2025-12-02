package com.example.youtube_audio_downloader

import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : AudioServiceActivity() {
    private var nativeBridgePlugin: NativeBridgePlugin? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        nativeBridgePlugin = NativeBridgePlugin().also {
            flutterEngine.plugins.add(it)
        }
    }

    override fun onDestroy() {
        nativeBridgePlugin?.shutdown()
        nativeBridgePlugin = null
        super.onDestroy()
    }
}
