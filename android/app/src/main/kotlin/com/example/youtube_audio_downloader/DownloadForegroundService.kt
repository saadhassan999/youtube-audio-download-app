package com.example.youtube_audio_downloader

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

class DownloadForegroundService : Service() {

    companion object {
        const val CHANNEL_ID = "yt_audio_download_channel"
        const val CHANNEL_NAME = "Audio Downloads"
        const val NOTIFICATION_ID = 2001
        const val ACTION_STOP = "com.example.youtube_audio_downloader.ACTION_STOP"
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopForeground(true)
            stopSelf()
            return START_NOT_STICKY
        }
        val notification = buildNotification()
        startForeground(NOTIFICATION_ID, notification)
        return START_STICKY
    }

    override fun onDestroy() {
        stopForeground(true)
        super.onDestroy()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps audio downloads running in the background."
                setShowBadge(false)
            }
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val launchIntent = packageManager?.getLaunchIntentForPackage(packageName)
        val contentIntent = if (launchIntent != null) {
            PendingIntent.getActivity(
                this,
                0,
                launchIntent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
        } else {
            null
        }

        val stopIntent = Intent(this, DownloadForegroundService::class.java).apply {
            action = ACTION_STOP
        }
        val stopPendingIntent = PendingIntent.getService(
            this,
            1,
            stopIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Downloading audio")
            .setContentText("Audio downloads will continue in the background.")
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .setSilent(true)
            .setContentIntent(contentIntent)
            .addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "Stop",
                stopPendingIntent
            )
            .build()
    }
}
