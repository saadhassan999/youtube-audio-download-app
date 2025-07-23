# YouTube API Setup Guide

## Overview
The app now supports searching for YouTube channels by name with auto-suggestions. For the best experience, you can optionally set up a YouTube Data API key.

## Option 1: Use Web Scraping (Default - No Setup Required)
The app works out of the box using web scraping to search for channels. This doesn't require any API key but may have some limitations.

## Option 2: Use YouTube Data API (Recommended - Better Results)

### Step 1: Get a YouTube Data API Key
1. Go to the [Google Cloud Console](https://console.cloud.google.com/)
2. Create a new project or select an existing one
3. Enable the YouTube Data API v3:
   - Go to "APIs & Services" > "Library"
   - Search for "YouTube Data API v3"
   - Click on it and press "Enable"
4. Create credentials:
   - Go to "APIs & Services" > "Credentials"
   - Click "Create Credentials" > "API Key"
   - Copy the generated API key

### Step 2: Add the API Key to the App
1. Open `lib/services/youtube_service.dart`
2. Replace `YOUR_YOUTUBE_API_KEY` with your actual API key:
   ```dart
   static const String _apiKey = 'YOUR_ACTUAL_API_KEY_HERE';
   ```

### Benefits of Using the API
- More accurate search results
- Channel thumbnails and descriptions
- Better performance
- No rate limiting issues

### API Quota
The YouTube Data API has a free quota of 10,000 units per day, which is sufficient for most users. Each search request uses about 100 units.

## Features
With the search functionality, users can now:
- Type channel names (e.g., "PewDiePie", "MrBeast")
- See real-time suggestions as they type
- Click on suggestions to add channels instantly
- Still use manual URL/ID entry as a fallback

## Troubleshooting
- If you don't have an API key, the app will automatically use web scraping
- If search isn't working, check your internet connection
- For API errors, verify your API key is correct and the YouTube Data API is enabled 