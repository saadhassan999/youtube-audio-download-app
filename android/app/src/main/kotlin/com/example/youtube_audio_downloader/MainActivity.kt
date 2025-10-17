package com.example.youtube_audio_downloader

import android.content.Intent
import androidx.core.content.ContextCompat
import com.fasterxml.jackson.databind.ObjectMapper
import com.fasterxml.jackson.module.kotlin.registerKotlinModule
import com.ryanheise.audioservice.AudioServiceActivity
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import com.yausername.youtubedl_android.mapper.VideoFormat
import com.yausername.youtubedl_android.mapper.VideoInfo
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {

    private val channelName = "yt_dlp_bridge"
    private val downloadChannelName = "download_foreground_service"
    private val mapper: ObjectMapper by lazy { ObjectMapper().registerKotlinModule() }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        try {
            YoutubeDL.getInstance().init(applicationContext)
        } catch (_: Exception) {
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "extractBestAudio" -> {
                        val idOrUrl = call.argument<String>("videoIdOrUrl")
                        if (idOrUrl.isNullOrBlank()) {
                            result.error("ARG", "videoIdOrUrl required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val info = extractBestAudio(idOrUrl)
                            result.success(
                                mapOf(
                                    "url" to info.url,
                                    "mimeType" to info.mimeType,
                                    "container" to info.container,
                                    "bitrateKbps" to info.bitrateKbps
                                )
                            )
                        } catch (e: Exception) {
                            result.error("EXTRACT_FAIL", e.message, null)
                        }
                    }

                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, downloadChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val intent = Intent(this, DownloadForegroundService::class.java)
                        ContextCompat.startForegroundService(this, intent)
                        result.success(null)
                    }

                    "stop" -> {
                        val intent = Intent(this, DownloadForegroundService::class.java)
                        stopService(intent)
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            }
        maybeUpdateYoutubeDlAsync()
    }

    private fun extractBestAudio(idOrUrl: String): ExtractedAudioResult {
        ensureYoutubeDlUpdated()

        val primaryRequest = YoutubeDLRequest(idOrUrl).apply {
            addOption("--dump-json")
            addOption("--skip-download")
            addOption("--no-playlist")
            addOption("--ignore-errors")
            addOption("--geo-bypass")
            addOption("--force-ipv4")
            addOption("-R", "5")
            addOption("-f", "bestaudio[ext=m4a]/bestaudio[ext=webm]/bestaudio/best")
        }

        val infoViaApi = try {
            YoutubeDL.getInstance().getInfo(
                YoutubeDLRequest(idOrUrl).apply {
                    addOption("--no-playlist")
                    addOption("--ignore-errors")
                    addOption("--geo-bypass")
                    addOption("--force-ipv4")
                    addOption("-R", "5")
                    addOption("-f", "bestaudio[ext=m4a]/bestaudio[ext=webm]/bestaudio/best")
                    addOption("--simulate")
                },
            )
        } catch (_: Exception) {
            null
        }

        val info = fetchVideoInfo(primaryRequest)
            ?: throw Exception("yt-dlp returned empty metadata for $idOrUrl")

        val formats = mutableListOf<VideoFormat>().apply {
            info.requestedFormats?.let { addAll(it) }
            info.formats?.let { addAll(it) }
        }

        val preferred = formats.filter {
            val url = it.url
            val vcodec = it.vcodec ?: "none"
            val acodec = it.acodec ?: "none"
            !url.isNullOrBlank() && (vcodec.equals("none", true) || !acodec.equals("none", true))
        }

        val best = preferred.ifEmpty { formats }.filter { !it.url.isNullOrBlank() }.maxByOrNull {
            when {
                it.abr > 0 -> it.abr
                it.tbr > 0 -> it.tbr
                it.asr > 0 -> it.asr
                else -> 0
            }
        }

        var directUrl = best?.url ?: infoViaApi?.url ?: info.url

        if (directUrl.isNullOrBlank()) {
            val fallbackRequest = YoutubeDLRequest(idOrUrl).apply {
                addOption("--no-playlist")
                addOption("--ignore-errors")
                addOption("--geo-bypass")
                addOption("--force-ipv4")
                addOption("-R", "5")
                addOption("-f", "bestaudio[acodec!=none]/bestaudio")
                addOption("--get-url")
            }
            val fallbackResponse = YoutubeDL.getInstance().execute(fallbackRequest).out
            directUrl = fallbackResponse
                ?.lineSequence()
                ?.map { it.trim() }
                ?.firstOrNull { it.startsWith("http") }
        }

        if (directUrl.isNullOrBlank()) {
            throw Exception("No audio streams available for $idOrUrl")
        }

        val container = best?.ext
            ?: info.ext
            ?: guessContainerFromUrl(directUrl)
            ?: "m4a"

        val mimeType = when (container.lowercase()) {
            "m4a", "mp4" -> "audio/mp4"
            "webm", "weba" -> "audio/webm"
            "mp3" -> "audio/mpeg"
            else -> "audio/mp4"
        }

        val bitrate = best?.abr?.takeIf { it > 0 }
            ?: best?.tbr?.takeIf { it > 0 }
            ?: best?.asr?.takeIf { it > 0 }

        return ExtractedAudioResult(
            url = directUrl,
            mimeType = mimeType,
            container = container,
            bitrateKbps = bitrate,
        )
    }

    private fun fetchVideoInfo(request: YoutubeDLRequest): VideoInfo? {
        val response = YoutubeDL.getInstance().execute(request)
        val json = response.out?.trim()
        if (json.isNullOrEmpty()) {
            return null
        }
        return mapper.readValue(json, VideoInfo::class.java)
    }

    private fun maybeUpdateYoutubeDlAsync() {
        if (updateAttempted.get()) return
        Thread {
            ensureYoutubeDlUpdated()
        }.start()
    }

    private fun ensureYoutubeDlUpdated() {
        if (updateAttempted.compareAndSet(false, true)) {
            try {
                YoutubeDL.getInstance().updateYoutubeDL(applicationContext)
            } catch (_: Exception) {
            }
        }
    }

    private fun guessContainerFromUrl(url: String): String? {
        val lower = url.lowercase()
        return when {
            lower.contains(".m4a") -> "m4a"
            lower.contains(".mp3") -> "mp3"
            lower.contains(".webm") || lower.contains(".weba") -> "webm"
            lower.contains("mime=audio%2Fwebm") -> "webm"
            lower.contains("mime=audio%2Fmp4") -> "m4a"
            else -> null
        }
    }

    private data class ExtractedAudioResult(
        val url: String,
        val mimeType: String,
        val container: String,
        val bitrateKbps: Int?
    )

    companion object {
        private val updateAttempted = java.util.concurrent.atomic.AtomicBoolean(false)
    }
}
