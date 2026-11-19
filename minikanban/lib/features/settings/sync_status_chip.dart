/// Чип статуса синхронизации в шапке.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/platform_role.dart';
import '../../sync/sync_status.dart';
import '../board/board_text.dart';

/// Текст чипа для состояния [status] на устройстве с ролью [role].
String syncStatusLabel(SyncStatus status, PlatformRole role, {DateTime? now}) {
  final last = status.lastSyncAt;
  return switch (status.phase) {
    SyncPhase.synced => last == null
        ? (role.isHub ? 'Телефон подключён' : 'Синхронизировано')
        : 'Синхронизировано · ${relativeTime(last, now: now)}',
    SyncPhase.syncing => 'Синхронизация…',
    SyncPhase.offline =>
      role.isHub ? 'Нет связи с телефоном' : 'Нет связи с ПК',
    SyncPhase.notPaired =>
      role.isHub ? 'Телефон не подключён' : 'Не подключено к ПК',
    SyncPhase.revoked => 'Отвязано от ПК',
    SyncPhase.certError => 'Ошибка сертификата ПК',
    SyncPhase.incompatible => 'Несовместимая версия',
  };
}

/// Чип статуса. Нажатие — ручная синхронизация ([onTap]).
///
/// Видимая высота 32px, область нажатия — 48px.
class SyncStatusChip extends ConsumerStatefulWidget {
  const SyncStatusChip({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  ConsumerState<SyncStatusChip> createState() => _SyncStatusChipState();
}

class _SyncStatusChipState extends ConsumerState<SyncStatusChip> {
  /// Обновляет «N мин назад», пока чип на экране.
  late final Timer _ticker = Timer.periodic(
    const Duration(seconds: 20),
    (_) {
      if (mounted) setState(() {});
    },
  );

  @override
  void initState() {
    super.initState();
    _ticker; // запускает таймер
  }

  @override
  void dispose() {
    _ticker.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final onTap = widget.onTap;
    final status = ref.watch(syncStatusProvider);
    final role = ref.watch(platformRoleProvider);
    final colors = context.kanban;
    final label = syncStatusLabel(status, role);

    final (Color bg, Color fg, Color? border, FontWeight weight) =
        switch (status.phase) {
      SyncPhase.synced => (
          colors.syncedBg,
          colors.syncedFg,
          null,
          FontWeight.w500,
        ),
      SyncPhase.syncing => (
          colors.tonal,
          colors.onTonal,
          null,
          FontWeight.w500
        ),
      SyncPhase.offline ||
      SyncPhase.revoked ||
      SyncPhase.certError ||
      SyncPhase.incompatible =>
        (colors.warnBg, colors.warnFg, null, FontWeight.w600),
      SyncPhase.notPaired => (
          colors.column,
          colors.textSecondary,
          colors.outline,
          FontWeight.w500,
        ),
    };

    final Widget icon = switch (status.phase) {
      SyncPhase.synced => Icon(Icons.check_circle_outline, size: 18, color: fg),
      SyncPhase.syncing => SizedBox(
          width: 18,
          height: 18,
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: CircularProgressIndicator(strokeWidth: 2, color: fg),
          ),
        ),
      SyncPhase.offline => Icon(Icons.cloud_off_outlined, size: 18, color: fg),
      SyncPhase.notPaired ||
      SyncPhase.revoked =>
        Icon(Icons.link_off, size: 18, color: fg),
      SyncPhase.certError ||
      SyncPhase.incompatible =>
        Icon(Icons.warning_amber_rounded, size: 18, color: fg),
    };

    return Semantics(
      button: true,
      label: '$label. Синхронизировать сейчас',
      excludeSemantics: true,
      onTap: onTap,
      child: Tooltip(
        message: 'Синхронизировать сейчас',
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: const ValueKey('sync-chip'),
            borderRadius: BorderRadius.circular(24),
            onTap: onTap,
            child: SizedBox(
              height: 48,
              child: Center(
                widthFactor: 1,
                child: Container(
                  height: 32,
                  padding: const EdgeInsets.only(left: 8, right: 12),
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: BorderRadius.circular(16),
                    border: border == null ? null : Border.all(color: border),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      icon,
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.2,
                            fontWeight: weight,
                            color: fg,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
