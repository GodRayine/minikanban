/// Брандмауэр Windows: пропускает ли он входящие подключения телефона к
/// серверу синхронизации в текущей сети.
///
/// Сеть может быть и частной, и общедоступной — важно лишь, чтобы для
/// этого exe было разрешающее входящее правило на активном профиле.
/// Чтение правил прав администратора не требует; добавление — требует
/// (UAC), и выполняется только по нажатию пользователя.
library;

import 'dart:convert';
import 'dart:io';

/// Итог проверки.
enum FirewallAccess {
  /// Входящие подключения разрешены (или брандмауэр выключен).
  allowed,

  /// Разрешающего правила для активного профиля нет.
  missing,

  /// Есть запрещающее правило (в окне Windows нажали «Отмена»).
  blocked,

  /// Проверить не удалось — ничего не показываем.
  unknown,
}

/// Биты профилей брандмауэра (`NET_FW_PROFILE_TYPE2`).
abstract final class FirewallProfile {
  static const int domain = 1;
  static const int private = 2;
  static const int public = 4;
  static const List<int> all = [domain, private, public];
}

const int _protocolTcp = 6;
const int _protocolAny = 256;

/// Включённое входящее правило, относящееся к приложению или его порту.
final class FirewallRule {
  const FirewallRule({
    required this.allow,
    required this.profiles,
    required this.protocol,
    required this.localPorts,
    required this.forApp,
  });

  /// `true` — разрешает, `false` — запрещает.
  final bool allow;

  /// Битовая маска профилей.
  final int profiles;
  final int protocol;

  /// `*`, пусто или список вида `80,5000-5010`.
  final String localPorts;

  /// Правило привязано к exe приложения (иначе — только к порту).
  final bool forApp;

  bool _coversPort(int port) {
    final ports = localPorts.trim();
    if (ports.isEmpty || ports == '*') return forApp;
    for (final part in ports.split(',')) {
      final range = part.trim().split('-');
      final from = int.tryParse(range.first.trim());
      final to = int.tryParse(range.last.trim());
      if (from != null && to != null && port >= from && port <= to) {
        return true;
      }
    }
    return false;
  }

  /// Относится ли правило к TCP-порту [port] на профиле [profile].
  bool matches(int profile, int port) =>
      profiles & profile != 0 &&
      (protocol == _protocolTcp || (protocol == _protocolAny && forApp)) &&
      _coversPort(port);
}

/// Состояние брандмауэра, снятое с системы.
final class FirewallSnapshot {
  const FirewallSnapshot({
    required this.currentProfiles,
    required this.enabledProfiles,
    required this.rules,
  });

  /// Профили активных сетей (битовая маска).
  final int currentProfiles;

  /// Профили, на которых брандмауэр включён (битовая маска).
  final int enabledProfiles;
  final List<FirewallRule> rules;

  /// Доступ к TCP-порту [port]: должен быть разрешён на каждом активном
  /// профиле; запрещающее правило сильнее разрешающего.
  FirewallAccess accessFor(int port) {
    var result = FirewallAccess.allowed;
    for (final profile in FirewallProfile.all) {
      if (currentProfiles & profile == 0) continue;
      if (enabledProfiles & profile == 0) continue;
      final matching = rules.where((rule) => rule.matches(profile, port));
      if (matching.any((rule) => !rule.allow)) return FirewallAccess.blocked;
      if (!matching.any((rule) => rule.allow)) result = FirewallAccess.missing;
    }
    return result;
  }
}

/// Разбирает JSON, который печатает скрипт проверки.
FirewallSnapshot? parseFirewallSnapshot(String json) {
  final Object? decoded;
  try {
    decoded = jsonDecode(json.trim());
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  final current = decoded['current'];
  final enabled = decoded['enabled'];
  if (current is! int || enabled is! int) return null;
  final rawRules = decoded['rules'];
  final rules = <FirewallRule>[];
  for (final item in rawRules is List ? rawRules : [rawRules]) {
    if (item is! Map) continue;
    final action = item['action'];
    final profiles = item['profiles'];
    final protocol = item['protocol'];
    if (action is! int || profiles is! int || protocol is! int) continue;
    final ports = item['ports'];
    rules.add(
      FirewallRule(
        allow: action == 1,
        profiles: profiles,
        protocol: protocol,
        localPorts: ports is String ? ports : '',
        forApp: item['app'] == true,
      ),
    );
  }
  return FirewallSnapshot(
    currentProfiles: current,
    enabledProfiles: enabled,
    rules: rules,
  );
}

String _psQuote(String value) => "'${value.replaceAll("'", "''")}'";

/// Скрипт PowerShell (в виде `-EncodedCommand`: пути с пробелами и
/// кириллицей не зависят от кодовой страницы и кавычек).
String _encode(String script) {
  final units = script.codeUnits;
  final bytes = <int>[];
  for (final unit in units) {
    bytes
      ..add(unit & 0xFF)
      ..add(unit >> 8);
  }
  return base64Encode(bytes);
}

/// Путь exe, каким его видит брандмауэр: без ссылок и junction-ов.
String firewallExecutablePath() {
  final path = Platform.resolvedExecutable;
  try {
    return File(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    return path;
  }
}

String _checkScript(String exe) => '''
\$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.Encoding]::UTF8
\$exe=${_psQuote(exe)}
\$p=New-Object -ComObject HNetCfg.FwPolicy2
\$enabled=0
foreach(\$t in 1,2,4){if(\$p.FirewallEnabled(\$t)){\$enabled=\$enabled -bor \$t}}
\$rules=@(\$p.Rules|Where-Object{\$_.Enabled -and \$_.Direction -eq 1 -and ((\$_.ApplicationName -eq \$exe) -or (-not \$_.ApplicationName -and -not \$_.ServiceName -and \$_.Protocol -eq 6 -and \$_.LocalPorts -and \$_.LocalPorts -ne '*'))}|ForEach-Object{@{action=[int]\$_.Action;profiles=[int]\$_.Profiles;protocol=[int]\$_.Protocol;ports=[string]\$_.LocalPorts;app=[bool]\$_.ApplicationName}})
@{current=[int]\$p.CurrentProfileTypes;enabled=\$enabled;rules=\$rules}|ConvertTo-Json -Compress -Depth 4
''';

Future<ProcessResult> _powershell(String script) => Process.run(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-EncodedCommand',
        _encode(script),
      ],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );

/// Проверяет доступ к TCP-порту [port] сервера. Не бросает исключений.
Future<FirewallAccess> checkFirewallAccess(int port) async {
  if (!Platform.isWindows) return FirewallAccess.unknown;
  try {
    final result = await _powershell(_checkScript(firewallExecutablePath()))
        .timeout(const Duration(seconds: 15));
    if (result.exitCode != 0) return FirewallAccess.unknown;
    final snapshot = parseFirewallSnapshot(result.stdout as String);
    return snapshot?.accessFor(port) ?? FirewallAccess.unknown;
  } on Object {
    return FirewallAccess.unknown;
  }
}

/// Имя правила, которое добавляет приложение.
const String firewallRuleName = 'MiniKanban';

/// Команды, выполняемые с правами администратора: убрать запрещающие
/// входящие правила для этого exe и добавить разрешающее для TCP-порта
/// на частных и общедоступных сетях.
String firewallAllowScript(String exe, int port) => '''
\$exe=${_psQuote(exe)}
Get-NetFirewallApplicationFilter -Program \$exe -ErrorAction SilentlyContinue|Get-NetFirewallRule|Where-Object{\$_.Direction -eq 'Inbound' -and \$_.Action -eq 'Block'}|Remove-NetFirewallRule
netsh advfirewall firewall delete rule name="$firewallRuleName" dir=in program="\$exe"|Out-Null
netsh advfirewall firewall add rule name="$firewallRuleName" dir=in action=allow program="\$exe" protocol=TCP localport=$port profile=private,public enable=yes
''';

/// Просит Windows (окно UAC) добавить разрешающее правило. Вызывается
/// только по нажатию пользователя. Возвращает, когда команда завершилась
/// или пользователь отказался.
Future<void> requestFirewallAccess(int port) async {
  if (!Platform.isWindows) return;
  final inner = _encode(firewallAllowScript(firewallExecutablePath(), port));
  final script = 'Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden '
      "-Wait -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass',"
      "'-EncodedCommand','$inner'";
  try {
    await _powershell(script).timeout(const Duration(minutes: 2));
  } on Object {
    // Отказ в UAC или таймаут: состояние покажет повторная проверка.
  }
}
