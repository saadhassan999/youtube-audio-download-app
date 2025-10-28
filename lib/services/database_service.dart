import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/channel.dart';
import '../models/audio_file.dart';
import '../models/playlist.dart';
import '../models/downloaded_video.dart';
import '../utils/constants.dart';
import 'package:synchronized/synchronized.dart';
import '../models/saved_video.dart';

class DatabaseService {
  static final DatabaseService instance = DatabaseService._init();
  static Database? _db;
  DatabaseService._init();
  static final Lock _dbLock = Lock();

  Future<Database> get db async {
    if (_db != null) return _db!;
    _db = await _initDB();
    return _db!;
  }

  Future<Database> _initDB() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, kAppDbName);
    return await openDatabase(
      path,
      version: 4,
      onCreate: _createDB,
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('''
            CREATE TABLE downloaded_videos (
              videoId TEXT PRIMARY KEY,
              title TEXT,
              filePath TEXT,
              size INTEGER,
              duration INTEGER,
              channelName TEXT,
              thumbnailUrl TEXT,
              downloadedAt TEXT,
              status TEXT
            )
          ''');
        }
        if (oldVersion < 3) {
          // Add new columns to channels table
          await db.execute('ALTER TABLE channels ADD COLUMN description TEXT DEFAULT ""');
          await db.execute('ALTER TABLE channels ADD COLUMN thumbnailUrl TEXT DEFAULT ""');
        }
        if (oldVersion < 4) {
          await _createSavedVideosTable(db);
        }
      },
    );
  }

  Future _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE channels (
        id TEXT PRIMARY KEY,
        name TEXT,
        description TEXT,
        thumbnailUrl TEXT,
        lastVideoId TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE playlists (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE audio_files (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT,
        channelName TEXT,
        filePath TEXT,
        videoId TEXT,
        playlistId INTEGER,
        FOREIGN KEY (playlistId) REFERENCES playlists(id)
      )
    ''');
    await db.execute('''
      CREATE TABLE downloaded_videos (
        videoId TEXT PRIMARY KEY,
        title TEXT,
        filePath TEXT,
        size INTEGER,
        duration INTEGER,
        channelName TEXT,
        thumbnailUrl TEXT,
        downloadedAt TEXT,
        status TEXT
      )
    ''');
    await _createSavedVideosTable(db);
  }

  Future<void> _createSavedVideosTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS saved_videos (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        videoId TEXT NOT NULL,
        title TEXT NOT NULL,
        channelId TEXT NOT NULL,
        channelTitle TEXT NOT NULL,
        durationMs INTEGER,
        thumbnailUrl TEXT,
        publishedAt TEXT,
        savedAtUtc TEXT NOT NULL,
        status TEXT NOT NULL,
        localPath TEXT,
        bytesTotal INTEGER,
        bytesDownloaded INTEGER,
        UNIQUE(videoId)
      )
    ''');
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_saved_videos_video_id ON saved_videos(videoId)',
    );
  }

  // Channel CRUD
  @pragma('vm:entry-point')
  Future<void> addChannel(Channel channel) async {
    final dbClient = await db;
    await dbClient.insert('channels', channel.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @pragma('vm:entry-point')
  Future<List<Channel>> getChannels() async {
    final dbClient = await db;
    final maps = await dbClient.query('channels');
    return maps.map((e) => Channel.fromMap(e)).toList();
  }

  @pragma('vm:entry-point')
  Future<void> deleteChannel(String id) async {
    final dbClient = await db;
    await dbClient.delete('channels', where: 'id = ?', whereArgs: [id]);
  }

  @pragma('vm:entry-point')
  Future<void> updateChannel(Channel channel) async {
    final dbClient = await db;
    await dbClient.update('channels', channel.toMap(), where: 'id = ?', whereArgs: [channel.id]);
  }

  // AudioFile CRUD
  @pragma('vm:entry-point')
  Future<void> addAudioFile(AudioFile audioFile) async {
    final dbClient = await db;
    await dbClient.insert('audio_files', audioFile.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @pragma('vm:entry-point')
  Future<List<AudioFile>> getAudioFiles() async {
    final dbClient = await db;
    final maps = await dbClient.query('audio_files');
    return maps.map((e) => AudioFile.fromMap(e)).toList();
  }

  @pragma('vm:entry-point')
  Future<void> deleteAudioFile(int id) async {
    final dbClient = await db;
    await dbClient.delete('audio_files', where: 'id = ?', whereArgs: [id]);
  }

  // Playlist CRUD
  @pragma('vm:entry-point')
  Future<int> addPlaylist(Playlist playlist) async {
    final dbClient = await db;
    return await dbClient.insert('playlists', playlist.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @pragma('vm:entry-point')
  Future<List<Playlist>> getPlaylists() async {
    final dbClient = await db;
    final maps = await dbClient.query('playlists');
    return maps.map((e) => Playlist.fromMap(e)).toList();
  }

  @pragma('vm:entry-point')
  Future<void> deletePlaylist(int id) async {
    final dbClient = await db;
    await dbClient.delete('playlists', where: 'id = ?', whereArgs: [id]);
  }

  @pragma('vm:entry-point')
  Future<void> updatePlaylist(Playlist playlist) async {
    final dbClient = await db;
    await dbClient.update('playlists', playlist.toMap(), where: 'id = ?', whereArgs: [playlist.id]);
  }

  @pragma('vm:entry-point')
  Future<void> addDownloadedVideo(DownloadedVideo video) async {
    await _dbLock.synchronized(() async {
      final dbClient = await db;
      await dbClient.insert('downloaded_videos', video.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  @pragma('vm:entry-point')
  Future<DownloadedVideo?> getDownloadedVideo(String videoId) async {
    return await _dbLock.synchronized(() async {
      final dbClient = await db;
      final maps = await dbClient.query('downloaded_videos', where: 'videoId = ?', whereArgs: [videoId]);
      if (maps.isNotEmpty) {
        return DownloadedVideo.fromMap(maps.first);
      }
      return null;
    });
  }

  @pragma('vm:entry-point')
  Future<List<DownloadedVideo>> getDownloadedVideos() async {
    print('[DatabaseService] getDownloadedVideos() called');
    return await _dbLock.synchronized(() async {
      print('[DatabaseService] getDownloadedVideos() lock acquired');
      final dbClient = await db;
      final maps = await dbClient.query('downloaded_videos', orderBy: 'downloadedAt DESC');
      print('[DatabaseService] getDownloadedVideos() query returned ${maps.length} rows');
      return maps.map((e) => DownloadedVideo.fromMap(e)).toList();
    });
  }

  @pragma('vm:entry-point')
  Future<void> deleteDownloadedVideo(String videoId) async {
    await _dbLock.synchronized(() async {
      final dbClient = await db;
      await dbClient.delete('downloaded_videos', where: 'videoId = ?', whereArgs: [videoId]);
    });
  }

  Future<void> upsertSavedVideo(SavedVideo video) async {
    await _dbLock.synchronized(() async {
      final dbClient = await db;
      await dbClient.insert(
        'saved_videos',
        video.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  Future<SavedVideo?> getSavedVideo(String videoId) async {
    return await _dbLock.synchronized(() async {
      final dbClient = await db;
      final maps = await dbClient.query(
        'saved_videos',
        where: 'videoId = ?',
        whereArgs: [videoId],
        limit: 1,
      );
      if (maps.isNotEmpty) {
        return SavedVideo.fromMap(maps.first);
      }
      return null;
    });
  }

  Future<List<SavedVideo>> getSavedVideos() async {
    return await _dbLock.synchronized(() async {
      final dbClient = await db;
      final maps = await dbClient.query(
        'saved_videos',
        orderBy: 'savedAtUtc DESC',
      );
      return maps.map(SavedVideo.fromMap).toList(growable: false);
    });
  }

  Future<void> updateSavedVideoFields(
    String videoId,
    Map<String, Object?> values,
  ) async {
    if (values.isEmpty) return;
    await _dbLock.synchronized(() async {
      final dbClient = await db;
      await dbClient.update(
        'saved_videos',
        values,
        where: 'videoId = ?',
        whereArgs: [videoId],
      );
    });
  }

  Future<void> deleteSavedVideo(String videoId) async {
    await _dbLock.synchronized(() async {
      final dbClient = await db;
      await dbClient.delete(
        'saved_videos',
        where: 'videoId = ?',
        whereArgs: [videoId],
      );
    });
  }

  Future close() async {
    final dbClient = await db;
    dbClient.close();
  }
}
