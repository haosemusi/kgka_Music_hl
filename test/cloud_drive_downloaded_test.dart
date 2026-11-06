import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kgka_music_hl/controllers/auth_controller.dart';
import 'package:kgka_music_hl/controllers/download_controller.dart';
import 'package:kgka_music_hl/controllers/player_controller.dart';
import 'package:kgka_music_hl/controllers/theme_controller.dart';
import 'package:kgka_music_hl/core/api_client.dart';
import 'package:kgka_music_hl/models/music_models.dart';
import 'package:kgka_music_hl/services/cache_service.dart';
import 'package:kgka_music_hl/services/download_service.dart';
import 'package:kgka_music_hl/services/music_api.dart';
import 'package:kgka_music_hl/services/music_audio_handler.dart';
import 'package:kgka_music_hl/ui/pages/cloud_drive_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _NoopDownloadService extends DownloadService {
  @override
  Future<int> fileSize(String path) async => 2048;
}

Map<String, dynamic> cloudItem({
  required String hash,
  required String name,
  required int audioId,
}) => {
  'name': name,
  'hash': hash,
  'audio_id': audioId,
  'album_audio_id': 0,
  'author_name': '歌手',
  'timelen': 180000,
  'size': 4096,
  'bitrate': 0,
  'ext': 'mp3',
  'add_time': 1762000000,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
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
    // LiquidGlassBackground 依赖全局 ThemeController 单例。
    ThemeController();
  });

  testWidgets('云盘列表给已下载歌曲显示绿色勾，未下载的不显示', (tester) async {
    SharedPreferences.setMockInitialValues({
      'ka_music_downloads_index': jsonEncode([
        {
          'song': const Song(
            id: '1001',
            title: '已下载的云盘歌',
            artist: '歌手',
            hash: 'DOWNLOADED_HASH',
            isCloudDrive: true,
          ).toCache(),
          'quality': AudioQuality.lossless.apiValue,
          'filePath': '/downloads/已下载的云盘歌.mp3',
          'downloadedAt': '2026-11-06T12:00:00.000',
        },
      ]),
    });

    final api = MusicApi(
      ApiClient(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/user/cloud')) {
            return http.Response(
              jsonEncode({
                'code': 0,
                'data': {
                  'list_count': 2,
                  'list': [
                    cloudItem(
                      hash: 'DOWNLOADED_HASH',
                      name: '已下载的云盘歌.mp3',
                      audioId: 1001,
                    ),
                    cloudItem(
                      hash: 'OTHER_HASH',
                      name: '没下载的云盘歌.mp3',
                      audioId: 1002,
                    ),
                  ],
                },
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          return http.Response('{}', 200, headers: {
            'content-type': 'application/json; charset=utf-8',
          });
        }),
      ),
    );
    final downloads = DownloadController(_NoopDownloadService(), api);
    await downloads.initialize();
    addTearDown(downloads.dispose);

    final player = PlayerController(api, MusicAudioHandler());
    player.downloadController = downloads;
    final auth = AuthController(api, CacheService());
    addTearDown(auth.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: CloudDrivePage(api: api, auth: auth, player: player),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('已下载的云盘歌'), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
  });
}
