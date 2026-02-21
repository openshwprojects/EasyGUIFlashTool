#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <iostream>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Parse command-line arguments early so we know whether we're in CLI mode.
  std::vector<std::string> command_line_arguments = GetCommandLineArguments();
  bool has_cli_args = !command_line_arguments.empty();

  // Attach to the parent console so that stdout/stderr from Dart are visible.
  // When running from cmd.exe or PowerShell, AttachConsole succeeds.
  // When running standalone with CLI args, allocate a new console.
  // When running without args (GUI mode), only attach if a debugger is present.
  if (::AttachConsole(ATTACH_PARENT_PROCESS)) {
    // Successfully attached to parent console (e.g. PowerShell / cmd.exe).
    // Reopen stdout/stderr so Dart's output reaches the terminal.
    FILE *unused;
    freopen_s(&unused, "CONOUT$", "w", stdout);
    freopen_s(&unused, "CONOUT$", "w", stderr);
    std::ios::sync_with_stdio();
    FlutterDesktopResyncOutputStreams();
  } else {
    if (has_cli_args || ::IsDebuggerPresent()) {
      CreateAndAttachConsole();
    }
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");
  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);

  // In CLI mode, create a hidden window — the Flutter engine still needs
  // a Win32Window to host the Dart isolate, but we don't want it visible.
  // Dart's exit() will terminate the process once the CLI work is done.
  if (!window.Create(L"EasyGUIFlashTool", origin, size)) {
    return EXIT_FAILURE;
  }

  if (has_cli_args) {
    // Hide the Flutter window — only the console should be visible.
    HWND hwnd = window.GetHandle();
    if (hwnd) {
      ::ShowWindow(hwnd, SW_HIDE);
    }
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
