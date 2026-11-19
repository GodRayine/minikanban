# MiniKanban — план реализации (итог консилиума)

Участники консилиума: архитектор, эксперт по сети/синхронизации, UX-дизайнер, QA/риски.
Код пишет только модель Fable 5.2.

## 1. Предметная область (кратко)
- Доска из 3 фиксированных колонок: «Не начато» (todo), «В процессе» (doing), «Готово» (done).
- Карточка v1: заголовок (≤120, обязателен), описание (≤2000, необязательно), колонка, позиция. Меток и сроков в v1 нет.
- Устройства: один ПК Windows 10 (1809+)/11 — хаб и источник истины; один или несколько телефонов Android 15+ (API 35) — клиенты.
- Каждое устройство работает офлайн на своём SQLite; синхронизация — надстройка.
- Линковка: QR только на ПК, телефон сканирует. Связь по LAN «по имени» ПК.

## 2. Принятые решения (и спорные места, которые решил консилиум)
| Вопрос | Решение | Почему |
|---|---|---|
| Стек | **Flutter** (stable ≥3.27), один проект, платформы windows+android | один код на UI/БД/синк; сервер на чистом Dart; лучшая предсказуемость |
| SQLite | `sqflite` (Android) + `sqflite_common_ffi` (Windows) | без codegen |
| State | `flutter_riverpod` (без codegen) | |
| Топология | звезда: ПК = HTTPS-сервер (`shelf`), телефоны = клиенты | на Android нет входящих портов, нет конфликтов с Doze |
| Транспорт | **HTTPS, самоподписанный сертификат ПК, пиннинг SHA-256 отпечатка из QR** | Android блокирует cleartext; токен не идёт открытым текстом по Wi-Fi. Архитектор предлагал HTTP — отклонено по аргументу сети/QA |
| Обнаружение | 1) последний удачный IP → 2) DNS-SD `_minikanban._tcp` (TXT `sid`) через `nsd` → 3) `<host>.local` → 4) IP-кандидаты из QR; всегда проверка `server_id` через `/v1/hello`; ручной ввод адреса как запасной путь | mDNS ненадёжен, нужен каскад |
| Конфликты | **LWW по полям** (title, description, column, pos, deleted) с HLC на каждое поле; курсор — монотонный `server_seq` на ПК | правка названия и перенос карточки не затирают друг друга; устойчиво к расхождению часов |
| Удаление | tombstone (`deleted=1`) как обычное поле; чистка на ПК через 90 дней; старый курсор → 410 → полный reset | |
| Порядок | дробный строковый индекс (base62, midpoint), сортировка `(pos, id)` | перенос меняет одну строку |
| Идемпотентность | outbox на клиенте, `change_id` (uuid), ПК помнит применённые id 30 дней | безопасные повторы |
| Расписание | resume + `Timer` 5 мин пока приложение открыто + debounce 2–3 с после локальной правки + кнопка/pull-to-refresh; в фоне WorkManager 15 мин | Android не даёт периодику чаще 15 мин в фоне |
| ПК в фоне | сворачивание в трей (сервер работает), автозапуск выключен по умолчанию | |
| Брандмауэр | инструкция + проверка в приложении; правило TCP 47321 для профиля Private (в установщике — позже) | |

## 3. Протокол (v1)
- `GET /v1/hello` → `{server_id, server_name, proto:1, time}` (без авторизации)
- `POST /v1/pair {code, device_id, device_name, platform}` → `{device_token, server_id, server_name}`; код одноразовый, 5 минут, ≤5 попыток/мин; на ПК хранится только хэш токена.
- `POST /v1/sync` (Bearer) `{cursor, changes:[{change_id, entity:"card", id, fields:{...}, hlc:{field:hlc}}], limit:500}` → `{applied:[change_id], changes:[...], cursor, has_more}`
- 401 `revoked` → клиент «Отвязано»; 410 → полный reset; несовпадение `proto` → «Несовместимая версия».
- QR: `mkanban://pair?v=1&sid=&name=&h=&ip=a,b&p=47321&c=<code>&fp=<sha256 spki b64url>&exp=<unix>`

## 4. Схема БД
- `cards(id PK, title, description, column INT 0..2, pos TEXT, deleted INT, created_at, hlc_title, hlc_description, hlc_column, hlc_pos, hlc_deleted, server_seq INT)`; индексы `(column, deleted, pos)`, `(server_seq)`.
- `outbox(change_id PK, card_id, fields_json, hlc_json, created_at)` — клиент.
- `applied_changes(change_id PK, applied_at)` — ПК.
- `devices(device_id PK, name, platform, token_hash, paired_at, last_sync_at, revoked)` — ПК.
- `meta(key PK, value)` — device_id, server_id, seq_counter, cursor, hlc_last, server_host/ips/port/fp/token(token — в secure storage).
- Версия схемы — `PRAGMA user_version`, последовательные миграции.

## 5. Структура `minikanban/lib`
```
core/      hlc.dart, ids.dart, fractional_index.dart, platform_role.dart
domain/    card.dart, board_repository.dart
data/      db.dart (open + migrations), card_dao.dart, outbox_dao.dart, device_dao.dart, meta_dao.dart
sync/protocol/  dto.dart, merge.dart, qr_payload.dart
sync/server/    sync_server.dart, pairing_service.dart, cert_service.dart, nsd_advertiser.dart   (Windows)
sync/client/    sync_client.dart, host_resolver.dart, sync_scheduler.dart                     (Android)
features/board/    board_page.dart, column_view.dart, card_tile.dart, card_editor.dart, board_controller.dart
features/pairing/  pair_pc_page.dart (QR + устройства), scan_page.dart, pairing_controller.dart
features/settings/ settings_page.dart, sync_status_chip.dart
```

## 6. Этапы
- **M0** Тулчейн: git, Flutter, VS Build Tools (C++), Android Studio/SDK 35 → `flutter doctor` зелёный.
- **M1** Ядро на чистом Dart: HLC, fractional index, Card, merge, DTO, QR payload + unit-тесты.
- **M2** БД + репозиторий + доска на Windows (CRUD, drag&drop, клавиатура).
- **M3** Доска на Android (вкладки + pager, bottom sheet «Переместить в…», свайп).
- **M4** Сервер ПК: HTTPS, /hello /pair /sync, NSD, экран QR + устройства.
- **M5** Клиент Android: сканер, пейринг, каскад поиска, outbox, планировщик, статус-чип.
- **M6** Интеграционные тесты сервер+клиент в одном процессе; ошибки/офлайн; release-сборки.

## 7. Критерии приёмки (DoD MVP)
1. Сборки Windows release и Android release APK (targetSdk 35).
2. CRUD и перенос карточек, данные переживают перезапуск на обеих платформах.
3. Привязка по QR < 30 с; есть ручной ввод адреса.
4. Изменение видно на другой стороне: при открытии телефона < 10 с; при открытом приложении ≤ 5 мин.
5. Конфликты по LWW-полям покрыты тестами; без токена — 401; обрыв посреди синка не портит БД.
6. После смены IP ПК синк восстанавливается без повторного QR (если mDNS работает), иначе подсказка.
7. Unit + интеграционные тесты зелёные; ручной E2E-чеклист на реальном телефоне Android 15+.

## 8. Риски (топ)
Брандмауэр/сеть «Общедоступная»; AP isolation/гостевой Wi-Fi (только понятная ошибка); mDNS режется роутером; DHCP меняет IP; лимит WorkManager; Android 16 local-network permission; нет физического телефона у агента — E2E делает заказчик.
