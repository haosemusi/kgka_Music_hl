import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kgka_music_hl/controllers/auth_controller.dart';
import 'package:kgka_music_hl/core/api_client.dart';
import 'package:kgka_music_hl/models/music_models.dart';
import 'package:kgka_music_hl/services/cache_service.dart';
import 'package:kgka_music_hl/services/music_api.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 收藏歌单接口总数：10 条，其中 2 条 hash 为空（收藏失败或已下架）。
const _playlistTotalCount = 10;
const _validLikedSongs = 8;

http.Response jsonResponse(Object body) => http.Response(
      jsonEncode({'code': 0, 'status': 200, 'data': body}),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

Map<String, dynamic> likedSongJson(int index) => {
  'fileid': 1000 + index,
  'hash': 'HASH_$index',
  'name': '收藏歌曲 $index',
  'timelen': 200000,
  'singers': [
    {'name': '歌手', 'singerid': 7, 'sid': 7},
  ],
};

MusicApi buildApi() {
  return MusicApi(
    ApiClient(
      client: MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/user/detail')) {
          return jsonResponse({'nickname': '测试账号'});
        }
        if (path.endsWith('/user/playlist')) {
          return jsonResponse({
            'userid': '9',
            'info': [
              {
                'name': '收藏',
                'listid': 77,
                'global_collection_id': 88,
                'count': _playlistTotalCount,
                'is_def': 2,
                'type': 1,
              },
            ],
          });
        }
        if (path.endsWith('/playlist/track/all')) {
          return jsonResponse({
            'songs': [
              for (var i = 0; i < _validLikedSongs; i++) likedSongJson(i),
              // 服务端仍计数、但列表页拿不到的两条：一条无 hash，一条空 hash
              {'fileid': 900, 'name': '收藏失败的歌曲'},
              {'fileid': 901, 'name': '已下架歌曲', 'hash': ''},
            ],
          });
        }
        return jsonResponse({});
      }),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('收藏总数按收藏歌单内有效歌曲计，不含收藏失败或下架条目', () async {
    final auth = AuthController(buildApi(), CacheService())
      ..session = const LoginSession(userId: '9', token: 'token', t1: 't1');

    await auth.refreshProfile(silent: true);

    expect(auth.errorMessage, isNull);
    expect(auth.likedPlaylist?.songCount, _playlistTotalCount);
    expect(auth.likedCount, _validLikedSongs);
  });

  test('收藏列表还没同步时退回歌单接口总数', () {
    final auth = AuthController(buildApi(), CacheService());
    auth.playlists = const [
      PlaylistSummary(
        id: '88',
        title: '收藏',
        isDefault: 2,
        songCount: _playlistTotalCount,
      ),
    ];

    expect(auth.likedCount, _playlistTotalCount);
  });
}
