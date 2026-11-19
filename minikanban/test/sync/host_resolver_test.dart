import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:minikanban/sync/client/host_resolver.dart';
import 'package:minikanban/sync/client/sync_api.dart';
import 'package:minikanban/sync/protocol/dto.dart';
import 'package:minikanban/sync/server/network_info.dart';

const sid = 'server-1';
const port = 47321;

HelloResponse hello([String serverId = sid, int proto = protocolVersion]) =>
    HelloResponse(
      serverId: serverId,
      serverName: 'PC',
      time: 0,
      proto: proto,
    );

/// Фейковая сеть: что отвечает каждый адрес на `/v1/hello`.
class FakeNetwork {
  final Map<Endpoint, FutureOr<HelloResponse> Function()> hosts = {};
  final List<Endpoint> probed = [];
  final Map<Endpoint, Duration> timeouts = {};

  Future<HelloResponse> probe(Endpoint endpoint, Duration timeout) async {
    probed.add(endpoint);
    timeouts[endpoint] = timeout;
    final answer = hosts[endpoint];
    if (answer == null) {
      throw SyncNetworkException('Нет соединения с $endpoint');
    }
    return answer();
  }
}

void main() {
  late FakeNetwork net;
  var discoveries = 0;
  List<Endpoint> discovered = [];

  setUp(() {
    net = FakeNetwork();
    discoveries = 0;
    discovered = [];
  });

  HostResolver resolver({bool withDiscovery = true}) => HostResolver(
        probe: net.probe,
        discover: withDiscovery
            ? (serverId, timeout) async {
                discoveries++;
                expect(serverId, sid);
                expect(timeout, const Duration(seconds: 3));
                return discovered;
              }
            : null,
      );

  const lastGood = Endpoint('192.168.1.10', port);
  const viaNsd = Endpoint('192.168.1.77', 50000);
  const qrIp = Endpoint('192.168.1.42', port);

  test('последний удачный адрес — первым, с таймаутом 1.5 с', () async {
    net.hosts[lastGood] = hello;
    net.hosts[qrIp] = hello;

    final found = await resolver().resolve(
      serverId: sid,
      lastGood: lastGood,
      ips: [qrIp.host],
      port: port,
    );

    expect(found.endpoint, lastGood);
    expect(found.source, HostSource.lastGood);
    expect(net.probed, [lastGood]);
    expect(net.timeouts[lastGood], const Duration(milliseconds: 1500));
    expect(discoveries, 0);
  });

  test('адрес сменился: находит через DNS-SD', () async {
    discovered = [viaNsd];
    net.hosts[viaNsd] = hello;

    final found = await resolver().resolve(
      serverId: sid,
      lastGood: lastGood,
      ips: [qrIp.host],
      port: port,
    );

    expect(found.endpoint, viaNsd);
    expect(found.source, HostSource.nsd);
    expect(discoveries, 1);
    expect(net.probed, [lastGood, viaNsd]);
  });

  test('DNS-SD молчит: имя ПК, затем IP из QR', () async {
    net.hosts[qrIp] = hello;

    final found = await resolver().resolve(
      serverId: sid,
      lastGood: lastGood,
      hostName: 'DESKTOP-7K2M',
      ips: ['192.168.1.41', qrIp.host],
      port: port,
    );

    expect(found.endpoint, qrIp);
    expect(found.source, HostSource.qrIp);
    expect(net.probed, [
      lastGood,
      const Endpoint('DESKTOP-7K2M.local', port),
      const Endpoint('DESKTOP-7K2M', port),
      const Endpoint('192.168.1.41', port),
      qrIp,
    ]);
  });

  test('имя ПК с .local срабатывает раньше IP', () async {
    const byName = Endpoint('desktop.local', port);
    net.hosts[byName] = hello;
    net.hosts[qrIp] = hello;

    final found = await resolver(withDiscovery: false).resolve(
      serverId: sid,
      hostName: 'desktop',
      ips: [qrIp.host],
      port: port,
    );
    expect(found.endpoint, byName);
    expect(found.source, HostSource.hostName);
  });

  test('чужой сервер на том же адресе пропускается', () async {
    net.hosts[lastGood] = () => hello('someone-else');
    net.hosts[qrIp] = hello;

    final found = await resolver().resolve(
      serverId: sid,
      lastGood: lastGood,
      ips: [qrIp.host],
      port: port,
    );
    expect(found.endpoint, qrIp);
  });

  test('при привязке IP из QR проверяются первыми', () async {
    net.hosts[qrIp] = hello;
    discovered = [viaNsd];
    net.hosts[viaNsd] = hello;

    final found = await resolver().resolve(
      serverId: sid,
      ips: [qrIp.host],
      port: port,
      ipsFirst: true,
    );
    expect(found.endpoint, qrIp);
    expect(discoveries, 0);
  });

  test('из нескольких IP выбирается ответивший', () async {
    const slow = Endpoint('10.0.0.1', port);
    const fast = Endpoint('10.0.0.2', port);
    final gate = Completer<HelloResponse>();
    net.hosts[slow] = () => gate.future;
    net.hosts[fast] = hello;

    final found = await resolver(withDiscovery: false).resolve(
      serverId: sid,
      ips: [slow.host, fast.host],
      port: port,
    );
    expect(found.endpoint, fast);
    gate.complete(hello());
  });

  test('один и тот же адрес не проверяется дважды', () async {
    discovered = [lastGood];
    await expectLater(
      resolver().resolve(
        serverId: sid,
        lastGood: lastGood,
        ips: [lastGood.host],
        port: port,
      ),
      throwsA(isA<HostNotFoundException>()),
    );
    expect(net.probed, [lastGood]);
  });

  test('никого нет — HostNotFoundException', () async {
    await expectLater(
      resolver().resolve(serverId: sid, ips: ['10.0.0.9'], port: port),
      throwsA(isA<HostNotFoundException>()),
    );
    expect(discoveries, 1);
  });

  test('сбой DNS-SD не мешает остальным способам', () async {
    net.hosts[qrIp] = hello;
    final found = await HostResolver(
      probe: net.probe,
      discover: (_, __) async => throw StateError('mDNS запрещён'),
    ).resolve(serverId: sid, ips: [qrIp.host], port: port);
    expect(found.endpoint, qrIp);
  });

  test('чужой сертификат и больше никого — SyncCertException', () async {
    net.hosts[qrIp] = () => throw const SyncCertException();
    await expectLater(
      resolver().resolve(serverId: sid, ips: [qrIp.host], port: port),
      throwsA(isA<SyncCertException>()),
    );
  });

  test('другая версия протокола — SyncIncompatibleException', () async {
    net.hosts[qrIp] = () => hello(sid, protocolVersion + 1);
    await expectLater(
      resolver().resolve(serverId: sid, ips: [qrIp.host], port: port),
      throwsA(isA<SyncIncompatibleException>()),
    );
  });

  group('Endpoint', () {
    test('разбор адреса', () {
      expect(
        Endpoint.tryParse('192.168.1.42:8765'),
        const Endpoint('192.168.1.42', 8765),
      );
      expect(
        Endpoint.tryParse(' desktop.local ', defaultPort: 47321),
        const Endpoint('desktop.local', 47321),
      );
      expect(
        Endpoint.tryParse('[fe80::1]:47321'),
        const Endpoint('fe80::1', 47321),
      );
      expect(Endpoint.tryParse('192.168.1.42'), isNull);
      expect(Endpoint.tryParse('192.168.1.42:0'), isNull);
      expect(Endpoint.tryParse('192.168.1.42:99999'), isNull);
      expect(Endpoint.tryParse('http://x/y', defaultPort: 1), isNull);
      expect(Endpoint.tryParse('', defaultPort: 1), isNull);
    });

    test('строковый вид разбирается обратно', () {
      for (final e in const [
        Endpoint('10.0.0.1', 47321),
        Endpoint('fe80::1', 1234),
      ]) {
        expect(Endpoint.tryParse(e.toString()), e);
      }
    });
  });

  group('IP-кандидаты ПК', () {
    LanAddress a(String name, String ip) =>
        LanAddress(interfaceName: name, ip: ip);

    test('без виртуальных адаптеров, loopback и link-local', () {
      expect(
        filterLanCandidates([
          a('vEthernet (WSL)', '172.18.0.1'),
          a('Loopback Pseudo-Interface 1', '127.0.0.1'),
          a('Ethernet', '169.254.10.20'),
          a('VirtualBox Host-Only Network', '192.168.56.1'),
          a('xray_tun', '172.18.0.1'),
          a('wg0', '10.8.0.2'),
          a('OpenVPN TAP-Windows6', '10.9.0.2'),
          a('Wi-Fi', '192.168.1.42'),
          a('Ethernet', '10.0.0.5'),
          a('Wi-Fi', '192.168.1.42'),
          a('Беспроводная сеть', '192.168.1.50'),
        ]),
        [
          a('Wi-Fi', '192.168.1.42'),
          a('Ethernet', '10.0.0.5'),
          a('Беспроводная сеть', '192.168.1.50'),
        ],
      );
    });

    test('частные сети первыми, не больше четырёх', () {
      final result = filterLanCandidates([
        a('Ethernet 2', '203.0.113.7'),
        for (var i = 1; i <= 5; i++) a('Ethernet', '192.168.$i.1'),
      ]);
      expect(result, hasLength(4));
      expect(result.every((e) => e.ip.startsWith('192.168.')), isTrue);
    });
  });
}
