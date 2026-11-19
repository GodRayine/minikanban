/// Настройки: на телефоне — привязанный компьютер и синхронизация,
/// на ПК — подключение телефонов, трей и автозапуск.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/desktop_shell.dart';
import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../sync/client/client_store.dart';
import '../../sync/client/sync_client.dart';
import '../../sync/sync_status.dart';
import '../pairing/pair_pc_page.dart';
import '../pairing/scan_page.dart';
import 'sync_status_chip.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isHub = ref.watch(platformRoleProvider).isHub;
    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: isHub ? const _HubSettings() : const _ClientSettings(),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
        child: Semantics(
          header: true,
          child: Text(
            text,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: context.kanban.textSecondary,
            ),
          ),
        ),
      );
}

// --- Телефон ----------------------------------------------------------------

class _ClientSettings extends ConsumerStatefulWidget {
  const _ClientSettings();

  @override
  ConsumerState<_ClientSettings> createState() => _ClientSettingsState();
}

class _ClientSettingsState extends ConsumerState<_ClientSettings> {
  ServerLink? _link;

  @override
  void initState() {
    super.initState();
    unawaited(_loadLink());
  }

  Future<void> _loadLink() async {
    final link = await ref.read(syncClientProvider)?.link();
    if (mounted) setState(() => _link = link);
  }

  Future<void> _connect() async {
    await openScanPage(context);
    await _loadLink();
  }

  Future<void> _unpair(SyncClient client) async {
    final error = Theme.of(context).colorScheme.error;
    final name = _link?.serverName ?? 'компьютера';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Отвязать от «$name»?'),
        content: const Text(
          'Синхронизация остановится. Задачи останутся на телефоне и на '
          'компьютере. Чтобы подключиться снова, отсканируйте QR-код.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: error),
            child: const Text('Отвязать'),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false)) return;
    await client.unpair();
    await _loadLink();
  }

  Future<void> _rediscover(SyncClient client) async {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: Text('Ищу компьютер в сети заново…')),
      );
    await client.rediscover();
    await _loadLink();
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(syncStatusProvider);
    final role = ref.watch(platformRoleProvider);
    final client = ref.watch(syncClientProvider);
    final colors = context.kanban;
    final error = Theme.of(context).colorScheme.error;
    final phase = status.phase;

    if (client == null || !phase.isPaired) {
      return ListView(
        children: [
          const _SectionTitle('Компьютер'),
          ListTile(
            leading: const Icon(Icons.computer),
            title: const Text('Подключение к компьютеру'),
            subtitle: Text(syncStatusLabel(status, role)),
          ),
          if (client != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: FilledButton.icon(
                onPressed: _connect,
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Подключить к компьютеру'),
              ),
            ),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Задачи сохраняются на этом устройстве'),
            subtitle: Text(
              'После подключения они будут синхронизироваться с компьютером '
              'по Wi-Fi.',
            ),
          ),
        ],
      );
    }

    final link = _link;
    final address = link?.lastGood?.toString() ??
        (link == null || link.ips.isEmpty
            ? null
            : '${link.ips.first}:${link.port}');
    final problem = switch (phase) {
      SyncPhase.revoked =>
        'Компьютер отвязал этот телефон. Подключитесь заново, чтобы '
            'продолжить синхронизацию.',
      SyncPhase.certError =>
        'Сертификат компьютера не совпал с сохранённым. Если приложение '
            'на компьютере переустанавливали, подключитесь заново.',
      SyncPhase.incompatible =>
        'На компьютере и телефоне разные версии приложения. Обновите '
            '«Мини-канбан» на обоих устройствах.',
      SyncPhase.offline =>
        'Компьютер не найден. Проверьте, что он включён, приложение '
            'запущено и оба устройства в одной сети Wi-Fi.',
      _ => null,
    };

    return ListView(
      children: [
        const _SectionTitle('Компьютер'),
        ListTile(
          leading: const Icon(Icons.computer),
          title: Text(link?.serverName ?? 'Компьютер'),
          subtitle: Text(
            [syncStatusLabel(status, role), if (address != null) address]
                .join('\n'),
          ),
          isThreeLine: address != null,
          // Диагностика: долгое нажатие забывает запомненный адрес и
          // ищет компьютер в сети заново.
          onLongPress: phase == SyncPhase.syncing
              ? null
              : () => _rediscover(client),
        ),
        if (problem != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: colors.warnBg,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                problem,
                style: TextStyle(
                  fontSize: 14,
                  height: 20 / 14,
                  color: colors.warnFg,
                ),
              ),
            ),
          ),
        if (phase == SyncPhase.revoked || phase == SyncPhase.certError)
          ListTile(
            leading: const Icon(Icons.qr_code_scanner),
            title: const Text('Подключить заново'),
            onTap: _connect,
          )
        else
          ListTile(
            leading: const Icon(Icons.sync),
            title: const Text('Синхронизировать сейчас'),
            enabled: phase != SyncPhase.syncing,
            onTap: () =>
                unawaited(ref.read(syncStatusProvider.notifier).syncNow()),
          ),
        ListTile(
          leading: Icon(Icons.link_off, color: error),
          title: Text('Отвязать', style: TextStyle(color: error)),
          onTap: () => _unpair(client),
        ),
        const _SectionTitle('Как это работает'),
        const ListTile(
          leading: Icon(Icons.info_outline),
          title: Text('Синхронизация по Wi-Fi'),
          subtitle: Text(
            'При открытии приложения, каждые 5 минут, пока оно на экране, '
            'и через несколько секунд после правки. В фоне — примерно раз '
            'в 15 минут.',
          ),
        ),
      ],
    );
  }
}

// --- ПК ---------------------------------------------------------------------

class _HubSettings extends ConsumerStatefulWidget {
  const _HubSettings();

  @override
  ConsumerState<_HubSettings> createState() => _HubSettingsState();
}

class _HubSettingsState extends ConsumerState<_HubSettings> {
  bool _autostart = false;
  bool _busy = false;

  DesktopShell? get _shell => ref.read(desktopShellProvider);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final enabled = await _shell?.autostartEnabled() ?? false;
    if (mounted) setState(() => _autostart = enabled);
  }

  Future<void> _toggle(bool value) async {
    final shell = _shell;
    if (shell == null || _busy) return;
    setState(() {
      _busy = true;
      _autostart = value;
    });
    final enabled = await shell.setAutostart(value);
    if (mounted) {
      setState(() {
        _busy = false;
        _autostart = enabled;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(syncStatusProvider);
    final role = ref.watch(platformRoleProvider);
    final shell = ref.watch(desktopShellProvider);
    final server = ref.watch(syncServerProvider);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(
          children: [
            const _SectionTitle('Телефоны'),
            ListTile(
              leading: const Icon(Icons.smartphone),
              title: const Text('Подключить телефон'),
              subtitle: Text(syncStatusLabel(status, role)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const PairPcPage()),
              ),
            ),
            if (server != null && server.isRunning)
              ListTile(
                leading: const Icon(Icons.lan_outlined),
                title: const Text('Сервер синхронизации работает'),
                subtitle: Text('Порт ${server.port}'),
              ),
            const _SectionTitle('Работа в фоне'),
            SwitchListTile(
              secondary: const Icon(Icons.rocket_launch_outlined),
              title: const Text('Запускать вместе с Windows'),
              subtitle: const Text(
                'Приложение запустится свёрнутым в трей, и телефоны смогут '
                'синхронизироваться сразу после включения компьютера.',
              ),
              value: _autostart,
              onChanged: shell == null || _busy ? null : _toggle,
            ),
            ListTile(
              leading: const Icon(Icons.minimize),
              title: const Text('Закрытие окна сворачивает в трей'),
              subtitle: Text(
                shell != null && shell.trayReady
                    ? 'Синхронизация продолжает работать. Чтобы открыть окно, '
                        'нажмите на значок в области уведомлений; чтобы '
                        'закрыть приложение совсем — «Выход» в его меню.'
                    : 'Значок в трее недоступен: закрытие окна завершает '
                        'приложение.',
              ),
            ),
            if (shell != null)
              ListTile(
                leading: const Icon(Icons.power_settings_new),
                title: const Text('Выйти из приложения'),
                subtitle: const Text('Синхронизация остановится'),
                onTap: () => unawaited(shell.quit()),
              ),
          ],
        ),
      ),
    );
  }
}
