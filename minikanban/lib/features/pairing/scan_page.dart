/// Экран «Подключение к компьютеру» на телефоне: сканер QR-кода, ручной
/// ввод адреса и ход привязки.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../app/providers.dart';
import '../../sync/client/client_store.dart';
import '../../sync/client/local_network_access.dart';
import '../../sync/client/pairing_client.dart';

const Color _bg = Color(0xFF0D0E12);
const Color _fg = Color(0xFFF1F1F7);
const Color _fg2 = Color(0xFFC4C6D2);
const Color _accent = Color(0xFFB5BEFA);
const Color _onAccent = Color(0xFF1B2466);
const Color _finder = Color(0xFF2A2C36);

/// Открывает экран подключения. Возвращает `true`, если телефон привязан.
Future<bool> openScanPage(BuildContext context) async =>
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const ScanPage()),
    ) ??
    false;

enum _Stage {
  /// Проверяем разрешение камеры.
  preparing,
  scanning,

  /// В доступе к камере отказано (можно спросить ещё раз).
  cameraDenied,

  /// Отказано «навсегда» — только через настройки системы.
  cameraBlocked,
  connecting,
  success,
  failure,
}

class ScanPage extends ConsumerStatefulWidget {
  const ScanPage({super.key});

  @override
  ConsumerState<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends ConsumerState<ScanPage>
    with WidgetsBindingObserver {
  _Stage _stage = _Stage.preparing;
  MobileScannerController? _scanner;
  PairingException? _error;
  String _serverName = '';

  /// Подсказка под видоискателем («Это не QR-код Мини-канбана»).
  String? _scanNote;
  Timer? _noteTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_prepareCamera(ask: true));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _noteTimer?.cancel();
    unawaited(_scanner?.dispose());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Вернулись из настроек системы — разрешение могли выдать.
    if (state == AppLifecycleState.resumed &&
        (_stage == _Stage.cameraDenied || _stage == _Stage.cameraBlocked)) {
      unawaited(_prepareCamera(ask: false));
    }
  }

  /// Разрешение камеры запрашивается только здесь — перед сканированием.
  Future<void> _prepareCamera({required bool ask}) async {
    PermissionStatus status;
    try {
      status = await Permission.camera.status;
      if (!status.isGranted && ask) status = await Permission.camera.request();
    } on Object {
      status = PermissionStatus.denied;
    }
    if (!mounted) return;
    if (status.isGranted) {
      _startScanner();
    } else {
      setState(
        () => _stage = status.isPermanentlyDenied || status.isRestricted
            ? _Stage.cameraBlocked
            : _Stage.cameraDenied,
      );
    }
  }

  void _startScanner() {
    _scanner ??= MobileScannerController(
      formats: const [BarcodeFormat.qrCode],
      detectionSpeed: DetectionSpeed.normal,
      detectionTimeoutMs: 600,
    );
    setState(() {
      _stage = _Stage.scanning;
      _error = null;
    });
  }

  Future<void> _stopScanner() async {
    final scanner = _scanner;
    _scanner = null;
    try {
      await scanner?.dispose();
    } on Object {
      // Камера уже остановлена.
    }
  }

  void _showNote(String text) {
    _noteTimer?.cancel();
    setState(() => _scanNote = text);
    _noteTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _scanNote = null);
    });
  }

  void _onDetect(BarcodeCapture capture) {
    if (_stage != _Stage.scanning) return;
    final pairing = ref.read(pairingClientProvider);
    if (pairing == null) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || raw.isEmpty) continue;
      try {
        final payload = pairing.parsePayload(raw);
        unawaited(_connect(() => pairing.pairWithPayload(payload)));
        return;
      } on PairingException catch (e) {
        if (e.error == PairingError.invalidInput) {
          _showNote('Это не QR-код «Мини-канбана»');
        } else {
          unawaited(_fail(e));
          return;
        }
      }
    }
  }

  Future<void> _fail(PairingException error) async {
    await _stopScanner();
    if (!mounted) return;
    setState(() {
      _stage = _Stage.failure;
      _error = error;
    });
  }

  Future<void> _connect(Future<ServerLink> Function() pair) async {
    setState(() => _stage = _Stage.connecting);
    await _stopScanner();
    try {
      // Android 16+/17: без этого разрешения система блокирует
      // соединения с устройствами локальной сети.
      if (await LocalNetworkAccess.request() == LocalNetworkStatus.denied) {
        throw const PairingException(
          PairingError.notFound,
          'Нет доступа к локальной сети',
          hint: 'Разрешите приложению «Мини-канбан» доступ к устройствам '
              'в локальной сети — без него телефон не может связаться '
              'с компьютером.',
        );
      }
      final link = await pair();
      if (!mounted) return;
      setState(() {
        _stage = _Stage.success;
        _serverName = link.serverName;
      });
      // Первая синхронизация сразу после привязки.
      final client = ref.read(syncClientProvider);
      await client?.reload();
      unawaited(ref.read(syncSchedulerProvider)?.syncNow());
    } on PairingException catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.failure;
        _error = e;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.failure;
        _error = PairingException(
          PairingError.notFound,
          'Не удалось подключиться',
          hint: '$e',
        );
      });
    }
  }

  Future<void> _enterManually() async {
    final pairing = ref.read(pairingClientProvider);
    if (pairing == null) return;
    final input = await showModalBottomSheet<ManualPairingInput>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ManualSheet(pairing: pairing),
    );
    if (input == null || !mounted) return;
    switch (input) {
      case ManualPayload(:final payload):
        await _connect(() => pairing.pairWithPayload(payload));
      case ManualAddress(:final endpoint, :final code):
        await _connect(() => pairing.pairManually(endpoint, code));
    }
  }

  @override
  Widget build(BuildContext context) {
    final available = ref.watch(pairingClientProvider) != null;
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        scaffoldBackgroundColor: _bg,
        appBarTheme: theme.appBarTheme.copyWith(
          backgroundColor: _bg,
          foregroundColor: _fg,
        ),
      ),
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 0,
          title: const Text(
            'Подключение к компьютеру',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
        ),
        body: SafeArea(
          child: !available
              ? const _Message(
                  icon: Icons.cloud_off_outlined,
                  title: 'Синхронизация недоступна',
                  text: 'Перезапустите приложение и попробуйте ещё раз.',
                )
              : switch (_stage) {
                  _Stage.preparing => const SizedBox.expand(),
                  _Stage.scanning => _ScanView(
                      controller: _scanner!,
                      onDetect: _onDetect,
                      note: _scanNote,
                      onManual: _enterManually,
                    ),
                  _Stage.cameraDenied || _Stage.cameraBlocked => _Message(
                      icon: Icons.no_photography_outlined,
                      title: 'Нужен доступ к камере',
                      text: _stage == _Stage.cameraBlocked
                          ? 'Чтобы отсканировать QR-код, разрешите '
                              '«Мини-канбану» доступ к камере в настройках '
                              'телефона. Или введите адрес компьютера вручную.'
                          : 'Камера нужна только для того, чтобы '
                              'отсканировать QR-код на экране компьютера. '
                              'Или введите адрес вручную.',
                      primaryLabel: _stage == _Stage.cameraBlocked
                          ? 'Открыть настройки'
                          : 'Разрешить',
                      onPrimary: _stage == _Stage.cameraBlocked
                          ? () => unawaited(openAppSettings())
                          : () => unawaited(_prepareCamera(ask: true)),
                      secondaryLabel: 'Ввести адрес вручную',
                      onSecondary: _enterManually,
                    ),
                  _Stage.connecting => const _Message(
                      progress: true,
                      title: 'Подключение…',
                      text: 'Ищем компьютер в сети Wi-Fi.',
                    ),
                  _Stage.success => _Message(
                      icon: Icons.check_circle_outline,
                      title: 'Телефон подключён к „$_serverName“',
                      text: 'Задачи будут синхронизироваться автоматически, '
                          'когда телефон и компьютер в одной сети Wi-Fi.',
                      primaryLabel: 'Готово',
                      onPrimary: () => Navigator.of(context).pop(true),
                    ),
                  _Stage.failure => _Message(
                      icon: Icons.error_outline,
                      title: _error?.message ?? 'Не удалось подключиться',
                      text: _error?.hint,
                      primaryLabel: 'Попробовать снова',
                      onPrimary: () => unawaited(_prepareCamera(ask: true)),
                      secondaryLabel: 'Ввести адрес вручную',
                      onSecondary: _enterManually,
                    ),
                },
        ),
      ),
    );
  }
}

class _LinkButton extends StatelessWidget {
  const _LinkButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: const Color(0xFFC5CCFF),
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          textStyle: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            decoration: TextDecoration.underline,
          ),
        ),
        child: Text(label),
      );
}

class _ScanView extends StatelessWidget {
  const _ScanView({
    required this.controller,
    required this.onDetect,
    required this.note,
    required this.onManual,
  });

  final MobileScannerController controller;
  final void Function(BarcodeCapture capture) onDetect;
  final String? note;
  final VoidCallback onManual;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(32, 48, 32, 16),
              child: Column(
                children: [
                  Semantics(
                    label: 'Видоискатель камеры',
                    image: true,
                    child: SizedBox(
                      width: 264,
                      height: 264,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(28),
                            child: ColoredBox(
                              color: _finder,
                              child: MobileScanner(
                                controller: controller,
                                onDetect: onDetect,
                                errorBuilder: (context, error, child) =>
                                    const Center(
                                  child: Padding(
                                    padding: EdgeInsets.all(24),
                                    child: Text(
                                      'Камера недоступна. Введите адрес '
                                      'вручную.',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(color: _fg2),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const IgnorePointer(
                            child: CustomPaint(painter: _CornersPainter()),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),
                  const Text(
                    'Наведите камеру на QR-код на экране компьютера',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 18,
                      height: 26 / 18,
                      fontWeight: FontWeight.w500,
                      color: _fg,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    note ??
                        'На компьютере: «Подключить телефон». Оба устройства '
                            'должны быть в одной сети Wi-Fi.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      height: 20 / 14,
                      color: note == null ? _fg2 : const Color(0xFFF3D38C),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: _LinkButton(
              label: 'Ввести адрес вручную',
              onPressed: onManual,
            ),
          ),
        ],
      );
}

/// Белые уголки видоискателя.
class _CornersPainter extends CustomPainter {
  const _CornersPainter();

  @override
  void paint(Canvas canvas, Size size) {
    const radius = 28.0;
    const arm = 48.0;
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    final rect = (Offset.zero & size).deflate(2);
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(radius));
    for (final corner in [
      Rect.fromLTWH(0, 0, arm, arm),
      Rect.fromLTWH(size.width - arm, 0, arm, arm),
      Rect.fromLTWH(0, size.height - arm, arm, arm),
      Rect.fromLTWH(size.width - arm, size.height - arm, arm, arm),
    ]) {
      canvas
        ..save()
        ..clipRect(corner)
        ..drawRRect(rrect, paint)
        ..restore();
    }
  }

  @override
  bool shouldRepaint(_CornersPainter oldDelegate) => false;
}

/// Полноэкранное сообщение: значок или индикатор, заголовок, пояснение
/// и до двух действий.
class _Message extends StatelessWidget {
  const _Message({
    this.icon,
    this.progress = false,
    required this.title,
    this.text,
    this.primaryLabel,
    this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
  });

  final IconData? icon;
  final bool progress;
  final String title;
  final String? text;
  final String? primaryLabel;
  final VoidCallback? onPrimary;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (progress)
                const SizedBox(
                  width: 48,
                  height: 48,
                  child: CircularProgressIndicator(color: _accent),
                )
              else if (icon != null)
                Icon(icon, size: 64, color: _accent),
              const SizedBox(height: 24),
              Semantics(
                liveRegion: true,
                child: Text(
                  title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 20,
                    height: 26 / 20,
                    fontWeight: FontWeight.w600,
                    color: _fg,
                  ),
                ),
              ),
              if (text != null) ...[
                const SizedBox(height: 12),
                Text(
                  text!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 15,
                    height: 22 / 15,
                    color: _fg2,
                  ),
                ),
              ],
              if (primaryLabel != null) ...[
                const SizedBox(height: 32),
                FilledButton(
                  onPressed: onPrimary,
                  style: FilledButton.styleFrom(
                    backgroundColor: _accent,
                    foregroundColor: _onAccent,
                    minimumSize: const Size(200, 48),
                  ),
                  child: Text(primaryLabel!),
                ),
              ],
              if (secondaryLabel != null && onSecondary != null) ...[
                const SizedBox(height: 8),
                _LinkButton(label: secondaryLabel!, onPressed: onSecondary!),
              ],
            ],
          ),
        ),
      );
}

/// Ручной ввод: строка `mkanban://…` либо адрес и код.
class _ManualSheet extends StatefulWidget {
  const _ManualSheet({required this.pairing});

  final PairingClient pairing;

  @override
  State<_ManualSheet> createState() => _ManualSheetState();
}

class _ManualSheetState extends State<_ManualSheet> {
  final TextEditingController _address = TextEditingController();
  final TextEditingController _code = TextEditingController();
  String? _addressError;
  String? _codeError;

  @override
  void initState() {
    super.initState();
    _address.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _address.dispose();
    _code.dispose();
    super.dispose();
  }

  /// Вставлена строка подключения целиком — код вводить не нужно.
  bool get _isLink => _address.text.trim().toLowerCase().startsWith('mkanban:');

  void _submit() {
    try {
      final input = widget.pairing.parseManual(_address.text, _code.text);
      Navigator.of(context).pop(input);
    } on PairingException catch (e) {
      setState(() {
        final forCode = e.message == 'Введите код';
        _codeError = forCode ? e.message : null;
        _addressError = forCode ? null : e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(
          24,
          0,
          24,
          24 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Ввести адрес вручную',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              const Text(
                'Адрес и код показаны на компьютере на экране «Подключить '
                'телефон». Можно вставить и строку подключения целиком '
                '(mkanban://…).',
                style: TextStyle(fontSize: 14, height: 20 / 14),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const ValueKey('manual-address'),
                controller: _address,
                autofocus: true,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.url,
                textInputAction:
                    _isLink ? TextInputAction.done : TextInputAction.next,
                onSubmitted: _isLink ? (_) => _submit() : null,
                decoration: InputDecoration(
                  labelText: 'Адрес компьютера',
                  hintText: '192.168.1.42:47321',
                  errorText: _addressError,
                  errorMaxLines: 3,
                ),
              ),
              if (!_isLink) ...[
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('manual-code'),
                  controller: _code,
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.visiblePassword,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    labelText: 'Код',
                    errorText: _codeError,
                  ),
                ),
              ],
              const SizedBox(height: 20),
              FilledButton(
                key: const ValueKey('manual-submit'),
                onPressed: _submit,
                child: const Text('Подключить'),
              ),
            ],
          ),
        ),
      );
}
