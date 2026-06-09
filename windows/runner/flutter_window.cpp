// windows/runner/flutter_window.cpp

#include "flutter_window.h"

#include <optional>
#include <windows.h>

// Flutter C++ client-wrapper headers (exposed by flutter_wrapper_app)
#include <flutter/encodable_value.h>
#include <flutter/method_call.h>
#include <flutter/method_channel.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

static void SendKeyPress(WORD virtualKey);

static constexpr char kAutomationChannel[] = "com.aircanvas.automation/slides";

// ── Click-through child window subclass ──────────────────────────────────────
// Flutter's view is a child HWND. Hit-testing is per-HWND, so we must return
// HTTRANSPARENT from the child's WndProc too, otherwise mouse events are
// consumed by Flutter instead of falling through to the window below.
static WNDPROC g_origFlutterChildProc = nullptr;

static LRESULT CALLBACK ClickThroughChildProc(
    HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  if (msg == WM_NCHITTEST) return HTTRANSPARENT;
  return CallWindowProc(g_origFlutterChildProc, hwnd, msg, wp, lp);
}

// ── Constructor / Destructor ──────────────────────────────────────────────────

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {
  OnDestroy();
}

// ─────────────────────────────────────────────────────────────────────────────
// FlutterWindow::OnCreate
// ─────────────────────────────────────────────────────────────────────────────
bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);

  // Register all generated plugins.
  RegisterPlugins(flutter_controller_->engine());

  // ── Register the native MethodChannel ─────────────────────────────────────
  // flutter::MethodChannel uses a raw binary messenger from the engine.
  auto* messenger = flutter_controller_->engine()->messenger();

  auto channel = std::make_shared<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger,
      kAutomationChannel,
      &flutter::StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {

        const std::string& method = call.method_name();

        if (method == "swipeLeft") {
          // ── Simulate pressing the LEFT arrow key ──────────────────────────
          // This is equivalent to the presenter pressing ← on the keyboard,
          // which advances to the PREVIOUS slide in PowerPoint / Keynote.
          SendKeyPress(VK_LEFT);
          result->Success();

        } else if (method == "swipeRight") {
          // ── Simulate pressing the RIGHT arrow key ─────────────────────────
          // Equivalent to → on the keyboard – advances to the NEXT slide.
          SendKeyPress(VK_RIGHT);
          result->Success();

        } else {
          result->NotImplemented();
        }
      });

  // Keep the channel alive for the lifetime of the window.
  // We store it on the stack here via a lambda capture; in a production
  // codebase you would hold it as a member variable of FlutterWindow.
  // For simplicity we use a static local (process-lifetime).
  static std::shared_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      s_channel = channel;

  HWND childHwnd = flutter_controller_->view()->GetNativeWindow();

  // Install click-through subclass on the Flutter child HWND.
  g_origFlutterChildProc = reinterpret_cast<WNDPROC>(
      SetWindowLongPtr(childHwnd, GWLP_WNDPROC,
                       reinterpret_cast<LONG_PTR>(ClickThroughChildProc)));

  SetChildContent(childHwnd);

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  flutter_controller_->ForceRedraw();
  return true;
}

// ─────────────────────────────────────────────────────────────────────────────
// FlutterWindow::OnDestroy
// ─────────────────────────────────────────────────────────────────────────────
void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }
  Win32Window::OnDestroy();
}

// ─────────────────────────────────────────────────────────────────────────────
// FlutterWindow::MessageHandler
// ─────────────────────────────────────────────────────────────────────────────
LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

// ─────────────────────────────────────────────────────────────────────────────
// SendKeyPress  (internal Win32 helper)
// ─────────────────────────────────────────────────────────────────────────────
/// Synthesise a single physical key-down + key-up event pair for the given
/// virtual key code.  Because SendInput injects events at the hardware-input
/// level, they will be received by whichever window currently has focus
/// (i.e. the foreground presentation window) – exactly what we need.
///
/// @param virtualKey  A Win32 VK_* constant (e.g. VK_LEFT, VK_RIGHT).
static void SendKeyPress(WORD virtualKey) {
  // Two INPUT structures: one for key-down, one for key-up.
  INPUT inputs[2] = {};

  // ── Key DOWN ──────────────────────────────────────────────────────────────
  inputs[0].type        = INPUT_KEYBOARD;
  inputs[0].ki.wVk      = virtualKey;
  inputs[0].ki.wScan    = 0;
  inputs[0].ki.dwFlags  = 0;            // 0 = key press (down)
  inputs[0].ki.time     = 0;
  inputs[0].ki.dwExtraInfo = 0;

  // ── Key UP ────────────────────────────────────────────────────────────────
  inputs[1].type        = INPUT_KEYBOARD;
  inputs[1].ki.wVk      = virtualKey;
  inputs[1].ki.wScan    = 0;
  inputs[1].ki.dwFlags  = KEYEVENTF_KEYUP; // flag marks this as key release
  inputs[1].ki.time     = 0;
  inputs[1].ki.dwExtraInfo = 0;

  UINT sent = SendInput(
      static_cast<UINT>(ARRAYSIZE(inputs)), // number of events
      inputs,                               // event array
      sizeof(INPUT)                         // size of each element
  );

  // Defensive: log to debug output if the system rejected the injection.
  if (sent != ARRAYSIZE(inputs)) {
    OutputDebugStringW(L"[AirCanvas] SendInput failed – check UIPI permissions.\n");
  }
}
