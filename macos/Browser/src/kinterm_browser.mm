// KinTerm's browser module: Chromium (CEF) behind a small C API.
//
// KinTerm doesn't link this. It loads it with dlopen the first time a
// browser is opened, so a KinTerm that never opens one never loads
// Chromium. Everything here runs on the main thread: CEF is set up with an
// external message pump that runs on the main run loop, only while it has
// work.
//
// See macos/Browser/README.md.

#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>

#include <algorithm>
#include <functional>
#include <set>
#include <string>

#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_parser.h"
#include "include/wrapper/cef_library_loader.h"

#define KT_EXPORT extern "C" __attribute__((visibility("default")))

// Events reported to KinTerm, see kt_event_fn.
enum {
  KT_EVENT_CREATED = 0,
  KT_EVENT_ADDRESS = 1,
  KT_EVENT_TITLE = 2,
  KT_EVENT_LOADING = 3,  // a: loading, b: can go back | can go forward << 1
  KT_EVENT_CLOSED = 4,
  KT_EVENT_CONSOLE_ERROR = 5,  // value: the message
  KT_EVENT_LOAD_ERROR = 6,     // value: the error text, a: the error code
  KT_EVENT_DEVTOOLS = 7,       // a: DevTools open
  KT_EVENT_TARGET = 8,         // value: the page's DevTools target id
  KT_EVENT_PICK = 9,           // value: a message from KinTerm's element picker
};

// Console messages starting with this are from KinTerm's element picker
// (see ElementPicker.swift), not the page's own: they go to KinTerm and
// not to the console.
static const char kPickPrefix[] = "__kintermPick:";

// Edit commands, see kt_browser_edit.
enum { KT_EDIT_UNDO = 0, KT_EDIT_REDO, KT_EDIT_CUT, KT_EDIT_COPY, KT_EDIT_PASTE, KT_EDIT_SELECT_ALL };

static void RunEdit(CefRefPtr<CefBrowser> browser, int command) {
  if (!browser) return;
  CefRefPtr<CefFrame> frame = browser->GetFocusedFrame();
  if (!frame) frame = browser->GetMainFrame();
  if (!frame) return;
  switch (command) {
    case KT_EDIT_UNDO: frame->Undo(); break;
    case KT_EDIT_REDO: frame->Redo(); break;
    case KT_EDIT_CUT: frame->Cut(); break;
    case KT_EDIT_COPY: frame->Copy(); break;
    case KT_EDIT_PASTE: frame->Paste(); break;
    case KT_EDIT_SELECT_ALL: frame->SelectAll(); break;
  }
}

// The edit command a ⌘ key is, or -1. Edit shortcuts are handled here, not
// through the menu: KinTerm's Edit menu belongs to the terminal (its
// shortcuts follow the terminal's keybindings), so ⌘V in a page must not
// depend on it.
static int EditCommandForKey(const CefKeyEvent& event, NSEvent* ns_event) {
  if (event.type != KEYEVENT_RAWKEYDOWN) return -1;
  uint32_t mods = event.modifiers & (EVENTFLAG_COMMAND_DOWN | EVENTFLAG_SHIFT_DOWN | EVENTFLAG_CONTROL_DOWN |
                                     EVENTFLAG_ALT_DOWN);
  NSString* key = ns_event.charactersIgnoringModifiers.lowercaseString;
  if (key.length != 1) return -1;
  unichar c = [key characterAtIndex:0];
  if (mods == EVENTFLAG_COMMAND_DOWN) {
    switch (c) {
      case 'z': return KT_EDIT_UNDO;
      case 'x': return KT_EDIT_CUT;
      case 'c': return KT_EDIT_COPY;
      case 'v': return KT_EDIT_PASTE;
      case 'a': return KT_EDIT_SELECT_ALL;
    }
  }
  if (mods == (EVENTFLAG_COMMAND_DOWN | EVENTFLAG_SHIFT_DOWN) && c == 'z') return KT_EDIT_REDO;
  return -1;
}

typedef void (*kt_event_fn)(void* context, int kind, const char* value, int a, int b);

// MARK: - NSApplication support CEF needs

// Chromium asks NSApp whether it's in the middle of sendEvent:. CEF expects
// the app's NSApplication class to answer; KinTerm uses NSApplication as it
// is, so the methods are added to it here, when the module is loaded.

static BOOL g_handling_send_event = NO;

@interface NSApplication (KinTermBrowser) <CefAppProtocol>
@end

@implementation NSApplication (KinTermBrowser)
- (BOOL)isHandlingSendEvent {
  return g_handling_send_event;
}

- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
  g_handling_send_event = handlingSendEvent;
}

- (void)kt_sendEvent:(NSEvent*)event {
  // After the swizzle this calls the original sendEvent:.
  CefScopedSendingEvent sending;
  [self kt_sendEvent:event];
}
@end

static void InstallSendEventHook() {
  static bool installed = false;
  if (installed) return;
  installed = true;
  Class cls = [NSApplication class];
  Method original = class_getInstanceMethod(cls, @selector(sendEvent:));
  Method replacement = class_getInstanceMethod(cls, @selector(kt_sendEvent:));
  method_exchangeImplementations(original, replacement);
}

// MARK: - Message pump

// CEF tells us when it has work (OnScheduleMessagePumpWork, from any
// thread). The work runs on the main run loop. While a browser is open a
// slow timer also keeps it going, as CEF's own samples do; with no browsers
// open nothing runs until CEF asks.

static const int64_t kMaxTimerDelayMs = 1000 / 30;
static NSTimer* g_pump_timer = nil;
static bool g_in_work = false;
static bool g_reentered = false;
static int g_open_browsers = 0;

static void ScheduleWork(int64_t delay_ms);

static void KillPumpTimer() {
  [g_pump_timer invalidate];
  g_pump_timer = nil;
}

static void DoWork() {
  if (g_in_work) {
    g_reentered = true;
    return;
  }
  g_reentered = false;
  g_in_work = true;
  CefDoMessageLoopWork();
  g_in_work = false;
  if (g_reentered) {
    ScheduleWork(0);
  } else if (!g_pump_timer && g_open_browsers > 0) {
    ScheduleWork(kMaxTimerDelayMs);
  }
}

static void ScheduleWork(int64_t delay_ms) {
  KillPumpTimer();
  if (delay_ms <= 0) {
    dispatch_async(dispatch_get_main_queue(), ^{
      DoWork();
    });
    return;
  }
  NSTimeInterval seconds = (double)std::min(delay_ms, kMaxTimerDelayMs) / 1000.0;
  g_pump_timer = [NSTimer timerWithTimeInterval:seconds
                                        repeats:NO
                                          block:^(NSTimer*) {
                                            g_pump_timer = nil;
                                            DoWork();
                                          }];
  g_pump_timer.tolerance = seconds / 2;
  // Common modes, so pages keep going during menus and window resizes.
  [[NSRunLoop mainRunLoop] addTimer:g_pump_timer forMode:NSRunLoopCommonModes];
}

// MARK: - App

class KTApp : public CefApp, public CefBrowserProcessHandler {
 public:
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }

  void OnBeforeCommandLineProcessing(const CefString& process_type,
                                     CefRefPtr<CefCommandLine> command_line) override {
    if (!process_type.empty()) return;
    // Cookies aren't encrypted with a Keychain item, which would ask for
    // the login password; the profile is KinTerm's own, for development.
    command_line->AppendSwitch("use-mock-keychain");
    // No background traffic or component downloads: a dev browser stays
    // quiet when you aren't using it.
    command_line->AppendSwitch("disable-background-networking");
    command_line->AppendSwitch("disable-component-update");
    command_line->AppendSwitch("no-default-browser-check");
    command_line->AppendSwitch("no-first-run");
  }

  void OnScheduleMessagePumpWork(int64_t delay_ms) override {
    dispatch_async(dispatch_get_main_queue(), ^{
      ScheduleWork(delay_ms);
    });
  }

 private:
  IMPLEMENT_REFCOUNTING(KTApp);
};

// MARK: - DevTools

// The DevTools of a page, in a view KinTerm gives it (docked) or a window
// of its own. Tells the page's client when it closes.
class KTDevToolsClient : public CefClient, public CefLifeSpanHandler, public CefKeyboardHandler {
 public:
  explicit KTDevToolsClient(std::function<void()> closed) : closed_(std::move(closed)) {}

  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return this; }

  bool OnPreKeyEvent(CefRefPtr<CefBrowser> browser, const CefKeyEvent& event, CefEventHandle os_event,
                     bool* is_keyboard_shortcut) override {
    if (!os_event) return false;
    int edit = EditCommandForKey(event, CAST_CEF_EVENT_HANDLE_TO_NSEVENT(os_event));
    if (edit < 0) return false;
    RunEdit(browser, edit);
    return true;
  }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    g_open_browsers++;
    NSView* view = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
    if (view.superview) {
      view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
      view.frame = view.superview.bounds;
    }
    ScheduleWork(0);
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    g_open_browsers = std::max(0, g_open_browsers - 1);
    if (closed_) closed_();
  }

  void Detach() { closed_ = nullptr; }

 private:
  std::function<void()> closed_;
  IMPLEMENT_REFCOUNTING(KTDevToolsClient);
};

// MARK: - A browser

class KTClient : public CefClient,
                 public CefDisplayHandler,
                 public CefLifeSpanHandler,
                 public CefLoadHandler,
                 public CefKeyboardHandler,
                 public CefDevToolsMessageObserver {
 public:
  KTClient(kt_event_fn fn, void* context, std::string pending_url)
      : fn_(fn), context_(context), pending_url_(std::move(pending_url)) {}

  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return this; }

  CefRefPtr<CefBrowser> browser() const { return browser_; }

  // KinTerm closed its side; no more events.
  void Detach() {
    fn_ = nullptr;
    if (devtools_) devtools_->Detach();
  }

  // DevTools in a window of its own. (Chromium can't put its DevTools
  // browser in a view; KinTerm docks DevTools by loading the DevTools front
  // end as an ordinary page instead.)
  void ShowDevTools() {
    if (!browser_) return;
    auto host = browser_->GetHost();
    CefWindowInfo info;
    info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
    CefBrowserSettings settings;
    if (devtools_) devtools_->Detach();
    CefRefPtr<KTClient> self(this);
    devtools_ = new KTDevToolsClient([self]() {
      self->devtools_ = nullptr;
      self->Emit(KT_EVENT_DEVTOOLS, nullptr, 0, 0);
    });
    host->ShowDevTools(info, devtools_, settings, CefPoint());
    Emit(KT_EVENT_DEVTOOLS, nullptr, 1, 0);
  }

  void CloseDevTools() {
    if (browser_ && browser_->GetHost()->HasDevTools()) browser_->GetHost()->CloseDevTools();
  }

  void Navigate(const std::string& url) {
    if (browser_) {
      browser_->GetMainFrame()->LoadURL(url);
    } else {
      pending_url_ = url;
    }
  }

  void Edit(int command) { RunEdit(browser_, command); }

  // Ask for the page's DevTools target id, so agents can be given this
  // page and no other (see kinterm-browser-mcp.mjs). Right after the
  // browser is made DevTools may not answer yet; asked again after each
  // load until it does.
  void RequestTargetId() {
    if (!browser_ || has_target_id_) return;
    if (!devtools_observer_) devtools_observer_ = browser_->GetHost()->AddDevToolsMessageObserver(this);
    // Our own message id: the result can arrive before this returns.
    static int next_id = 0x4b540000;
    target_info_id_ = ++next_id;
    if (browser_->GetHost()->ExecuteDevToolsMethod(target_info_id_, "Target.getTargetInfo", nullptr) == 0) {
      target_info_id_ = -1;
    }
  }

  void Close() {
    closing_ = true;
    devtools_observer_ = nullptr;
    if (browser_) browser_->GetHost()->CloseBrowser(true);
  }

  // CefLifeSpanHandler

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    browser_ = browser;
    g_open_browsers++;
    NSView* view = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    if (view.superview) view.frame = view.superview.bounds;
    Emit(KT_EVENT_CREATED, nullptr, browser->GetIdentifier(), 0);
    RequestTargetId();
    if (closing_) {
      browser->GetHost()->CloseBrowser(true);
    } else if (!pending_url_.empty() && pending_url_ != browser->GetMainFrame()->GetURL().ToString()) {
      browser->GetMainFrame()->LoadURL(pending_url_);
    }
    pending_url_.clear();
    ScheduleWork(0);
  }

  bool OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int popup_id,
                     const CefString& target_url, const CefString& target_frame_name,
                     WindowOpenDisposition target_disposition, bool user_gesture,
                     const CefPopupFeatures& popupFeatures, CefWindowInfo& windowInfo,
                     CefRefPtr<CefClient>& client, CefBrowserSettings& settings,
                     CefRefPtr<CefDictionaryValue>& extra_info, bool* no_javascript_access) override {
    // One page per browser: links that would open a window open here.
    if (!target_url.empty()) browser->GetMainFrame()->LoadURL(target_url);
    return true;
  }

  bool DoClose(CefRefPtr<CefBrowser> browser) override {
    // By default CEF would now close the window the browser is in, a
    // terminal or browser window of KinTerm's. Only the browser goes:
    // taking its view out of the window destroys it.
    NSView* view = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
    [view removeFromSuperview];
    return true;
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    if (browser_ && browser_->IsSame(browser)) {
      // The registration holds this client; let it go.
      devtools_observer_ = nullptr;
      browser_ = nullptr;
      g_open_browsers = std::max(0, g_open_browsers - 1);
      Emit(KT_EVENT_CLOSED, nullptr, 0, 0);
    }
  }

  // CefDisplayHandler

  void OnAddressChange(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                       const CefString& url) override {
    if (frame->IsMain()) Emit(KT_EVENT_ADDRESS, url.ToString().c_str(), 0, 0);
  }

  void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) override {
    Emit(KT_EVENT_TITLE, title.ToString().c_str(), 0, 0);
  }

  bool OnConsoleMessage(CefRefPtr<CefBrowser> browser, cef_log_severity_t level,
                        const CefString& message, const CefString& source, int line) override {
    std::string text = message.ToString();
    if (text.rfind(kPickPrefix, 0) == 0) {
      Emit(KT_EVENT_PICK, text.c_str() + sizeof(kPickPrefix) - 1, 0, 0);
      return true;
    }
    if (level >= LOGSEVERITY_ERROR) Emit(KT_EVENT_CONSOLE_ERROR, message.ToString().c_str(), line, 0);
    return false;
  }

  // CefLoadHandler

  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool isLoading, bool canGoBack,
                            bool canGoForward) override {
    Emit(KT_EVENT_LOADING, nullptr, isLoading ? 1 : 0, (canGoBack ? 1 : 0) | (canGoForward ? 2 : 0));
    if (!isLoading) RequestTargetId();
  }

  void OnLoadError(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, ErrorCode errorCode,
                   const CefString& errorText, const CefString& failedUrl) override {
    if (!frame->IsMain() || errorCode == ERR_ABORTED) return;
    Emit(KT_EVENT_LOAD_ERROR, errorText.ToString().c_str(), errorCode, 0);
  }

  // CefKeyboardHandler

  bool OnPreKeyEvent(CefRefPtr<CefBrowser> browser, const CefKeyEvent& event, CefEventHandle os_event,
                     bool* is_keyboard_shortcut) override {
    if (!os_event || event.type != KEYEVENT_RAWKEYDOWN || !(event.modifiers & EVENTFLAG_COMMAND_DOWN)) return false;
    NSEvent* ns_event = CAST_CEF_EVENT_HANDLE_TO_NSEVENT(os_event);
    // Edit shortcuts (⌘C, ⌘V, ⌘A…) act on the page directly.
    int edit = EditCommandForKey(event, ns_event);
    if (edit >= 0) {
      RunEdit(browser, edit);
      return true;
    }
    // Other ⌘ shortcuts go to KinTerm's menus first (⌘W, ⌘T, grid and
    // browser items), like they do everywhere else in the app.
    return [[NSApp mainMenu] performKeyEquivalent:ns_event];
  }

  // CefDevToolsMessageObserver

  void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser, int message_id, bool success, const void* result,
                              size_t result_size) override {
    if (message_id != target_info_id_) return;
    target_info_id_ = -1;
    if (!success || !result) return;
    CefRefPtr<CefValue> value = CefParseJSON(result, result_size, JSON_PARSER_RFC);
    if (!value || value->GetType() != VTYPE_DICTIONARY) return;
    CefRefPtr<CefDictionaryValue> info = value->GetDictionary()->GetDictionary("targetInfo");
    if (!info) return;
    std::string id = info->GetString("targetId").ToString();
    if (id.empty()) return;
    has_target_id_ = true;
    Emit(KT_EVENT_TARGET, id.c_str(), 0, 0);
  }

 private:
  void Emit(int kind, const char* value, int a, int b) {
    if (fn_) fn_(context_, kind, value, a, b);
  }

  kt_event_fn fn_;
  void* context_;
  std::string pending_url_;
  bool closing_ = false;
  CefRefPtr<CefBrowser> browser_;
  CefRefPtr<KTDevToolsClient> devtools_;
  CefRefPtr<CefRegistration> devtools_observer_;
  int target_info_id_ = -1;
  bool has_target_id_ = false;

  IMPLEMENT_REFCOUNTING(KTClient);
};

static bool g_initialized = false;
static std::set<KTClient*> g_clients;

static KTClient* AsClient(void* handle) {
  auto* client = static_cast<KTClient*>(handle);
  return g_clients.count(client) ? client : nullptr;
}

// MARK: - C API

// Load Chromium and start it. Returns 0 on success.
//
// framework_dir: ".../Chromium Embedded Framework.framework"
// helper_path:   ".../KinTerm Helper.app/Contents/MacOS/KinTerm Helper"
// cache_dir:     the profile, KinTerm's own (not a browser you use)
// debug_port:    Chrome DevTools Protocol port on 127.0.0.1, 0 for none
KT_EXPORT int kt_browser_initialize(const char* framework_dir, const char* helper_path,
                                    const char* cache_dir, int debug_port) {
  if (g_initialized) return 0;

  std::string library = std::string(framework_dir) + "/Chromium Embedded Framework";
  if (!cef_load_library(library.c_str())) return 1;

  InstallSendEventHook();

  // Chromium gets no arguments of KinTerm's.
  NSString* executable = NSBundle.mainBundle.executablePath ?: @"kinterm";
  static std::string argv0 = executable.fileSystemRepresentation;
  static char* argv[] = {argv0.data(), nullptr};
  CefMainArgs args(1, argv);

  CefSettings settings;
  settings.no_sandbox = false;
  settings.external_message_pump = true;
  settings.multi_threaded_message_loop = false;
  settings.remote_debugging_port = debug_port;
  settings.persist_session_cookies = true;
  settings.log_severity = LOGSEVERITY_ERROR;
  CefString(&settings.framework_dir_path) = framework_dir;
  CefString(&settings.browser_subprocess_path) = helper_path;
  CefString(&settings.main_bundle_path) = NSBundle.mainBundle.bundlePath.fileSystemRepresentation;
  CefString(&settings.root_cache_path) = cache_dir;
  CefString(&settings.cache_path) = std::string(cache_dir) + "/Default";
  CefString(&settings.log_file) = std::string(cache_dir) + "/browser.log";
  CefString(&settings.locale) = "en-US";

  CefRefPtr<KTApp> app(new KTApp);
  if (!CefInitialize(args, settings, app, nullptr)) return 2;
  g_initialized = true;
  ScheduleWork(0);
  return 0;
}

// Make a browser filling parent (an NSView), loading url. Events go to fn
// with context until kt_browser_close. Returns a handle.
KT_EXPORT void* kt_browser_create(void* parent, const char* url, kt_event_fn fn, void* context) {
  if (!g_initialized) return nullptr;
  NSView* view = (__bridge NSView*)parent;

  CefWindowInfo info;
  NSRect bounds = view.bounds;
  info.SetAsChild(CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(view),
                  CefRect(0, 0, (int)std::max(1.0, bounds.size.width), (int)std::max(1.0, bounds.size.height)));
  info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;

  CefBrowserSettings browser_settings;
  std::string start = url && *url ? url : "about:blank";
  CefRefPtr<KTClient> client(new KTClient(fn, context, start));
  if (!CefBrowserHost::CreateBrowser(info, client, start, browser_settings, nullptr, nullptr)) return nullptr;

  client->AddRef();  // Released by kt_browser_close.
  g_clients.insert(client.get());
  ScheduleWork(0);
  return client.get();
}

KT_EXPORT void kt_browser_navigate(void* handle, const char* url) {
  if (auto* client = AsClient(handle)) client->Navigate(url);
}

// 0 back, 1 forward, 2 reload, 3 stop, 4 reload ignoring the cache
KT_EXPORT void kt_browser_command(void* handle, int command) {
  auto* client = AsClient(handle);
  if (!client || !client->browser()) return;
  auto browser = client->browser();
  switch (command) {
    case 0: browser->GoBack(); break;
    case 1: browser->GoForward(); break;
    case 2: browser->Reload(); break;
    case 3: browser->StopLoad(); break;
    case 4: browser->ReloadIgnoreCache(); break;
  }
}

KT_EXPORT void kt_browser_set_focus(void* handle, int focus) {
  auto* client = AsClient(handle);
  if (client && client->browser()) client->browser()->GetHost()->SetFocus(focus != 0);
}

// DevTools for the page in a window of its own. Reported with
// KT_EVENT_DEVTOOLS.
KT_EXPORT void kt_browser_show_devtools(void* handle) {
  if (auto* client = AsClient(handle)) client->ShowDevTools();
}

// Run JavaScript in the page's main frame.
KT_EXPORT void kt_browser_execute_js(void* handle, const char* code) {
  auto* client = AsClient(handle);
  if (!client || !client->browser()) return;
  auto frame = client->browser()->GetMainFrame();
  frame->ExecuteJavaScript(code, frame->GetURL(), 0);
  ScheduleWork(0);
}

// 0 undo, 1 redo, 2 cut, 3 copy, 4 paste, 5 select all, in the focused frame.
KT_EXPORT void kt_browser_edit(void* handle, int command) {
  if (auto* client = AsClient(handle)) {
    client->Edit(command);
    ScheduleWork(0);
  }
}

KT_EXPORT void kt_browser_close_devtools(void* handle) {
  if (auto* client = AsClient(handle)) client->CloseDevTools();
}

// Close the browser. No events reach KinTerm after this.
KT_EXPORT void kt_browser_close(void* handle) {
  auto* client = AsClient(handle);
  if (!client) return;
  g_clients.erase(client);
  client->CloseDevTools();
  client->Detach();
  client->Close();
  ScheduleWork(0);
  client->Release();
}

// Close everything and stop Chromium, when KinTerm quits.
KT_EXPORT void kt_browser_shutdown(void) {
  if (!g_initialized) return;
  for (KTClient* client : std::set<KTClient*>(g_clients)) kt_browser_close(client);
  // Let the browsers finish closing, for at most a second.
  NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
  while (g_open_browsers > 0 && [deadline timeIntervalSinceNow] > 0) {
    CefDoMessageLoopWork();
    [NSThread sleepForTimeInterval:0.01];
  }
  KillPumpTimer();
  CefShutdown();
  g_initialized = false;
}
