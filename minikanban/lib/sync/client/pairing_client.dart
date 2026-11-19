/// Привязка телефона к ПК: по QR (отпечаток известен заранее) или
/// вручную по адресу и коду.
library;

import '../../data/board_repository_impl.dart';
import '../../data/meta_dao.dart';
import '../crypto_util.dart';
import '../protocol/dto.dart';
import '../protocol/qr_payload.dart';
import 'client_store.dart';
import 'host_resolver.dart';
import 'sync_api.dart';

import 'package:sqflite_common/sqlite_api.dart';

/// Почему привязка не удалась.
enum PairingError {
  /// Код просрочен, неверен или уже использован.
  codeRejected,

  /// Слишком много попыток за минуту.
  rateLimited,

  /// ПК не найден в сети.
  notFound,

  /// Сертификат/подлинность ПК не подтверждены.
  untrusted,

  /// Несовместимые версии приложения.
  incompatible,

  /// Введённые данные некорректны.
  invalidInput,
}

/// Ошибка привязки с текстом для пользователя.
class PairingException implements Exception {
  const PairingException(this.error, this.message, {this.hint});

  final PairingError error;
  final String message;

  /// Что попробовать (вторая строка на экране ошибки).
  final String? hint;

  static const PairingException codeExpired = PairingException(
    PairingError.codeRejected,
    'Код устарел — обновите его на компьютере',
    hint: 'Нажмите «Обновить код» на компьютере и отсканируйте новый QR-код.',
  );

  static const PairingException notFound = PairingException(
    PairingError.notFound,
    'Компьютер не найден',
    hint: 'Разные сети Wi-Fi? Подключите телефон и компьютер к одной сети '
        'и проверьте, что брандмауэр Windows разрешает «Мини-канбан» '
        'в частных сетях.',
  );

  static const PairingException untrusted = PairingException(
    PairingError.untrusted,
    'Не удалось проверить компьютер',
    hint: 'Сертификат не совпал с кодом подключения. Обновите код на '
        'компьютере и попробуйте ещё раз.',
  );

  static const PairingException incompatible = PairingException(
    PairingError.incompatible,
    'Несовместимая версия',
    hint: 'Обновите «Мини-канбан» на телефоне и на компьютере.',
  );

  static const PairingException rateLimited = PairingException(
    PairingError.rateLimited,
    'Слишком много попыток',
    hint: 'Подождите минуту и попробуйте снова.',
  );

  @override
  String toString() => 'PairingException(${error.name}): $message';
}

/// Разобранный ручной ввод.
sealed class ManualPairingInput {
  const ManualPairingInput();
}

/// Вставлена строка `mkanban://…` — то же, что QR.
final class ManualPayload extends ManualPairingInput {
  const ManualPayload(this.payload);

  final PairingQrPayload payload;
}

/// Введены адрес и код.
final class ManualAddress extends ManualPairingInput {
  const ManualAddress(this.endpoint, this.code);

  final Endpoint endpoint;
  final String code;
}

class PairingClient {
  PairingClient({
    required Database db,
    required BoardRepositoryImpl repository,
    required this.store,
    required Future<String> Function() deviceName,
    this.platform = 'android',
    SyncApiFactory apiFactory = defaultSyncApiFactory,
    ServiceDiscovery? discover,
    DateTime Function()? now,
  })  : _db = db,
        _repository = repository,
        _deviceName = deviceName,
        _apiFactory = apiFactory,
        _discover = discover,
        _now = now ?? DateTime.now;

  final Database _db;
  final BoardRepositoryImpl _repository;
  final Future<String> Function() _deviceName;
  final SyncApiFactory _apiFactory;
  final ServiceDiscovery? _discover;
  final DateTime Function() _now;

  final ClientStore store;
  final String platform;

  /// Разбирает ручной ввод: строку `mkanban://…` целиком в поле адреса
  /// либо адрес `IP:порт` (порт по умолчанию 47321) и код.
  /// Бросает [PairingException] с понятным текстом.
  ManualPairingInput parseManual(String address, String code) {
    final text = address.trim();
    if (text.toLowerCase().startsWith('${PairingQrPayload.scheme}:')) {
      return ManualPayload(parsePayload(text));
    }
    final endpoint = Endpoint.tryParse(
      text,
      defaultPort: PairingQrPayload.defaultPort,
    );
    if (endpoint == null) {
      throw const PairingException(
        PairingError.invalidInput,
        'Некорректный адрес',
        hint: 'Введите адрес как на экране компьютера, например '
            '192.168.1.42:47321.',
      );
    }
    final trimmedCode = code.trim();
    if (trimmedCode.isEmpty) {
      throw const PairingException(
        PairingError.invalidInput,
        'Введите код',
        hint: 'Код показан на компьютере под QR-кодом.',
      );
    }
    return ManualAddress(endpoint, trimmedCode);
  }

  /// Разбирает содержимое QR; ошибки формата — [PairingException].
  PairingQrPayload parsePayload(String raw) {
    try {
      return PairingQrPayload.parse(raw, now: _now());
    } on QrPayloadException catch (e) {
      if (e.error == QrPayloadError.expired) {
        throw PairingException.codeExpired;
      }
      throw PairingException(
        e.error == QrPayloadError.unsupportedVersion
            ? PairingError.incompatible
            : PairingError.invalidInput,
        e.message,
      );
    }
  }

  /// Привязка по данным QR. Сертификат ПК проверяется по отпечатку из QR.
  Future<ServerLink> pairWithPayload(PairingQrPayload payload) async {
    if (payload.isExpired(_now())) throw PairingException.codeExpired;
    final api = _apiFactory(payload.fingerprint);
    try {
      final resolved = await HostResolver(
        probe: (endpoint, timeout) => api.hello(endpoint, timeout: timeout),
        discover: _discover,
      ).resolve(
        serverId: payload.serverId,
        hostName: payload.host,
        ips: payload.ips,
        port: payload.port,
        ipsFirst: true,
      );
      final reply = await api.pair(
        resolved.endpoint,
        PairRequest(
          code: payload.code,
          deviceId: _repository.deviceId,
          deviceName: await _safeDeviceName(),
          platform: platform,
        ).toJson(),
      );
      if (reply.response.serverId != payload.serverId) {
        throw PairingException.untrusted;
      }
      final link = ServerLink(
        serverId: payload.serverId,
        serverName: reply.response.serverName,
        host: payload.host,
        ips: payload.ips,
        port: resolved.endpoint.port,
        fingerprint: payload.fingerprint,
        lastGood: resolved.endpoint,
      );
      await _finish(link, reply.response.deviceToken);
      return link;
    } on SyncException catch (e) {
      throw _translate(e);
    } finally {
      api.close();
    }
  }

  /// Привязка по адресу и коду, введённым вручную.
  ///
  /// Отпечатка из QR здесь нет, поэтому сертификат, увиденный при
  /// подключении, связывается с кодом: телефон отправляет не сам код, а
  /// HMAC от кода и отпечатка, и ждёт от ПК ответный HMAC. Посредник с
  /// другим сертификатом не пройдёт ни одну из проверок.
  Future<ServerLink> pairManually(Endpoint endpoint, String code) async {
    final api = _apiFactory(null);
    try {
      final hello =
          await api.hello(endpoint, timeout: const Duration(seconds: 5));
      if (!hello.isCompatible) throw PairingException.incompatible;
      final fingerprint = api.seenFingerprint(endpoint);
      if (fingerprint == null) throw PairingException.untrusted;
      final deviceId = _repository.deviceId;

      final reply = await api.pair(endpoint, {
        'code_proof': pairingClientProof(
          code: code,
          fingerprint: fingerprint,
          deviceId: deviceId,
        ),
        'device_id': deviceId,
        'device_name': await _safeDeviceName(),
        'platform': platform,
      });
      final expected = pairingServerProofFromHash(
        codeHash: sha256Hex(code),
        fingerprint: fingerprint,
        deviceId: deviceId,
      );
      final proof = reply.serverProof;
      if (proof == null ||
          !constantTimeEquals(proof, expected) ||
          api.seenFingerprint(endpoint) != fingerprint ||
          reply.response.serverId != hello.serverId) {
        throw PairingException.untrusted;
      }
      final link = ServerLink(
        serverId: hello.serverId,
        serverName: reply.response.serverName,
        host: '',
        ips: [endpoint.host],
        port: endpoint.port,
        fingerprint: fingerprint,
        lastGood: endpoint,
      );
      await _finish(link, reply.response.deviceToken);
      return link;
    } on SyncException catch (e) {
      throw _translate(e);
    } finally {
      api.close();
    }
  }

  Future<String> _safeDeviceName() async {
    try {
      final name = (await _deviceName()).trim();
      if (name.isEmpty) return 'Телефон';
      return name.length > 64 ? name.substring(0, 64) : name;
    } on Object {
      return 'Телефон';
    }
  }

  Future<void> _finish(ServerLink link, String token) async {
    final previous = await store.knownServerId();
    if (previous != null && previous != link.serverId) {
      // Другой ПК: его история нумеруется заново, и о наших карточках
      // он ничего не знает — отправим ему всё.
      final meta = MetaDao(_db);
      await meta.setCursor(0);
      await meta.remove(MetaKeys.resetPending);
      await _repository.enqueueFullState();
    }
    await store.saveLink(link, token: token);
  }

  static PairingException _translate(SyncException e) => switch (e) {
        PairingRejectedException(reason: 'rate_limited') =>
          PairingException.rateLimited,
        PairingRejectedException() => PairingException.codeExpired,
        SyncCertException() => PairingException.untrusted,
        SyncIncompatibleException() => PairingException.incompatible,
        SyncUnauthorizedException() ||
        SyncGoneException() ||
        SyncNetworkException() =>
          PairingException.notFound,
      };
}
