import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kgka_music_hl/controllers/auth_controller.dart';
import 'package:kgka_music_hl/controllers/player_controller.dart';
import 'package:kgka_music_hl/controllers/theme_controller.dart';
import 'package:kgka_music_hl/core/api_client.dart';
import 'package:kgka_music_hl/models/music_models.dart';
import 'package:kgka_music_hl/services/cache_service.dart';
import 'package:kgka_music_hl/services/music_api.dart';
import 'package:kgka_music_hl/services/music_audio_handler.dart';
import 'package:kgka_music_hl/ui/pages/playlist_detail_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response jsonResponse(Object body) => http.Response(
  jsonEncode({'code': 0, 'status': 200, 'data': body}),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

/// 收藏歌单：接口总数 5 首，其中 2 条没有 hash（收藏失败或已下架），
/// 列表里实际只有 3 首。
Map<String, dynamic> trackJson(int index) => {
  'fileid': 9000 + index,
  'hash': 'LIKED_HASH_$index',
  'name': '收藏歌曲 $index',
  'timelen': 180000,
  'singers': [
    {'name': '歌手', 'singerid': 7, 'sid': 7},
  ],
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
    SharedPreferences.setMockInitialValues({});
    ThemeController();
  });

  testWidgets('收藏歌单顶部数量与列表实际条数一致', (tester) async {
    final api = MusicApi(
      ApiClient(
        client: MockClient((request) async {
          final path = request.url.path;
          if (path.endsWith('/playlist/detail')) {
            // 详情接口不带 is_def，且 count 把无效条目也算进来。
            return jsonResponse({
              'listid': 77,
              'global_collection_id': 88,
              'name': '收藏',
              'count': 5,
            });
          }
          if (path.endsWith('/playlist/track/all')) {
            return jsonResponse({
              'count': 5,
              'songs': [
                trackJson(1),
                trackJson(2),
                trackJson(3),
                {'fileid': 9100, 'name': '已下架歌曲'},
                {'fileid': 9101, 'name': '收藏失败的歌曲', 'hash': ''},
              ],
            });
          }
          return jsonResponse({});
        }),
      ),
    );
    final auth = AuthController(api, CacheService())
      ..session = const LoginSession(userId: '9', token: 'tk', t1: 't1')
      ..playlists = const [
        PlaylistSummary(
          id: '88',
          listId: '77',
          title: '收藏',
          isDefault: 2,
          songCount: 5,
        ),
      ];
    addTearDown(auth.dispose);
    final player = PlayerController(api, MusicAudioHandler());
    addTearDown(player.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: PlaylistDetailPage(
          api: api,
          auth: auth,
          player: player,
          playlist: auth.playlists.first,
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.textContaining('5 首歌'), findsNothing);
    expect(find.textContaining('3 首歌'), findsWidgets);
    expect(find.text('收藏歌曲 1'), findsOneWidget);
    expect(find.text('已下架歌曲'), findsNothing);
  });
}
