# 🎵 YouTube Audio Downloader

A modern Flutter app to **download and listen to audio from YouTube channels and videos**.
Build your own audio library by adding channels via handle or link, automatically fetch new uploads, download audio for offline listening, and enjoy smooth background playback with lock-screen controls.

## 🚀 Features

### 🔎 Add & Discover (Stay Inside the App)

* **Add channels by handle or link**
  Paste `@handle` or a YouTube channel URL to add a channel directly.
* **Add individual videos by link**
  Paste a YouTube video URL or ID to save it for streaming or download.
* **Optional keyword search (API-powered)**
  Enable or disable YouTube API search directly from the app drawer.
  When disabled, all core features continue to work without API usage.

### 📺 Channel Library

* **Saved channels list with avatars**
* **Browse recent uploads per channel**
  Channel feeds load recent uploads using YouTube RSS (quota-free).
* **Fast cached loading**
  Recently loaded channel uploads are cached locally for instant display and offline viewing.
* **Manual refresh support**
* **Duplicate protection**
  Channels already added cannot be added again.

### 🎧 Offline Audio & Downloads

* **Download audio for offline listening**
* **Resumable downloads**
  Downloads automatically resume after interruptions or app restarts.
* **Download manager**

  * Live progress
  * Cancel active downloads
  * Delete completed files
* **Repair orphaned files**
  Detects audio files on disk and restores them into the app when possible.

### ▶️ Audio Player

* **Stream or play downloaded audio**
* **Mini player across the app**
* **Lock-screen & notification controls**
* **10-second rewind / forward**
* **Playback speed control**
* **Next / previous through downloaded queue**
* **Remembers playback position**
  Continues exactly where you left off.

### 🔔 Background & Notifications (Android)

* **Automatic background checks for new uploads**
* **Auto-download newest channel uploads**
* **Notifications when new audio is ready**
* **Android 13+ notification permission handling**

### 💾 Local-First & Reliable

* **All data stored locally**

  * Channels
  * Saved videos
  * Downloads
  * Playback state
* **Works offline**
  Cached channel uploads and downloaded audio remain accessible.
* **Offline awareness**
  Displays an offline banner and refreshes automatically when connectivity returns.

### 🎨 Settings & UI

* **Material 3 design**
* **Light / Dark theme toggle**
* **Enable / Disable API search from the app drawer**
* **Support / contact shortcut**

## 📲 Installation

### Prerequisites

* [Flutter SDK](https://flutter.dev/docs/get-started/install)
* Android Studio or Xcode
* Android or iOS device/emulator

### Steps

1. **Clone the repository**

   ```sh
   git clone https://github.com/saadhassan999/youtube-audio-download-app.git
   cd youtube-audio-download-app
   ```

2. **Install dependencies**

   ```sh
   flutter pub get
   ```

3. **(Optional) Provide a YouTube Data API key**
   Required **only if you enable API search**.

   ```sh
   flutter run --dart-define=YOUTUBE_API_KEY=YOUR_KEY_HERE
   ```

4. **Run the app**

   ```sh
   flutter run
   ```

5. **Android 13+**
   Grant notification permission when prompted for background playback and downloads.

## 🛠️ Usage

1. **Add channels or videos**

   * Paste `@handle`, channel link, or video link using the Add button.
2. **Browse channel uploads**

   * Expand a channel to see recent uploads (cached and offline-friendly).
3. **Download audio**

   * Tap download on any video to save it for offline playback.
4. **Manage downloads**

   * View progress, cancel, delete, or repair files from the Downloads screen.
5. **Play audio**

   * Use mini player, notification controls, or lock screen.
6. **Background auto-download**

   * New channel uploads are checked periodically and downloaded automatically.
7. **Toggle API search**

   * Enable or disable API-powered keyword search directly from the drawer.

## 📦 Dependencies

* `just_audio`
* `just_audio_background`
* `youtube_explode_dart`
* `sqflite`
* `flutter_local_notifications`
* `workmanager`
* `permission_handler`
* `provider`
* `url_launcher`
* *(see pubspec.yaml for full list)*


## 🤝 Contributing

Issues, feedback, and pull requests are welcome.


## 📄 License

MIT License


> **Developed by [saadhassan999](https://github.com/saadhassan999)**
