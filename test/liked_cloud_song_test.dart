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

http.Response jsonResponse(Object body) => http.Response(
  jsonEncode({'code': 0, 'status': 200, 'data': body}),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

/// 云盘曲目：album_audio_id 是 0，真正的 ID 在自身的 audio_id 上。
const cloudSong = Song(
  id: '556677',
  title: '云盘歌曲',
  artist: '歌手',
  hash: 'CLOUD_HASH',
  albumAudioId: '0',
  isCloudDrive: true,
);

AuthController buildAuth(MusicApi api) =>
    AuthController(api, CacheService())
      ..session = const LoginSession(userId: '9', token: 'tk', t1: 't1')
      ..playlists = const [
        PlaylistSummary(
          id: '88',
          listId: '77',
          title: '收藏',
          isDefault: 2,
          songCount: 1,
        ),
      ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('收藏云盘歌曲时不会把占位 0 当成 mixSongId 提交', () async {
    Map<String, dynamic>? sentPayload;
    final api = MusicApi(
      ApiClient(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/playlist/tracks/add')) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            sentPayload = (body['songs'] as List).first as Map<String, dynamic>;
            return jsonResponse({
              'status': 1,
              'info': [
                {'hash': 'CLOUD_HASH', 'fileid': 4001, 'name': '云盘歌曲'},
              ],
            });
          }
          return jsonResponse({});
        }),
      ),
    );
    final auth = buildAuth(api);

    await auth.toggleLike(cloudSong);

    expect(sentPayload, isNotNull);
    expect(sentPayload!['mixSongId'], '556677');
    expect(sentPayload!['hash'], 'CLOUD_HASH');
    expect(auth.isLiked(cloudSong), isTrue);
  });

  test('服务端没落库时不点亮收藏，并返回未生效', () async {
    final api = MusicApi(
      ApiClient(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/playlist/tracks/add')) {
            // status 正常，但 info 是空数组：这首歌其实没有进收藏歌单。
            return jsonResponse({'status': 1, 'info': []});
          }
          return jsonResponse({});
        }),
      ),
    );
    final auth = buildAuth(api);

    final done = await auth.toggleLike(cloudSong);

    expect(done, isFalse);
    expect(auth.isLiked(cloudSong), isFalse);
  });

  test('收藏列表里已经没有这首歌时，取消收藏不报错并清掉本地标记', () async {
    var songStillInPlaylist = true;
    var deleteCalled = false;
    final api = MusicApi(
      ApiClient(
        client: MockClient((request) async {
          final path = request.url.path;
          if (path.endsWith('/playlist/tracks/add')) {
            return jsonResponse({
              'status': 1,
              'info': [
                {'hash': 'CLOUD_HASH', 'fileid': 4001, 'name': '云盘歌曲'},
              ],
            });
          }
          if (path.endsWith('/playlist/track/all')) {
            return jsonResponse({
              'songs': songStillInPlaylist
                  ? [
                      {
                        'fileid': 4001,
                        'hash': 'CLOUD_HASH',
                        'name': '云盘歌曲',
                      },
                    ]
                  : [],
            });
          }
          if (path.endsWith('/playlist/tracks/del')) {
            deleteCalled = true;
            return jsonResponse({'status': 1});
          }
          return jsonResponse({});
        }),
      ),
    );
    final auth = buildAuth(api);

    await auth.toggleLike(cloudSong);
    expect(auth.isLiked(cloudSong), isTrue);

    // 模拟服务端列表里已经查不到这首歌（下架、或当初就没真正加入）。
    songStillInPlaylist = false;
    final done = await auth.toggleLike(cloudSong);

    expect(done, isTrue);
    expect(auth.isLiked(cloudSong), isFalse);
    expect(deleteCalled, isFalse);
  });

  test('收藏列表能查到时按歌单内 fileid 删除', () async {
    String? deletedFileIds;
    final api = MusicApi(
      ApiClient(
        client: MockClient((request) async {
          final path = request.url.path;
          if (path.endsWith('/playlist/tracks/add')) {
            return jsonResponse({
              'status': 1,
              'info': [
                {'hash': 'CLOUD_HASH', 'fileid': 4001, 'name': '云盘歌曲'},
              ],
            });
          }
          if (path.endsWith('/playlist/track/all')) {
            return jsonResponse({
              'songs': [
                {'fileid': 4001, 'hash': 'CLOUD_HASH', 'name': '云盘歌曲'},
              ],
            });
          }
          if (path.endsWith('/playlist/tracks/del')) {
            deletedFileIds = request.url.queryParameters['fileids'];
            return jsonResponse({'status': 1});
          }
          return jsonResponse({});
        }),
      ),
    );
    final auth = buildAuth(api);

    await auth.toggleLike(cloudSong);
    await auth.toggleLike(cloudSong);

    expect(deletedFileIds, '4001');
    expect(auth.isLiked(cloudSong), isFalse);
  });
}
