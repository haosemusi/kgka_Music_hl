import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/controllers/download_controller.dart';
import 'package:kgka_music_hl/core/api_client.dart';
import 'package:kgka_music_hl/models/music_models.dart';
import 'package:kgka_music_hl/services/download_service.dart';
import 'package:kgka_music_hl/services/music_api.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeDownloadService extends DownloadService {
  _FakeDownloadService(this.fileSizes);

  final Map<String, int> fileSizes;

  @override
  Future<int> fileSize(String path) async => fileSizes[path] ?? 0;
}

class _BlockingDownloadService extends DownloadService {
  @override
  Future<int> fileSize(String path) => Completer<int>().future;
}

class _CapturingDownloadService extends DownloadService {
  _CapturingDownloadService(this.targetPath);

  final String targetPath;
  String? requestedUrl;
  String? fileExtension;
  String? fileName;

  @override
  Future<int> fileSize(String path) async => 2048;

  @override
  Future<String> download({
    required Song song,
    required AudioQuality quality,
    required String url,
    required void Function(int received, int total) onProgress,
    String? fileExtension,
  }) async {
    requestedUrl = url;
    this.fileExtension = fileExtension;
    fileName = fileNameForPublic(song, quality, fileExtension);
    return targetPath;
  }

  String fileNameForPublic(
    Song song,
    AudioQuality quality,
    String? fileExtension,
  ) => fileNameFor(song, quality, fileExtension: fileExtension);
}

http.Response jsonResponse(Object body) => http.Response(
  jsonEncode({'code': 0, 'status': 200, 'data': body}),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'downloaded file wins regardless of current quality and hash casing',
    () async {
      const downloadedSong = Song(
        id: '1',
        title: '已下载歌曲',
        artist: '歌手',
        hash: 'ABC123',
      );
      const playlistSong = Song(
        id: '1',
        title: '已下载歌曲',
        artist: '歌手',
        hash: 'abc123',
      );
      const path = '/downloads/song.flac';
      SharedPreferences.setMockInitialValues({
        'ka_music_downloads_index': jsonEncode([
          {
            'song': downloadedSong.toCache(),
            'quality': AudioQuality.lossless.apiValue,
            'filePath': path,
            'downloadedAt': '2026-10-26T12:00:00.000',
          },
        ]),
      });

      final controller = DownloadController(
        _FakeDownloadService({path: 1024}),
        MusicApi(ApiClient()),
      );

      expect(
        await controller.localPathFor(playlistSong, AudioQuality.standard),
        path,
      );
      expect(controller.isDownloaded(playlistSong), isTrue);
    },
  );

  test(
    'stalled local file lookup falls back instead of blocking playback',
    () async {
      const song = Song(
        id: '2',
        title: '旧下载歌曲',
        artist: '歌手',
        hash: 'stale-path',
      );
      SharedPreferences.setMockInitialValues({
        'ka_music_downloads_index': jsonEncode([
          {
            'song': song.toCache(),
            'quality': AudioQuality.standard.apiValue,
            'filePath': '/downloads/stalled.mp3',
            'downloadedAt': '2026-10-26T12:00:00.000',
          },
        ]),
      });

      final controller = DownloadController(
        _BlockingDownloadService(),
        MusicApi(ApiClient()),
      );

      final stopwatch = Stopwatch()..start();
      expect(
        await controller.localPathFor(song, AudioQuality.standard),
        isNull,
      );
      stopwatch.stop();
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(controller.isDownloaded(song), isTrue);
    },
  );

  test('云盘歌曲用云盘接口取下载地址并保留真实扩展名', () async {
    SharedPreferences.setMockInitialValues({});
    final requestedPaths = <String>[];
    Map<String, String>? cloudQuery;
    final api = MusicApi(
      ApiClient(
        client: MockClient((request) async {
          final path = request.url.path;
          requestedPaths.add(path);
          if (path.endsWith('/user/cloud/url')) {
            cloudQuery = request.url.queryParameters;
            return jsonResponse({
              'url': 'https://cdn.example.com/audio/歌手-云盘歌曲.mp3?sign=abc',
              'hash': 'CLOUD_HASH',
            });
          }
          return jsonResponse({'url': [], 'hash': ''});
        }),
      ),
    );
    final service = _CapturingDownloadService('/downloads/歌手-云盘歌曲.mp3');
    final controller = DownloadController(service, api);
    const cloudSong = Song(
      id: '778899',
      title: '云盘歌曲',
      artist: '歌手',
      albumAudioId: '0',
      hash: 'CLOUD_HASH',
      isCloudDrive: true,
    );

    // 当前音质是无损，但云盘里的原文件是 mp3。
    await controller.download(cloudSong, AudioQuality.lossless);

    expect(
      requestedPaths.where((path) => path.endsWith('/song/url')),
      isEmpty,
      reason: '云盘曲目不能用普通音质接口解析地址',
    );
    expect(
      requestedPaths.any((path) => path.endsWith('/user/cloud/url')),
      isTrue,
    );
    // audio_id 必须是云盘条目自身的 id，占位 0 的 album_audio_id 不能发出去。
    expect(cloudQuery?['audio_id'], '778899');
    expect(cloudQuery?.containsKey('album_audio_id'), isFalse);
    expect(service.requestedUrl, endsWith('.mp3?sign=abc'));
    expect(service.fileExtension, 'mp3');
    expect(service.fileName, '歌手-云盘歌曲.mp3');
    expect(controller.isDownloaded(cloudSong), isTrue);
  });

  test('云盘主地址为空时用备用地址，备用也没有才回退普通取址', () async {
    SharedPreferences.setMockInitialValues({});
    for (final primary in ['backup', 'fallback']) {
      final requestedPaths = <String>[];
      final api = MusicApi(
        ApiClient(
          client: MockClient((request) async {
            final path = request.url.path;
            requestedPaths.add(path);
            if (path.endsWith('/user/cloud/url')) {
              return jsonResponse(
                primary == 'backup'
                    ? {
                        'url': '',
                        'backup_url': 'https://cdn.example.com/b/云盘.mp3',
                        'hash': 'CLOUD_HASH',
                      }
                    : {'url': '', 'hash': 'CLOUD_HASH'},
              );
            }
            if (path.endsWith('/song/url')) {
              return jsonResponse({
                'url': ['https://cdn.example.com/a/云盘.mp3'],
                'hash': 'CLOUD_HASH',
              });
            }
            return jsonResponse({});
          }),
        ),
      );
      final service = _CapturingDownloadService('/downloads/cloud-$primary.mp3');
      final controller = DownloadController(service, api);
      const song = Song(
        id: '1234',
        title: '云盘歌曲',
        artist: '歌手',
        hash: 'CLOUD_HASH',
        isCloudDrive: true,
      );

      await controller.download(song, AudioQuality.lossless);

      if (primary == 'backup') {
        expect(service.requestedUrl, startsWith('https://cdn.example.com/b/'));
        expect(
          requestedPaths.where((path) => path.endsWith('/song/url')),
          isEmpty,
        );
      } else {
        expect(service.requestedUrl, startsWith('https://cdn.example.com/a/'));
        expect(
          requestedPaths.any((path) => path.endsWith('/song/url')),
          isTrue,
        );
      }
      expect(controller.isDownloaded(song), isTrue);
    }
  });

  test('普通歌曲仍按当前音质解析并且不覆盖扩展名', () async {
    SharedPreferences.setMockInitialValues({});
    final requestedPaths = <String>[];
    final api = MusicApi(
      ApiClient(
        client: MockClient((request) async {
          final path = request.url.path;
          requestedPaths.add(path);
          if (path.endsWith('/song/url')) {
            return jsonResponse({
              'url': ['https://cdn.example.com/audio/歌手-普通歌曲.flac'],
              'hash': 'PLAIN_HASH',
            });
          }
          return jsonResponse({});
        }),
      ),
    );
    final service = _CapturingDownloadService('/downloads/歌手-普通歌曲.flac');
    final controller = DownloadController(service, api);
    const plainSong = Song(
      id: '8',
      title: '普通歌曲',
      artist: '歌手',
      hash: 'PLAIN_HASH',
    );

    await controller.download(plainSong, AudioQuality.lossless);

    expect(
      requestedPaths.where((path) => path.endsWith('/user/cloud/url')),
      isEmpty,
    );
    expect(service.requestedUrl, endsWith('.flac'));
    expect(service.fileExtension, isNull);
    expect(service.fileName, '歌手-普通歌曲.flac');
    expect(controller.isDownloaded(plainSong), isTrue);
  });
}
