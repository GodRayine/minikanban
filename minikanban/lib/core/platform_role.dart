/// Роль устройства в синхронизации: ПК — хаб, телефон — клиент.
library;

import 'package:flutter/foundation.dart';

enum PlatformRole {
  /// ПК (Windows): источник истины, назначает `server_seq`, показывает QR.
  hub,

  /// Телефон (Android): копит правки в outbox и отправляет их хабу.
  client;

  bool get isHub => this == hub;
}

/// Роль по текущей платформе: настольные ОС — хаб, остальные — клиент.
PlatformRole detectPlatformRole() => switch (defaultTargetPlatform) {
      TargetPlatform.windows ||
      TargetPlatform.linux ||
      TargetPlatform.macOS =>
        PlatformRole.hub,
      _ => PlatformRole.client,
    };
