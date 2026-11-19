/// IPv4-адреса ПК в локальной сети — кандидаты для QR-кода.
library;

import 'dart:io';

/// Адрес сетевого интерфейса.
final class LanAddress {
  const LanAddress({required this.interfaceName, required this.ip});

  final String interfaceName;
  final String ip;

  @override
  bool operator ==(Object other) =>
      other is LanAddress &&
      other.interfaceName == interfaceName &&
      other.ip == ip;

  @override
  int get hashCode => Object.hash(interfaceName, ip);

  @override
  String toString() => '$ip ($interfaceName)';
}

/// Виртуальные адаптеры и VPN-туннели: по их адресам телефон до ПК не
/// доберётся.
final RegExp _virtualInterface = RegExp(
  'vethernet|virtual|vmware|vbox|hyper-v|wsl|loopback|bluetooth|docker|'
  'tailscale|zerotier|wireguard|wintun|vpn|tap-|tunnel|npcap|pseudo|'
  r'xray|clash|sing-?box|nekoray|outline|(^|[\s_\-])(tun|tap|wg|utun)\d*($|[\s_\-])',
  caseSensitive: false,
);

bool _isPrivate(List<int> o) =>
    o[0] == 10 ||
    (o[0] == 172 && o[1] >= 16 && o[1] <= 31) ||
    (o[0] == 192 && o[1] == 168);

/// Отбирает адреса физических интерфейсов: без loopback, link-local
/// (169.254.x.x) и виртуальных адаптеров; частные сети — первыми.
/// Не больше [max] адресов, чтобы QR оставался читаемым.
List<LanAddress> filterLanCandidates(
  Iterable<LanAddress> addresses, {
  int max = 4,
}) {
  final private = <LanAddress>[];
  final other = <LanAddress>[];
  for (final address in addresses) {
    if (_virtualInterface.hasMatch(address.interfaceName)) continue;
    final List<int> octets;
    try {
      octets = Uri.parseIPv4Address(address.ip);
    } on FormatException {
      continue;
    }
    if (octets[0] == 127 || octets[0] == 0) continue;
    if (octets[0] == 169 && octets[1] == 254) continue;
    final target = _isPrivate(octets) ? private : other;
    if (!target.contains(address)) target.add(address);
  }
  return [...private, ...other].take(max).toList();
}

/// IPv4-кандидаты этого ПК.
Future<List<LanAddress>> lanIPv4Candidates() async {
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    return filterLanCandidates([
      for (final interface in interfaces)
        for (final address in interface.addresses)
          LanAddress(interfaceName: interface.name, ip: address.address),
    ]);
  } on Object {
    return const [];
  }
}
