import 'package:flutter_test/flutter_test.dart';
import 'package:minikanban/sync/server/firewall.dart';

const int port = 47321;

FirewallRule rule({
  bool allow = true,
  int profiles = FirewallProfile.public,
  int protocol = 6,
  String ports = '*',
  bool forApp = true,
}) =>
    FirewallRule(
      allow: allow,
      profiles: profiles,
      protocol: protocol,
      localPorts: ports,
      forApp: forApp,
    );

FirewallAccess access(
  List<FirewallRule> rules, {
  int current = FirewallProfile.public,
  int enabled = 7,
}) =>
    FirewallSnapshot(
      currentProfiles: current,
      enabledProfiles: enabled,
      rules: rules,
    ).accessFor(port);

void main() {
  group('доступ через брандмауэр', () {
    test('общедоступная сеть с разрешающим правилом для exe', () {
      expect(access([rule(protocol: 17), rule()]), FirewallAccess.allowed);
    });

    test('правил нет — доступа нет', () {
      expect(access(const []), FirewallAccess.missing);
    });

    test('правило только для частных сетей не годится в общедоступной', () {
      expect(
        access([rule(profiles: FirewallProfile.private)]),
        FirewallAccess.missing,
      );
      expect(
        access(
          [rule(profiles: FirewallProfile.private)],
          current: FirewallProfile.private,
        ),
        FirewallAccess.allowed,
      );
    });

    test('правило только для UDP не открывает TCP-порт', () {
      expect(access([rule(protocol: 17)]), FirewallAccess.missing);
    });

    test('правило «любой протокол» для exe подходит', () {
      expect(access([rule(protocol: 256, ports: '')]), FirewallAccess.allowed);
    });

    test('запрещающее правило сильнее разрешающего', () {
      expect(access([rule(), rule(allow: false)]), FirewallAccess.blocked);
    });

    test('выключенный брандмауэр ничего не блокирует', () {
      expect(access(const [], enabled: 3), FirewallAccess.allowed);
    });

    test('две активные сети: правило нужно на обеих', () {
      const both = FirewallProfile.private | FirewallProfile.public;
      expect(access([rule()], current: both), FirewallAccess.missing);
      expect(
        access([rule(profiles: 0x7FFFFFFF)], current: both),
        FirewallAccess.allowed,
      );
    });

    test('правило по порту без привязки к exe', () {
      expect(
        access([rule(forApp: false, ports: '80,47000-47999')]),
        FirewallAccess.allowed,
      );
      expect(
        access([rule(forApp: false, ports: '80,443')]),
        FirewallAccess.missing,
      );
      // Правило «все порты» без exe скрипт не выдаёт; на всякий случай
      // оно не считается разрешением.
      expect(access([rule(forApp: false)]), FirewallAccess.missing);
    });

    test('правило для exe с другим портом не подходит', () {
      expect(access([rule(ports: '5000')]), FirewallAccess.missing);
      expect(access([rule(ports: '$port')]), FirewallAccess.allowed);
    });
  });

  group('parseFirewallSnapshot', () {
    test('обычный вывод скрипта', () {
      final snapshot = parseFirewallSnapshot(
        '{"current":4,"enabled":7,"rules":['
        '{"action":1,"profiles":4,"protocol":17,"ports":"*","app":true},'
        '{"action":1,"profiles":4,"protocol":6,"ports":"*","app":true}]}\r\n',
      );
      expect(snapshot, isNotNull);
      expect(snapshot!.currentProfiles, 4);
      expect(snapshot.rules, hasLength(2));
      expect(snapshot.accessFor(port), FirewallAccess.allowed);
    });

    test('нет правил и одно правило объектом', () {
      expect(
        parseFirewallSnapshot('{"current":2,"enabled":7,"rules":[]}')!
            .accessFor(port),
        FirewallAccess.missing,
      );
      expect(
        parseFirewallSnapshot(
          '{"current":2,"enabled":7,"rules":'
          '{"action":0,"profiles":2147483647,"protocol":6,"ports":"*",'
          '"app":true}}',
        )!
            .accessFor(port),
        FirewallAccess.blocked,
      );
      expect(
        parseFirewallSnapshot('{"current":2,"enabled":7,"rules":null}')!
            .accessFor(port),
        FirewallAccess.missing,
      );
    });

    test('мусор — проверка не удалась', () {
      expect(parseFirewallSnapshot(''), isNull);
      expect(parseFirewallSnapshot('New-Object : access denied'), isNull);
      expect(parseFirewallSnapshot('[1,2]'), isNull);
      expect(parseFirewallSnapshot('{"current":"x","enabled":7}'), isNull);
    });
  });

  test('скрипт разрешения добавляет правило для exe и порта', () {
    final script = firewallAllowScript(r"C:\Апп's\minikanban.exe", port);
    expect(script, contains(r"$exe='C:\Апп''s\minikanban.exe'"));
    expect(script, contains('dir=in action=allow'));
    expect(script, contains('protocol=TCP localport=$port'));
    expect(script, contains('profile=private,public'));
  });
}
