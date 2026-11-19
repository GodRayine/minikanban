/// Генерация идентификаторов (UUID v4) для карточек, изменений и устройств.
library;

import 'package:uuid/uuid.dart';

const Uuid _uuid = Uuid();

final RegExp _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

/// Новый случайный UUID v4 в нижнем регистре.
String newId() => _uuid.v4();

/// Похожа ли строка на UUID (в нижнем регистре, с дефисами).
bool isUuid(String value) => _uuidPattern.hasMatch(value);
