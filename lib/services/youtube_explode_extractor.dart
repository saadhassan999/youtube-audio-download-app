import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'extractor_service.dart';

class YoutubeExplodeExtractor implements ExtractorService {
  final YoutubeExplode Function() _clientFactory;

  YoutubeExplodeExtractor({YoutubeExplode Function()? clientFactory})
    : _clientFactory = clientFactory ?? (() => YoutubeExplode());

  static const List<int> _preferredItags = [140, 251];

  @override
  Future<ExtractedAudio> getBestAudio(String videoIdOrUrl) async {
    final yt = _clientFactory();
    final rawInput = videoIdOrUrl.trim();
    final VideoId resolvedId = _resolveVideoId(rawInput);
    AudioOnlyStreamInfo? selectedStream;
    Object? lastError;

    Future<void> attemptLoad({
      List<YoutubeApiClient>? clients,
      bool requireWatchPage = true,
    }) async {
      final manifest = await yt.videos.streamsClient.getManifest(
        resolvedId,
        ytClients: clients,
        requireWatchPage: requireWatchPage,
      );
      final audioStreams = manifest.audioOnly.toList();
      if (audioStreams.isEmpty) {
        return;
      }
      selectedStream = _selectPreferred(audioStreams);
    }

    try {
      final attempts = <Future<void> Function()>[
        () => attemptLoad(),
        () => attemptLoad(clients: [YoutubeApiClient.tv]),
        () => attemptLoad(
              clients: [
                YoutubeApiClient.androidVr,
                YoutubeApiClient.android,
              ],
            ),
        () => attemptLoad(
              clients: [YoutubeApiClient.safari],
              requireWatchPage: false,
            ),
      ];

      for (final attempt in attempts) {
        try {
          await attempt();
          if (selectedStream != null) {
            break;
          }
        } catch (e) {
          lastError = e;
        }
      }

      if (selectedStream == null) {
        if (lastError != null) {
          throw Exception(
            'No audio streams available for $rawInput (Last error: $lastError)',
          );
        }
        throw Exception('No audio streams available for $rawInput');
      }

      return ExtractedAudio(
        url: selectedStream!.url.toString(),
        mimeType: selectedStream!.codec.mimeType,
        bitrateKbps: selectedStream!.bitrate.kiloBitsPerSecond.round(),
        container: selectedStream!.container.name,
      );
    } finally {
      yt.close();
    }
  }

  VideoId _resolveVideoId(String input) {
    final trimmed = input.trim();
    final parsed = VideoId.parseVideoId(trimmed);
    if (parsed != null) {
      return VideoId(parsed);
    }
    String decoded = trimmed;
    try {
      decoded = Uri.decodeComponent(trimmed);
      if (decoded != trimmed) {
        final decodedParsed = VideoId.parseVideoId(decoded);
        if (decodedParsed != null) {
          return VideoId(decodedParsed);
        }
      }
    } catch (_) {}
    return VideoId(trimmed);
  }

  AudioOnlyStreamInfo _selectPreferred(List<AudioOnlyStreamInfo> streams) {
    for (final itag in _preferredItags) {
      for (final stream in streams) {
        if (stream.tag == itag) {
          return stream;
        }
      }
    }
    streams.sort((a, b) => b.bitrate.compareTo(a.bitrate));
    return streams.first;
  }
}
