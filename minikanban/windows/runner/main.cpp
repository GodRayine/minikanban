#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

// "Мини-канбан" (экранировано, чтобы не зависеть от кодировки файла).
const wchar_t kWindowTitle[] =
    L"\x041c\x0438\x043d\x0438-\x043a\x0430\x043d\x0431\x0430\x043d";
const wchar_t kWindowClass[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
const wchar_t kInstanceMutex[] = L"Local\\MiniKanban.SingleInstance";

// Приложение уже запущено (возможно, свёрнуто в трей): показываем его окно
// вместо запуска второго экземпляра со вторым сервером синхронизации.
bool ActivateRunningInstance() {
  ::CreateMutexW(nullptr, TRUE, kInstanceMutex);
  if (::GetLastError() != ERROR_ALREADY_EXISTS) {
    return false;
  }
  HWND existing = ::FindWindowW(kWindowClass, kWindowTitle);
  if (existing != nullptr) {
    ::ShowWindow(existing, ::IsIconic(existing) ? SW_RESTORE : SW_SHOW);
    ::SetForegroundWindow(existing);
  }
  return true;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  if (ActivateRunningInstance()) {
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  // --minimized (автозапуск с Windows): окно не показывается, приложение
  // остаётся в трее.
  bool start_hidden = false;
  for (const std::string& argument : command_line_arguments) {
    if (argument == "--minimized") {
      start_hidden = true;
    }
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  window.set_start_hidden(start_hidden);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(kWindowTitle, origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
