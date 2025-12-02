package com.example.youtube_audio_downloader

import android.app.Application
import dev.fluttercommunity.workmanager.BackgroundWorker
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugins.GeneratedPluginRegistrant

class DownloadApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        BackgroundWorker.pluginRegistrant = { engine: FlutterEngine ->
            GeneratedPluginRegistrant.registerWith(engine)
            engine.plugins.add(NativeBridgePlugin())
        }
    }
}
