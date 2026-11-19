/// Оболочка ПК: закрытие окна сворачивает приложение в трей (сервер
/// синхронизации продолжает работать), автозапуск с Windows.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// Аргумент командной строки: запуск свёрнутым в трей (автозапуск).
/// Его же разбирает `windows/runner/main.cpp`, чтобы не показывать окно.
const String startMinimizedArg = '--minimized';

class DesktopShell with WindowListener, TrayListener {
  DesktopShell._();

  static const String _trayIcon = 'assets/app_icon.ico';

  bool _trayReady = false;
  bool _quitting = false;

  /// Вызывается перед выходом из приложения (остановить сервер).
  Future<void> Function()? onQuit;

  /// Работает ли значок в трее. Без него закрытие окна завершает
  /// приложение как обычно — иначе окно было бы не вернуть.
  bool get trayReady => _trayReady;

  /// Настраивает окно, трей и автозапуск. Ошибки плагинов не мешают
  /// работе приложения — недоступная возможность просто отключается.
  static Future<DesktopShell?> init() async {
    if (!Platform.isWindows) return null;
    final shell = DesktopShell._();
    try {
      launchAtStartup.setup(
        appName: 'MiniKanban',
        appPath: Platform.resolvedExecutable,
        args: const [startMinimizedArg],
      );
    } on Object catch (error) {
      debugPrint('Автозапуск недоступен: $error');
    }
    try {
      await windowManager.ensureInitialized();
      await trayManager.setIcon(_trayIcon);
      await trayManager.setToolTip('Мини-канбан');
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'show', label: 'Открыть Мини-канбан'),
            MenuItem.separator(),
            MenuItem(key: 'quit', label: 'Выход'),
          ],
        ),
      );
      trayManager.addListener(shell);
      windowManager.addListener(shell);
      await windowManager.setPreventClose(true);
      shell._trayReady = true;
    } on Object catch (error) {
      debugPrint('Трей недоступен: $error');
    }
    return shell;
  }

  /// Показывает окно и переводит на него фокус.
  Future<void> showWindow() async {
    try {
      await windowManager.show();
      await windowManager.focus();
    } on Object catch (error) {
      debugPrint('Не удалось показать окно: $error');
    }
  }

  /// Завершает приложение (пункт «Выход» в трее).
  Future<void> quit() async {
    if (_quitting) return;
    _quitting = true;
    try {
      await onQuit?.call().timeout(const Duration(seconds: 3));
    } on Object catch (error) {
      debugPrint('Ошибка при завершении: $error');
    }
    try {
      await trayManager.destroy();
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    } on Object {
      exit(0);
    }
  }

  // --- Автозапуск -----------------------------------------------------------

  Future<bool> autostartEnabled() async {
    try {
      return await launchAtStartup.isEnabled();
    } on Object {
      return false;
    }
  }

  /// Включает/выключает запуск вместе с Windows; возвращает новое
  /// состояние.
  Future<bool> setAutostart(bool enabled) async {
    try {
      if (enabled) {
        await launchAtStartup.enable();
      } else {
        await launchAtStartup.disable();
      }
    } on Object catch (error) {
      debugPrint('Не удалось изменить автозапуск: $error');
    }
    return autostartEnabled();
  }

  // --- События окна и трея --------------------------------------------------

  @override
  void onWindowClose() {
    if (_quitting) return;
    if (_trayReady) {
      unawaited(windowManager.hide());
    } else {
      unawaited(quit());
    }
  }

  @override
  void onTrayIconMouseDown() => unawaited(showWindow());

  @override
  void onTrayIconRightMouseDown() => unawaited(trayManager.popUpContextMenu());

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        unawaited(showWindow());
      case 'quit':
        unawaited(quit());
    }
  }
}
