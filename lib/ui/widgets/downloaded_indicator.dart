import 'package:flutter/material.dart';

import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import 'toast.dart';

/// 歌曲名后的"已下载到本地"小圆勾。
///
/// 收藏歌单、云盘等列表共用，保证同一套视觉与提示。
class DownloadedIndicator extends StatelessWidget {
  const DownloadedIndicator({
    super.key,
    required this.player,
    required this.song,
    this.interactive = true,
  });

  final PlayerController player;
  final Song song;

  /// 为 false 时不响应点击（多选模式下点击应留给整行勾选）。
  final bool interactive;

  @override
  Widget build(BuildContext context) {
    final downloads = player.downloadController;
    if (downloads == null) return const SizedBox.shrink();

    return AnimatedBuilder(
      animation: downloads,
      builder: (context, _) {
        if (!downloads.isDownloaded(song)) {
          return const SizedBox.shrink();
        }
        const badge = SizedBox.square(
          dimension: 16,
          child: Icon(
            Icons.check_rounded,
            size: 12,
            color: Color(0xFF24C768),
          ),
        );
        final circle = Material(
          color: const Color(0x1A24C768),
          shape: const CircleBorder(),
          child: interactive
              ? InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => Toast.info('已下载，播放时将优先使用本地文件'),
                  child: badge,
                )
              : badge,
        );
        return Tooltip(message: '已下载', child: circle);
      },
    );
  }
}
