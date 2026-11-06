import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kgka_music_hl/controllers/auth_controller.dart';
import 'package:kgka_music_hl/controllers/download_controller.dart';
import 'package:kgka_music_hl/controllers/player_controller.dart';
import 'package:kgka_music_hl/core/api_client.dart';
import 'package:kgka_music_hl/models/music_models.dart';
import 'package:kgka_music_hl/services/cache_service.dart';
import 'package:kgka_music_hl/services/download_service.dart';
import 'package:kgka_music_hl/services/music_api.dart';
import 'package:kgka_music_hl/services/music_audio_handler.dart';
import 'package:kgka_music_hl/controllers/theme_controller.dart';
import 'package:kgka_music_hl/ui/pages/downloaded_songs_page.dart';
import 'package:kgka_music_hl/ui/widgets/toast.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _downloadedSong = Song(
  id: '1',
  title: '已下载的歌',
  artist: '歌手',
  hash: 'HASH_A',
);

/// 只覆盖收藏状态，其余行为沿用真实控制器。
class _FakeAuth extends AuthController {
  _FakeAuth(super.api, super.cache);

  /// 收藏顺序，等同步后收藏歌单里的次序。
  final List<String> likedOrder = [];
  final List<Song> toggledSongs = [];
  bool loggedIn = true;

  @override
  bool get isLoggedIn => loggedIn;

  @override
  bool isLiked(Song song) => likedOrder.contains(song.hash);

  @override
  List<String> get likedSongHashes => List.of(likedOrder);

  @override
  PlaylistSummary? get likedPlaylist =>
      const PlaylistSummary(id: 'fav', title: '收藏');

  @override
  Future<void> toggleLike(Song song) async {
    toggledSongs.add(song);
    if (!likedOrder.remove(song.hash)) {
      likedOrder.add(song.hash);
    }
    notifyListeners();
  }
}

class _NoopDownloadService extends DownloadService {
  @override
  Future<int> fileSize(String path) async => 1024;
}

Map<String, dynamic> _downloadIndexItem(Song song, String path) => {
  'song': song.toCache(),
  'quality': AudioQuality.lossless.apiValue,
  'filePath': path,
  'downloadedAt': '2026-11-06T12:00:00.000',
};

Future<void> _pumpPage(
  WidgetTester tester,
  _FakeAuth auth,
  DownloadController downloads, {
  PlayerController? player,
}) async {
  final api = MusicApi(
    ApiClient(client: MockClient((_) async => http.Response('{}', 200))),
  );
  final activePlayer = player ?? PlayerController(api, MusicAudioHandler());

  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: Toast.navigatorKey,
      home: DownloadedSongsPage(
        api: api,
        auth: auth,
        player: activePlayer,
        downloads: downloads,
      ),
    ),
  );
  await tester.pump();
}

/// 记录 playSong 收到的队列，不真正加载音源。
class _RecordingPlayer extends PlayerController {
  _RecordingPlayer(super.api, super.audioHandler);

  Song? lastSong;
  List<Song> lastQueue = const [];

  @override
  Future<void> playSong(
    Song song, {
    List<Song>? queue,
    bool preservePersonalFmSession = false,
    QueueOrigin? origin,
  }) async {
    lastSong = song;
    lastQueue = queue ?? const [];
    currentSong = song;
    if (queue != null && queue.isNotEmpty) {
      this.queue = queue;
    }
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DownloadController downloads;
  late _FakeAuth auth;

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.ryanheise.just_audio.methods'),
      (call) async {
        if (call.method == 'init') return {'id': 'test_id'};
        return {};
      },
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.ryanheise.audio_service.client.methods'),
      (call) async => {},
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.ryanheise.audio_service.handler.methods'),
      (call) async => {},
    );
    SharedPreferences.setMockInitialValues({
      'ka_music_downloads_index': jsonEncode([
        _downloadIndexItem(_downloadedSong, '/downloads/song.flac'),
      ]),
    });

    final api = MusicApi(ApiClient(client: MockClient((_) async => http.Response('{}', 200))));
    // LiquidGlassBackground 依赖全局 ThemeController 单例。
    ThemeController();
    downloads = DownloadController(_NoopDownloadService(), api);
    await downloads.initialize();
    auth = _FakeAuth(api, CacheService());
  });

  tearDown(() {
    downloads.dispose();
    auth.dispose();
  });

  testWidgets('未收藏的已下载歌曲显示空心收藏按钮，点击后变实心', (tester) async {
    await _pumpPage(tester, auth, downloads);

    expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget);
    expect(find.byIcon(Icons.favorite_rounded), findsNothing);
    // 行内点按即可播放，不再额外展示播放按钮。
    expect(find.byIcon(Icons.play_circle_fill_rounded), findsNothing);

    await tester.tap(find.byIcon(Icons.favorite_border_rounded));
    await tester.pump();

    expect(auth.toggledSongs.single.hash, _downloadedSong.hash);
    expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);
    expect(find.byIcon(Icons.favorite_border_rounded), findsNothing);

    // 等待收藏 Toast 的关闭定时器结束。
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('已收藏的已下载歌曲显示实心收藏按钮，点击后取消收藏', (tester) async {
    auth.likedOrder.add(_downloadedSong.hash);
    await _pumpPage(tester, auth, downloads);

    expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.favorite_rounded));
    await tester.pump();

    expect(auth.likedOrder, isEmpty);
    expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('已下载列表按收藏页的歌曲顺序展示', (tester) async {
    const first = Song(
      id: '11',
      title: '收藏第一首',
      artist: '歌手',
      hash: 'HASH_FIRST',
    );
    const second = Song(
      id: '12',
      title: '收藏第二首',
      artist: '歌手',
      hash: 'HASH_SECOND',
    );
    const uncollected = Song(
      id: '13',
      title: '未收藏下载',
      artist: '歌手',
      hash: 'HASH_OTHER',
    );

    // 下载索引里的顺序故意与收藏页相反：未收藏、第二首、第一首。
    SharedPreferences.setMockInitialValues({
      'ka_music_downloads_index': jsonEncode([
        _downloadIndexItem(uncollected, '/downloads/other.mp3'),
        _downloadIndexItem(second, '/downloads/second.flac'),
        _downloadIndexItem(first, '/downloads/first.flac'),
      ]),
    });
    final api = MusicApi(
      ApiClient(client: MockClient((_) async => http.Response('{}', 200))),
    );
    final orderedDownloads = DownloadController(_NoopDownloadService(), api);
    await orderedDownloads.initialize();
    addTearDown(orderedDownloads.dispose);

    auth.likedOrder.addAll(['HASH_FIRST', 'HASH_SECOND']);
    await _pumpPage(tester, auth, orderedDownloads);

    double topOf(String title) => tester.getTopLeft(find.text(title)).dy;
    expect(topOf('收藏第一首'), lessThan(topOf('收藏第二首')));
    expect(topOf('收藏第二首'), lessThan(topOf('未收藏下载')));
  });

  testWidgets('点击播放时整页已下载歌曲成为播放队列，其他来源的歌被清掉', (tester) async {
    const first = Song(
      id: '21',
      title: '队列第一首',
      artist: '歌手',
      hash: 'QUEUE_FIRST',
    );
    const second = Song(
      id: '22',
      title: '队列第二首',
      artist: '歌手',
      hash: 'QUEUE_SECOND',
    );
    const foreign = Song(
      id: '99',
      title: '别的歌单的歌',
      artist: '歌手',
      hash: 'QUEUE_FOREIGN',
    );

    SharedPreferences.setMockInitialValues({
      'ka_music_downloads_index': jsonEncode([
        _downloadIndexItem(second, '/downloads/second.flac'),
        _downloadIndexItem(first, '/downloads/first.flac'),
      ]),
    });
    final api = MusicApi(
      ApiClient(client: MockClient((_) async => http.Response('{}', 200))),
    );
    final queueDownloads = DownloadController(_NoopDownloadService(), api);
    await queueDownloads.initialize();
    addTearDown(queueDownloads.dispose);

    final player = _RecordingPlayer(api, MusicAudioHandler());
    addTearDown(player.dispose);
    // 进页面前正在播别的歌单。
    player.queue = const [foreign];

    // 收藏顺序：第一首、第二首，与下载索引次序相反。
    auth.likedOrder.addAll(['QUEUE_FIRST', 'QUEUE_SECOND']);

    await _pumpPage(tester, auth, queueDownloads, player: player);

    await tester.tap(find.text('队列第二首'));
    await tester.pump();

    expect(player.lastSong?.hash, second.hash);
    expect(
      player.lastQueue.map((song) => song.hash).toList(),
      [first.hash, second.hash],
    );
    expect(player.queue.any((song) => song.hash == foreign.hash), isFalse);
  });

  testWidgets('未登录时点击收藏只提示登录，不调用收藏接口', (tester) async {
    auth.loggedIn = false;
    await _pumpPage(tester, auth, downloads);

    await tester.tap(find.byIcon(Icons.favorite_border_rounded));
    await tester.pump();

    expect(auth.toggledSongs, isEmpty);
    expect(find.text('请先登录后再收藏'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
  });
}
