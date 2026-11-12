// The helper processes Chromium runs pages, the GPU and services in. The
// same executable is copied into each "KinTerm Helper (…).app".

#include "include/cef_app.h"
#include "include/cef_sandbox_mac.h"
#include "include/wrapper/cef_library_loader.h"

int main(int argc, char* argv[]) {
  // Every helper runs in Chromium's sandbox.
  CefScopedSandboxContext sandbox_context;
  if (!sandbox_context.Initialize(argc, argv)) return 1;

  CefScopedLibraryLoader library_loader;
  if (!library_loader.LoadInHelper()) return 1;

  CefMainArgs main_args(argc, argv);
  return CefExecuteProcess(main_args, nullptr, nullptr);
}
