# 🎵 YouTube Audio Downloader

A modern Flutter app to **download and play audio from YouTube channels**. 
Easily manage your favorite channels, download audio for offline listening, and enjoy a seamless playback experience with background audio, lock screen controls, and automatic background downloads.

---

## 🚀 Features

- **Unified Search:** Look up YouTube channels *and* individual videos from the same search bar using names, URLs, or raw IDs.
- **Saved Videos Hub:** Save any suggested video for quick access, stream instantly, download later, or remove it when you're done.
- **Channel Management:** Add, search, and manage your favorite YouTube channels to keep new uploads in one place.
- **Audio Download:** Download audio from YouTube videos for offline playback with automatic retry and resume.
- **Download Manager:** View real-time download progress, cancel downloads, and manage completed files.
- **Audio Player:** Play downloaded audio with background playback, notification controls, and lock screen integration.
- **Background Auto-Download:** Automatically fetch and download new audios from your subscribed channels in the background.
- **Instant UI:** Fast, responsive interface with instant loading and smooth navigation.
- **Cross-Platform:** Works on Android (including Android 13, 14, and 15) and iOS (with some features).
- **Persistent Storage:** Saved videos, downloads, and playback positions are stored locally.
- **Adaptive Theme Toggle:** Pick between Material 3 light and dark themes right from the drawer—the app restyles instantly and remembers your choice across launches.
- **Permission Handling:** Handles notification and background playback permissions for modern Android.
- **Offline Awareness:** Detects when the device is offline, surfaces a banner, and lets you refresh the moment connectivity returns.

---

## 📲 Installation

### Prerequisites

- [Flutter SDK](https://flutter.dev/docs/get-started/install)
- Android Studio or Xcode (for iOS)
- A device or emulator

### Steps

1. **Clone the repository:**
   ```sh
   git clone https://github.com/saadhassan999/youtube-audio-download-app.git
   cd youtube-audio-download-app
   ```

2. **Install dependencies:**
   ```sh
   flutter pub get
   ```

3. **Run the app:**
   ```sh
   flutter run
   ```

4. **(Android 13+):**  
   Grant notification permissions when prompted for full media controls.

---

## 🛠️ Usage

1. **Search Channels or Videos:**  
   Use the search bar on the home screen to find channels or individual videos by name, URL, or ID. Tap a video to save it for later.

2. **Add Channels:**  
   When you tap a channel suggestion (or paste a channel link), it will be added to your channel list.

3. **Saved Videos:**  
   The Saved Videos section collects every video you store from search. Stream immediately, download when you’re ready, or remove it with one tap. A small loading spinner appears while a remove/download action is in progress so you can see what’s happening.

4. **Download Audio:**  
   Browse channel videos or your saved list and tap the download button to save audio for offline listening.

5. **Manage Downloads:**  
   Go to the Downloads screen to view active and completed downloads. Cancel or delete as needed.

6. **Play Audio:**  
   Tap any downloaded audio to play. Use the mini player, notification panel, or lock screen controls for playback.

7. **Background Auto-Download:**  
   The app will periodically check for new videos from your channels and download audio automatically in the background (requires notification/background permissions).

8. **Offline Banner & Refresh:**  
   If you lose connection, an in-app banner reminds you you’re offline—once you’re back online, pull down on the home screen to reload channel and saved video data.

---

## 📦 Dependencies

- [`just_audio`](https://pub.dev/packages/just_audio)
- [`just_audio_background`](https://pub.dev/packages/just_audio_background)
- [`youtube_explode_dart`](https://pub.dev/packages/youtube_explode_dart)
- [`sqflite`](https://pub.dev/packages/sqflite)
- [`flutter_local_notifications`](https://pub.dev/packages/flutter_local_notifications)
- [`workmanager`](https://pub.dev/packages/workmanager)
- [`permission_handler`](https://pub.dev/packages/permission_handler)
- [`provider`](https://pub.dev/packages/provider)
- [`url_launcher`](https://pub.dev/packages/url_launcher)
- ...and more (see [`pubspec.yaml`](pubspec.yaml))

---

## 🤝 Contributing

Contributions, issues, and feature requests are welcome!  
Feel free to open an issue or submit a pull request.

---

## 📄 License

This project is licensed under the MIT License.

---

> **Developed by [saadhassan999](https://github.com/saadhassan999)**
