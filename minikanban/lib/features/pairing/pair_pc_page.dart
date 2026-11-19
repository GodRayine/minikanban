/// Экран «Подключите телефон» на ПК: QR-код с одноразовым кодом,
/// адрес для ручного ввода и список связанных устройств.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/device_dao.dart';
import '../../sync/protocol/qr_payload.dart';
import '../../sync/server/firewall.dart';
import '../../sync/server/network_info.dart';
import '../../sync/server/pairing_service.dart';
import '../../sync/server/sync_server.dart';
import '../board/board_text.dart';

/// «4:59» — остаток срока действия кода.
String formatCountdown(Duration left) {
  final seconds = left.isNegative ? 0 : left.inSeconds;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

/// «Синхронизация 3 мин назад» / «Ещё не синхронизировался».
String deviceSyncLabel(PairedDevice device, {DateTime? now}) {
  final at = device.lastSyncAt;
  if (at == null) return 'Ещё не синхронизировался';
  return 'Синхронизация '
      '${relativeTime(DateTime.fromMillisecondsSinceEpoch(at), now: now)}';
}

/// Проверка брандмауэра Windows для порта сервера. В тестах подменяется.
final firewallCheckProvider = Provider<Future<FirewallAccess> Function(int)>(
  (ref) => checkFirewallAccess,
);

/// Запрос разрешающего правила (UAC). В тестах подменяется.
final firewallRequestProvider = Provider<Future<void> Function(int)>(
  (ref) => requestFirewallAccess,
);

class PairPcPage extends ConsumerWidget {
  const PairPcPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final server = ref.watch(syncServerProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Мини-канбан',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        shape: Border(bottom: BorderSide(color: context.kanban.outline)),
      ),
      body: server == null || !server.isRunning
          ? _ServerUnavailable(error: ref.watch(syncServerErrorProvider))
          : _PairingBody(server: server),
    );
  }
}

class _ServerUnavailable extends StatelessWidget {
  const _ServerUnavailable({required this.error});

  final String? error;

  @override
  Widget build(BuildContext context) {
    final colors = context.kanban;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_outlined,
                  size: 56, color: colors.textSecondary),
              const SizedBox(height: 16),
              Text(
                'Синхронизация недоступна',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: colors.text,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Не удалось запустить сервер синхронизации на этом '
                'компьютере. Перезапустите приложение.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  height: 22 / 15,
                  color: colors.textSecondary,
                ),
              ),
              if (error != null) ...[
                const SizedBox(height: 12),
                SelectableText(
                  error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: colors.textSecondary),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _PairingBody extends ConsumerStatefulWidget {
  const _PairingBody({required this.server});

  final SyncServer server;

  @override
  ConsumerState<_PairingBody> createState() => _PairingBodyState();
}

class _PairingBodyState extends ConsumerState<_PairingBody> {
  late PairingCode _code;
  List<LanAddress> _addresses = const [];
  List<PairedDevice> _devices = const [];
  FirewallAccess _firewall = FirewallAccess.unknown;
  bool _firewallBusy = false;
  int _ticks = 0;
  StreamSubscription<void>? _events;
  Timer? _ticker;

  SyncServer get _server => widget.server;

  @override
  void initState() {
    super.initState();
    _code = _server.pairing.newCode();
    _events = _server.deviceEvents.listen((_) => _onDeviceEvent());
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    unawaited(_loadAddresses());
    unawaited(_loadDevices());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    unawaited(_events?.cancel());
    // Экран закрыт — код больше не должен действовать.
    _server.pairing.cancelCode();
    super.dispose();
  }

  void _tick() {
    if (!mounted) return;
    // Пока доступ не разрешён, перепроверяем: правило могли добавить в
    // окне Windows или сеть могла смениться.
    if (++_ticks % 10 == 0 && _needsFirewallRule) {
      unawaited(_checkFirewall());
    }
    if (!DateTime.now().isBefore(_code.expiresAt)) {
      _refreshCode();
    } else {
      setState(() {});
    }
  }

  void _refreshCode() {
    setState(() => _code = _server.pairing.newCode());
    unawaited(_loadAddresses());
  }

  Future<void> _loadAddresses() async {
    final addresses = await lanIPv4Candidates();
    if (mounted) setState(() => _addresses = addresses);
    await _checkFirewall();
  }

  bool get _needsFirewallRule =>
      _firewall == FirewallAccess.missing ||
      _firewall == FirewallAccess.blocked;

  Future<void> _checkFirewall() async {
    if (_firewallBusy) return;
    _firewallBusy = true;
    try {
      final access = await ref.read(firewallCheckProvider)(_server.port);
      if (mounted) setState(() => _firewall = access);
    } finally {
      _firewallBusy = false;
    }
  }

  /// Кнопка «Разрешить в брандмауэре»: Windows спросит подтверждение (UAC).
  Future<void> _allowInFirewall() async {
    if (_firewallBusy) return;
    setState(() => _firewallBusy = true);
    try {
      await ref.read(firewallRequestProvider)(_server.port);
    } finally {
      _firewallBusy = false;
    }
    await _checkFirewall();
    if (mounted) setState(() {});
  }

  Future<void> _loadDevices() async {
    final devices = await _server.devices();
    if (mounted) setState(() => _devices = devices);
  }

  void _onDeviceEvent() {
    if (!mounted) return;
    // Код одноразовый: телефон его использовал — показываем новый.
    if (!_server.pairing.hasActiveCode) {
      _refreshCode();
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Телефон подключён')));
    }
    unawaited(_loadDevices());
  }

  String get _qrData => PairingQrPayload(
        serverId: _server.serverId,
        serverName: _server.serverName,
        host: _server.serverName,
        ips: [for (final a in _addresses) a.ip],
        port: _server.port,
        code: _code.code,
        fingerprint: _server.identity.fingerprint,
        exp: _code.exp,
      ).encode();

  Future<void> _copy(String text, String message) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _confirmRevoke(PairedDevice device) async {
    final error = Theme.of(context).colorScheme.error;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Отвязать «${device.name}»?'),
        content: const SizedBox(
          width: 420,
          child: Text(
            'Телефон перестанет синхронизироваться с этим компьютером. '
            'Задачи на обоих устройствах останутся. Чтобы подключить '
            'телефон снова, отсканируйте QR-код заново.',
          ),
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
    if (confirmed ?? false) await _server.revoke(device.deviceId);
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 1100;
    final pairCard = _PairCard(
      qrData: _qrData,
      countdown: formatCountdown(_code.expiresAt.difference(DateTime.now())),
      serverName: _server.serverName,
      port: _server.port,
      addresses: _addresses,
      firewall: _firewall,
      onAllowInFirewall:
          _firewallBusy ? null : () => unawaited(_allowInFirewall()),
      code: _code.code,
      onRefresh: _refreshCode,
      onCopyCode: () => _copy(_code.code, 'Код скопирован'),
      onCopyLink: () => _copy(_qrData, 'Строка подключения скопирована'),
    );
    final side = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DevicesCard(devices: _devices, onRevoke: _confirmRevoke),
        const SizedBox(height: 16),
        const _FirewallHint(),
      ],
    );

    return SingleChildScrollView(
      padding: EdgeInsets.symmetric(
        horizontal: wide ? 32 : 16,
        vertical: wide ? 40 : 16,
      ),
      child: Center(
        child: wide
            ? Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 600, child: pairCard),
                  const SizedBox(width: 24),
                  SizedBox(width: 480, child: side),
                ],
              )
            : ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 600),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [pairCard, const SizedBox(height: 16), side],
                ),
              ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child, this.padding = const EdgeInsets.all(32)});

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final colors = context.kanban;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colors.outline),
      ),
      child: child,
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: context.kanban.textSecondary,
            ),
          ),
          const SizedBox(height: 2),
          child,
        ],
      );
}

class _PairCard extends StatelessWidget {
  const _PairCard({
    required this.qrData,
    required this.countdown,
    required this.serverName,
    required this.port,
    required this.addresses,
    required this.firewall,
    required this.onAllowInFirewall,
    required this.code,
    required this.onRefresh,
    required this.onCopyCode,
    required this.onCopyLink,
  });

  final String qrData;
  final String countdown;
  final String serverName;
  final int port;
  final List<LanAddress> addresses;
  final FirewallAccess firewall;

  /// `null` — запрос уже выполняется.
  final VoidCallback? onAllowInFirewall;
  final String code;
  final VoidCallback onRefresh;
  final VoidCallback onCopyCode;
  final VoidCallback onCopyLink;

  @override
  Widget build(BuildContext context) {
    final colors = context.kanban;
    final primary = Theme.of(context).colorScheme.primary;
    const ink = Color(0xFF1B1C22);
    final strong = TextStyle(
      fontSize: 18,
      fontWeight: FontWeight.w600,
      color: colors.text,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    final qr = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 268,
          height: 268,
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: colors.outline),
          ),
          child: QrImageView(
            key: const ValueKey('pair-qr'),
            data: qrData,
            size: 240,
            padding: EdgeInsets.zero,
            backgroundColor: Colors.white,
            errorCorrectionLevel: QrErrorCorrectLevel.M,
            semanticsLabel: 'QR-код для подключения телефона',
            eyeStyle:
                const QrEyeStyle(eyeShape: QrEyeShape.square, color: ink),
            dataModuleStyle: const QrDataModuleStyle(
              dataModuleShape: QrDataModuleShape.square,
              color: ink,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.schedule, size: 18, color: colors.textSecondary),
            const SizedBox(width: 6),
            Text(
              'Код действует $countdown',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: colors.textSecondary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ],
    );

    final facts = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Fact(
          label: 'Этот компьютер',
          child: Text(serverName, style: strong),
        ),
        const SizedBox(height: 16),
        _Fact(
          label: 'Адрес в локальной сети',
          child: addresses.isEmpty
              ? Text(
                  'Сеть не найдена',
                  style: strong.copyWith(color: colors.warnFg),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final (i, address) in addresses.indexed)
                      SelectableText(
                        '${address.ip}:$port',
                        style: i == 0
                            ? strong
                            : strong.copyWith(
                                fontSize: 15,
                                fontWeight: FontWeight.w500,
                                color: colors.textSecondary,
                              ),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 16),
        _Fact(
          label: 'Сеть',
          child: Text(
            addresses.isEmpty
                ? 'Подключите компьютер к Wi-Fi или кабелю'
                : addresses.first.interfaceName,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: colors.text,
            ),
          ),
        ),
        if (firewall == FirewallAccess.allowed) ...[
          const SizedBox(height: 16),
          _Fact(
            label: 'Брандмауэр Windows',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check_circle_outline, size: 18, color: colors.green),
                const SizedBox(width: 6),
                Text(
                  'Доступ разрешён',
                  key: const ValueKey('firewall-allowed'),
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: colors.text,
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 24),
        OutlinedButton.icon(
          onPressed: onRefresh,
          icon: const Icon(Icons.refresh, size: 20),
          label: const Text('Обновить код'),
          style: OutlinedButton.styleFrom(foregroundColor: primary),
        ),
      ],
    );

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              'Подключите телефон',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.5,
                color: colors.text,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Откройте приложение на телефоне и наведите камеру на код. '
            'Устройства должны быть в одной сети Wi-Fi.',
            style: TextStyle(
              fontSize: 15,
              height: 22 / 15,
              color: colors.textSecondary,
            ),
          ),
          if (firewall == FirewallAccess.missing ||
              firewall == FirewallAccess.blocked) ...[
            const SizedBox(height: 16),
            _FirewallWarning(
              blocked: firewall == FirewallAccess.blocked,
              onAllow: onAllowInFirewall,
            ),
          ],
          const SizedBox(height: 24),
          Wrap(
            spacing: 28,
            runSpacing: 24,
            children: [
              qr,
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 236),
                child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: facts,
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          const Divider(height: 1),
          const SizedBox(height: 16),
          Text(
            'Камера не работает? На телефоне выберите «Ввести адрес '
            'вручную» и укажите адрес компьютера и этот код:',
            style: TextStyle(
              fontSize: 14,
              height: 20 / 14,
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SelectableText(
                code,
                key: const ValueKey('pair-code'),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'Consolas',
                  letterSpacing: 0.5,
                  color: colors.text,
                ),
              ),
              IconButton(
                tooltip: 'Скопировать код',
                onPressed: onCopyCode,
                icon: const Icon(Icons.copy, size: 20),
              ),
              TextButton(
                onPressed: onCopyLink,
                child: const Text('Скопировать строку подключения'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FirewallWarning extends StatelessWidget {
  const _FirewallWarning({required this.blocked, required this.onAllow});

  /// Есть запрещающее правило (а не просто нет разрешающего).
  final bool blocked;
  final VoidCallback? onAllow;

  @override
  Widget build(BuildContext context) {
    final colors = context.kanban;
    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        key: const ValueKey('firewall-warning'),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        decoration: BoxDecoration(
          color: colors.warnBg,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.warning_amber_rounded, size: 22, color: colors.warnFg),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    blocked
                        ? 'Брандмауэр Windows блокирует «Мини-канбан» в этой '
                            'сети, поэтому телефон не сможет подключиться. '
                            'Разрешите доступ — Windows попросит подтверждение.'
                        : 'Брандмауэр Windows пока не пропускает подключения '
                            'к «Мини-канбану» в этой сети, поэтому телефон не '
                            'сможет подключиться. Разрешите доступ — Windows '
                            'попросит подтверждение.',
                    style: TextStyle(
                      fontSize: 14,
                      height: 20 / 14,
                      fontWeight: FontWeight.w500,
                      color: colors.warnFg,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton.icon(
                      onPressed: onAllow,
                      icon: const Icon(Icons.shield_outlined, size: 18),
                      label: const Text('Разрешить в брандмауэре'),
                      style: TextButton.styleFrom(
                        foregroundColor: colors.warnFg,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DevicesCard extends StatelessWidget {
  const _DevicesCard({required this.devices, required this.onRevoke});

  final List<PairedDevice> devices;
  final void Function(PairedDevice device) onRevoke;

  @override
  Widget build(BuildContext context) {
    final colors = context.kanban;
    final error = Theme.of(context).colorScheme.error;
    return _Panel(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Связанные устройства',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: colors.text,
            ),
          ),
          const SizedBox(height: 12),
          if (devices.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                'Пока нет связанных устройств.',
                style: TextStyle(fontSize: 14, color: colors.textSecondary),
              ),
            ),
          for (final (i, device) in devices.indexed) ...[
            if (i > 0) const Divider(height: 1),
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 64),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: colors.tonal,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.smartphone,
                      size: 20,
                      color: colors.onTonal,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          device.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: colors.text,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          deviceSyncLabel(device),
                          style: TextStyle(
                            fontSize: 13,
                            color: colors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Semantics(
                    label: 'Отвязать ${device.name}',
                    button: true,
                    excludeSemantics: true,
                    child: OutlinedButton(
                      onPressed: () => onRevoke(device),
                      style: OutlinedButton.styleFrom(foregroundColor: error),
                      child: const Text('Отвязать'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _FirewallHint extends StatelessWidget {
  const _FirewallHint();

  @override
  Widget build(BuildContext context) {
    final colors = context.kanban;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        color: colors.tonal,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 22, color: colors.onTonal),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Телефон не находит компьютер?',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: colors.onTonal,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Проверьте, что оба устройства подключены к одной сети '
                  'Wi-Fi и что на телефоне выключен VPN. Приложению '
                  '«Мини-канбан» должен быть разрешён доступ в брандмауэре '
                  'Windows — и для частных, и для общедоступных сетей. '
                  'Гостевые сети Wi-Fi иногда не дают устройствам видеть '
                  'друг друга.',
                  style: TextStyle(
                    fontSize: 14,
                    height: 20 / 14,
                    color: colors.onTonal,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
