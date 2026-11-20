import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../services/update_service.dart';
import '../theme/app_theme.dart';

/// 새 빌드가 있을 때 조용히 물어보는 팝업.
///
/// ## 설계 원칙 — 세 가지
///
/// **1. 막지 않습니다.**
/// `showDialog` 는 기본적으로 뒤를 어둡게 하고 입력을 막습니다. 하지만
/// 이 팝업은 "지금 할까요?"를 묻는 것이지 "이거부터 하세요"가 아닙니다.
/// `barrierDismissible: true` 로 두어 바깥을 눌러 닫을 수 있게 합니다.
/// 그게 곧 "나중에"입니다.
///
/// **2. 무엇이 바뀌었는지 보여줍니다.**
/// "새 버전이 있습니다. 업데이트하시겠습니까?" 만 있으면 사용자는 근거 없이
/// 결정해야 합니다. `notes` 가 있으면 함께 보여줍니다. 없으면 빌드 ID 를
/// 보여줍니다 — 최소한 "내 것과 다르다"는 사실은 전달됩니다.
///
/// **3. 데이터를 잃지 않는다고 명시합니다.**
/// 일정 앱 사용자가 가장 먼저 드는 걱정은 "지금 쓰던 거 날아가나?" 입니다.
/// 실제로 이 앱의 데이터는 브라우저 저장소에 있고 업데이트는 그것을
/// 건드리지 않습니다. 그 사실을 팝업에 적습니다. 안 적으면 사용자는
/// 업데이트를 미루고, 미루면 영원히 옛 버전을 씁니다.
class UpdateDialog extends StatelessWidget {
  const UpdateDialog({super.key, required this.check});

  final UpdateCheck check;

  /// 팝업을 띄우고 사용자의 선택을 돌려줍니다.
  ///
  /// 반환값:
  ///   `true`  → 지금 업데이트
  ///   `false` → 나중에 (또는 바깥을 눌러 닫음)
  static Future<bool> show(BuildContext context, UpdateCheck check) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (_) => UpdateDialog(check: check),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.ac;

    return AlertDialog(
      backgroundColor: p.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      titlePadding: const EdgeInsets.fromLTRB(22, 22, 22, 6),
      contentPadding: const EdgeInsets.fromLTRB(22, 8, 22, 8),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: p.indigo.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(Icons.system_update_alt_rounded,
                size: 20, color: p.indigo),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              context.tr('update_available_title'),
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: p.ink,
              ),
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 무엇이 바뀌었는지 — 있으면 보여주고, 없으면 빌드 ID
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: p.ink.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: p.line),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  check.notes?.isNotEmpty == true
                      ? check.notes!
                      : context.tr('update_no_notes'),
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.45,
                    color: p.ink,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  context.tr('update_build_info', args: {
                    'current': _short(check.currentBuild),
                    'remote': _short(check.remoteBuild),
                  }),
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.4,
                    color: p.inkSoft,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // ## 데이터 걱정을 먼저 없앱니다
          // 이 줄이 없으면 사용자는 업데이트를 미룹니다. 미루면 보안 패치도
          // 함께 미뤄집니다. 실제로 2026-11-20 사건 이후 배포에서 이게
          // 문제가 될 수 있었습니다.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.verified_user_outlined,
                  size: 15, color: p.inkSoft),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  context.tr('update_data_safe'),
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.45,
                    color: p.inkSoft,
                  ),
                ),
              ),
            ],
          ),

          // ## 페이지가 새로고침된다는 사실을 숨기지 않습니다
          // "업데이트"라고만 하면 화면이 그대로일 거라 기대합니다. 실제로는
          // 새로고침이 일어나므로 미리 말해야 놀라지 않습니다.
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline_rounded, size: 15, color: p.inkSoft),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  context.tr('update_reload_notice'),
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.45,
                    color: p.inkSoft,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          style: TextButton.styleFrom(
            foregroundColor: p.inkSoft,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          ),
          child: Text(
            context.tr('update_later'),
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: FilledButton.styleFrom(
            backgroundColor: p.indigo,
            foregroundColor: p.card,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          child: Text(
            context.tr('update_now'),
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }

  /// 긴 빌드 ID 를 팝업에 맞게 줄입니다.
  ///
  /// `2026.11.20.0851` → 그대로. `2026.11.20.0851-abcdef` → 앞부분만.
  /// 전체를 보여주면 팝업이 깨지고, 잘라도 "다르다"는 사실은 전달됩니다.
  String _short(String s) {
    if (s.isEmpty) return '—';
    if (s.length <= 18) return s;
    return '${s.substring(0, 15)}…';
  }
}
