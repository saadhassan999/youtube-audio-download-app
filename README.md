# 🎵 YouTube Audio Downloader

A modern Flutter app to **download and play audio from YouTube channels**. 
Easily manage your favorite channels, download audio for offline listening, and enjoy a seamless playback experience with background audio, lock screen controls, and automatic background downloads.

---

## 🚀 Features

- **Channel Management:** Add, search, and manage your favorite YouTube channels.
- **Audio Download:** Download audio from YouTube videos for offline playback.
- **Download Manager:** View real-time download progress, cancel downloads, and manage completed files.
- **Audio Player:** Play downloaded audio with background playback, notification controls, and lock screen integration.
- **Background Auto-Download:** Automatically fetch and download new audios from your subscribed channels in the background.
- **Instant UI:** Fast, responsive interface with instant loading and smooth navigation.
- **Cross-Platform:** Works on Android (including Android 13, 14, and 15) and iOS (with some features).
- **Persistent Storage:** All downloads and playback positions are saved locally.
- **Permission Handling:** Handles notification and background playback permissions for modern Android.

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

1. **Add Channels:**  
   Use the main screen to add your favorite YouTube channels.

2. **Download Audio:**  
   Browse channel videos and tap the download button to save audio for offline listening.

3. **Manage Downloads:**  
   Go to the Downloads screen to view active and completed downloads. Cancel or delete as needed.

4. **Play Audio:**  
   Tap any downloaded audio to play. Use the mini player, notification panel, or lock screen controls for playback.

5. **Background Auto-Download:**  
   The app will periodically check for new videos from your channels and download audio automatically in the background (requires notification/background permissions).

---

## 📦 Dependencies

- [`just_audio`](https://pub.dev/packages/just_audio)
- [`just_audio_background`](https://pub.dev/packages/just_audio_background)
- [`youtube_explode_dart`](https://pub.dev/packages/youtube_explode_dart)
- [`sqflite`](https://pub.dev/packages/sqflite)
- [`flutter_local_notifications`](https://pub.dev/packages/flutter_local_notifications)
- [`workmanager`](https://pub.dev/packages/workmanager)
- [`permission_handler`](https://pub.dev/packages/permission_handler)
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
