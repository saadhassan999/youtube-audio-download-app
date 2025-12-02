package com.example.youtube_audio_downloader

import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.content.ContextCompat
import com.fasterxml.jackson.databind.ObjectMapper
import com.fasterxml.jackson.module.kotlin.registerKotlinModule
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import com.yausername.youtubedl_android.mapper.VideoFormat
import com.yausername.youtubedl_android.mapper.VideoInfo
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.concurrent.atomic.AtomicBoolean

class NativeBridgePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var appContext: Context? = null
    private var ytChannel: MethodChannel? = null
    private var downloadChannel: MethodChannel? = null
    private val mapper: ObjectMapper by lazy { ObjectMapper().registerKotlinModule() }
    private val activityJob = SupervisorJob()
    private val ioScope = CoroutineScope(activityJob + Dispatchers.IO)
    @Volatile
    private var ytDlpInitialized = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        attachToMessenger(binding.applicationContext, binding.binaryMessenger)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        ytChannel?.setMethodCallHandler(null)
        downloadChannel?.setMethodCallHandler(null)
        ytChannel = null
        downloadChannel = null
        activityJob.cancel()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "extractBestAudio" -> {
                val idOrUrl = call.argument<String>("videoIdOrUrl")
                if (idOrUrl.isNullOrBlank()) {
                    result.error("ARG", "videoIdOrUrl required", null)
                    return
                }
                extractAsync(idOrUrl, preferDirectFile = false, result = result)
            }

            "extractBestAudioStream" -> {
                val idOrUrl = call.argument<String>("videoIdOrUrl")
                if (idOrUrl.isNullOrBlank()) {
                    result.error("ARG", "videoIdOrUrl required", null)
                    return
                }
                extractAsync(idOrUrl, preferDirectFile = false, result = result)
            }

            "extractBestAudioDownload" -> {
                val idOrUrl = call.argument<String>("videoIdOrUrl")
                if (idOrUrl.isNullOrBlank()) {
                    result.error("ARG", "videoIdOrUrl required", null)
                    return
                }
                extractAsync(idOrUrl, preferDirectFile = true, result = result)
            }

            "reinitializeYtDlp" -> {
                ioScope.launch {
                    val ok = ensureYoutubeDlInitialized(force = true)
                    withContext(Dispatchers.Main) {
                        if (ok) {
                            result.success(null)
                        } else {
                            result.error("INIT_FAIL", "yt-dlp reinit failed", null)
                        }
                    }
                }
            }

            else -> result.notImplemented()
        }
    }

    fun shutdown() {
        activityJob.cancel()
    }

    private fun attachToMessenger(context: Context, messenger: BinaryMessenger) {
        appContext = context.applicationContext
        ensureYoutubeDlInitialized(force = false)

        ytChannel = MethodChannel(messenger, YT_CHANNEL).also { channel ->
            channel.setMethodCallHandler(this)
        }

        downloadChannel = MethodChannel(messenger, DOWNLOAD_CHANNEL).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val intent = Intent(appContext, DownloadForegroundService::class.java)
                        ContextCompat.startForegroundService(context, intent)
                        result.success(null)
                    }

                    "stop" -> {
                        val intent = Intent(appContext, DownloadForegroundService::class.java)
                        context.stopService(intent)
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            }
        }

        maybeUpdateYoutubeDlAsync()
    }

    private fun extractAsync(
        idOrUrl: String,
        preferDirectFile: Boolean,
        result: MethodChannel.Result,
    ) {
        ioScope.launch {
            try {
                val info = extractBestAudioWithInitRetry(
                    idOrUrl,
                    preferDirectFile = preferDirectFile,
                )
                withContext(Dispatchers.Main) {
                    result.success(
                        mapOf(
                            "url" to info.url,
                            "mimeType" to info.mimeType,
                            "container" to info.container,
                            "bitrateKbps" to info.bitrateKbps,
                        ),
                    )
                }
            } catch (e: Exception) {
                withContext(Dispatchers.Main) {
                    result.error("EXTRACT_FAIL", e.message, null)
                }
            }
        }
    }

    private fun extractBestAudioWithInitRetry(
        idOrUrl: String,
        preferDirectFile: Boolean = false,
    ): ExtractedAudioResult {
        if (!ensureYoutubeDlInitialized(force = false)) {
            throw Exception("yt-dlp init failed")
        }
        val start = System.currentTimeMillis()
        try {
            Log.d(LOG_TAG, "[YtDlpBridge] extract start for $idOrUrl")
            val info = extractBestAudio(idOrUrl, preferDirectFile)
            Log.d(
                LOG_TAG,
                "[YtDlpBridge] extract success for $idOrUrl in ${System.currentTimeMillis() - start}ms",
            )
            return info
        } catch (e: Exception) {
            if (isInstanceNotInitialized(e)) {
                Log.w(LOG_TAG, "[YtDlpBridge] instance not initialized; reinitializing and retrying")
                val reinitOk = ensureYoutubeDlInitialized(force = true)
                if (reinitOk) {
                    val retryInfo = extractBestAudio(idOrUrl, preferDirectFile)
                    Log.d(
                        LOG_TAG,
                        "[YtDlpBridge] extract success after reinit for $idOrUrl in ${System.currentTimeMillis() - start}ms",
                    )
                    return retryInfo
                }
            }
            throw e
        }
    }

    private fun extractBestAudio(
        idOrUrl: String,
        preferDirectFile: Boolean,
    ): ExtractedAudioResult {
        val primaryRequest = YoutubeDLRequest(idOrUrl).apply {
            addOption("--dump-json")
            addOption("--skip-download")
            addOption("--no-playlist")
            addOption("--ignore-errors")
            addOption("--geo-bypass")
            addOption("--force-ipv4")
            addOption("-R", "5")
            addOption(
                "-f",
                if (preferDirectFile) {
                    "bestaudio[ext=m4a]/bestaudio[ext=webm]/bestaudio[acodec!=none]/bestaudio"
                } else {
                    "bestaudio[ext=m4a]/bestaudio[ext=webm]/bestaudio/best"
                },
            )
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

        val candidates = preferred.ifEmpty { formats }.filter { !it.url.isNullOrBlank() }

        val best = selectBestFormat(candidates, preferDirectFile)

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
        if (!ytDlpInitialized) return
        if (!updateAttempted.compareAndSet(false, true)) return
        val ctx = appContext ?: return
        Thread {
            try {
                YoutubeDL.getInstance().updateYoutubeDL(ctx)
                Log.d(LOG_TAG, "[YtDlpBridge] yt-dlp assets updated (Python/yt-dlp refreshed)")
            } catch (e: Exception) {
                Log.e(LOG_TAG, "[YtDlpBridge] yt-dlp assets update failed: ${e.message}", e)
            }
        }.start()
    }

    @Synchronized
    private fun ensureYoutubeDlInitialized(force: Boolean = false): Boolean {
        if (ytDlpInitialized && !force) {
            return true
        }
        val ctx = appContext
        if (ctx == null) {
            ytDlpInitialized = false
            return false
        }
        Log.d(LOG_TAG, "[YtDlpBridge] init start (force=$force, library 0.17.2)")
        return try {
            YoutubeDL.getInstance().init(ctx)
            ytDlpInitialized = true
            Log.d(LOG_TAG, "[YtDlpBridge] init success (Python >= 3.10, yt-dlp ready)")
            maybeUpdateYoutubeDlAsync()
            true
        } catch (e: Exception) {
            ytDlpInitialized = false
            Log.e(LOG_TAG, "[YtDlpBridge] init failed: ${e.message}", e)
            false
        }
    }

    private fun isInstanceNotInitialized(e: Exception): Boolean {
        val msg = e.message?.lowercase() ?: ""
        return msg.contains("not initialized")
    }

    private fun selectBestFormat(
        candidates: List<VideoFormat>,
        preferDirectFile: Boolean,
    ): VideoFormat? {
        if (candidates.isEmpty()) return null
        val filtered = if (preferDirectFile) {
            candidates.filterNot { format ->
                val u = format.url?.lowercase() ?: ""
                u.contains("manifest.googlevideo.com") ||
                    u.contains("playlist.m3u8") ||
                    u.contains(".m3u8") ||
                    u.contains("mime=application%2Fx-mpegurl")
            }.ifEmpty { candidates }
        } else {
            candidates
        }
        return filtered.maxByOrNull {
            when {
                it.abr > 0 -> it.abr
                it.tbr > 0 -> it.tbr
                it.asr > 0 -> it.asr
                else -> 0
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

    data class ExtractedAudioResult(
        val url: String,
        val mimeType: String,
        val container: String,
        val bitrateKbps: Int?,
    )

    companion object {
        private const val LOG_TAG = "NativeYtDlp"
        private val updateAttempted = AtomicBoolean(false)
        const val YT_CHANNEL = "yt_dlp_bridge"
        const val DOWNLOAD_CHANNEL = "download_foreground_service"
    }
}
