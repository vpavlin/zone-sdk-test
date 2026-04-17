# Feedback for Logos Core / Basecamp Team

This document summarizes issues, bugs, and improvement suggestions discovered while building **Yolo Board** — a UI plugin that uses the zone-sequencer and storage modules via IPC inside Basecamp.

---

## Critical Bugs Fixed (with PRs/forks available)

### 1. capability_module: `logosAPI` member shadowing breaks all IPC

**Severity:** Critical — blocks ALL inter-module communication

`CapabilityModulePlugin` declares a private `LogosAPI* logosAPI` member that shadows the public one inherited from `PluginInterface`. `initLogos()` sets the private member, but `ModuleProxy::informModuleToken()` reads the inherited public one — which is always null. Result: every `informModuleToken` call fails with "LogosAPI not available", preventing any module from authenticating with any other module.

**Fix:** Remove the private member (3 lines). The comment in the code says "this should be defined in interface.h but if not defined here it breaks" — it breaks because of the shadowing, not because of a missing definition.

**Fork:** [vpavlin/logos-capability-module@fix-ipc-shadowing](https://github.com/vpavlin/logos-capability-module/tree/fix-ipc-shadowing)

### 2. LogosResult cannot cross QRemoteObjects wire

**Severity:** Critical — all module methods returning `LogosResult` return empty values to callers

`ModuleProxy::callRemoteMethod` returns `QVariant(LogosResult)` to the QRemoteObjects transport. Dynamic replicas cannot serialize custom types — the value arrives empty on the client side. This affects every module built with the `logos_module()` codegen that returns `StdLogosResult`.

**Fix:** Convert `LogosResult` to a JSON `QString` in `ModuleProxy::callRemoteMethod` before returning. The client parses the JSON string.

**Fork:** [vpavlin/logos-cpp-sdk@logos-result-serialization-fix](https://github.com/vpavlin/logos-cpp-sdk/tree/logos-result-serialization-fix)

### 3. SDK version mismatch: `LogosInstance::id()` hash suffix

**Severity:** Critical — modules built with old SDK cannot be reached via IPC

The new SDK generates registry URLs with a `LogosInstance::id()` hash suffix (e.g. `local:logos_module_name_abc123`). Modules built with the old SDK (before the `LogosInstance` change) publish on `local:logos_module_name` (no suffix). The consumer connects to the suffixed URL, the provider listens on the non-suffixed one — they never find each other.

**Impact:** Any module not rebuilt with the latest SDK will silently fail to receive IPC calls (20s timeout, then empty result).

**Recommendation:** Consider a compatibility layer or version negotiation in the registry URL scheme.

---

## IPC Framework Issues

### 4. `informModuleToken` uses a single 1-second timer

`plugin_manager.cpp` waits exactly 1 second before calling `informModuleToken` on the capability module. If the module isn't ready yet, the call fails silently. 

**Fix:** Retry loop with 500ms interval, up to 10 attempts.

**Fork:** [vpavlin/logos-liblogos@ipc-fixes](https://github.com/vpavlin/logos-liblogos/tree/ipc-fixes)

### 5. QRemoteObjects calls are thread-bound

`QRemoteObjectNode` and its replicas must be used from the thread that created them. Calling `invokeRemoteMethod` from a `QtConcurrent::run` thread silently fails — the replica is never found and the call times out after 20 seconds.

**Impact:** Any plugin that tries to make IPC calls from background threads (to avoid freezing the UI) will experience 20s hangs.

**Workaround:** Use `QTimer::singleShot(0, ...)` to defer IPC calls to the main thread. This blocks the UI briefly but the calls succeed.

**Recommendation:** Document this clearly, or add a thread-marshaling layer in `LogosAPIClient` that automatically dispatches to the correct thread.

### 6. No async IPC support for UI plugins

UI plugins run on the main thread. IPC calls are synchronous and block the UI. The generated client API has `*Async` variants, but the raw `invokeRemoteMethod` path (used by plugins not linking the generated client) is always blocking.

**Recommendation:** Provide an `invokeRemoteMethodAsync` that returns a `QFuture` or takes a callback, usable without the generated client headers.

---

## Code Generator Issues

### 7. Header parser is line-based — multi-line declarations are silently skipped

The `impl_header_parser.cpp` processes one line at a time. Method declarations that span multiple lines are not parsed and silently omitted from the generated provider and client code.

```cpp
// This is SKIPPED by the codegen:
StdLogosResult downloadToUrl(const std::string& cid, const std::string& filePath,
                              bool local, int64_t chunkSize);

// This works:
StdLogosResult downloadFile(const std::string& cid, const std::string& filePath, bool local);
```

**Impact:** Methods silently missing from the generated IPC interface with no warning.

**Recommendation:** Either support multi-line declarations or emit a warning when a line looks like a partial declaration.

### 8. No provider method generated for 4+ parameter methods

Even when on a single line, `downloadToUrl` (4 params: string, string, bool, int64_t) was not generated in the provider. The client API IS generated for it. This asymmetry means the client can call a method that the server can't dispatch.

**Workaround:** Add a 3-parameter wrapper method.

---

## Basecamp Integration Issues

### 9. QML `FileDialog` crashes in QQuickWidget embedding

Importing `QtQuick.Dialogs` and using `FileDialog` in a UI plugin crashes the Basecamp process immediately. This is because UI plugins are loaded inside a `QQuickWidget`, and `FileDialog` creates a native dialog that conflicts with the embedding context.

**Workaround:** Use C++ `QFileDialog` from the backend instead.

**Recommendation:** Document this limitation for UI plugin developers.

### 10. `logos_host` path is hardcoded to nix store

Basecamp uses `QCoreApplication::applicationDirPath() + "/logos_host"` to find the host binary. When developing with a patched `logos_host`, you can't easily override it.

**Note:** The `LOGOS_HOST_PATH` environment variable override exists and works — but it's not documented.

### 11. No module auto-loading based on `dependencies`

Core modules listed in a UI plugin's `manifest.json` `dependencies` field are only loaded when the UI plugin is clicked — not at Basecamp startup. The embedded plugin metadata (from `Q_PLUGIN_METADATA`) is what Basecamp reads, not the `manifest.json` file on disk.

**Impact:** Developers must ensure the compile-time `plugin.json` (embedded in the .so) matches the `manifest.json` dependencies. Mismatches cause modules not to load.

---

## Storage Module Specific

### 12. Storage module has no HTTP REST API

The `libstorage`-based storage module runs a Codex node internally but does not expose an HTTP REST API. All operations must go through IPC. This makes it impossible to test or debug storage operations from the command line or external tools.

**Recommendation:** Consider adding an optional REST API endpoint, or at least a way to query the node's SPR/peerId for peer connectivity debugging.

### 13. `downloadToUrl` missing from generated provider

Due to issues #7/#8 above, `downloadToUrl` (the most natural download method) is not available via IPC. We had to add a `downloadFile` wrapper with fewer parameters.

---

## Summary

The Basecamp module system works well architecturally. The main pain points are:

1. **Silent failures** — IPC calls fail silently (empty results, 20s timeouts) instead of producing clear error messages
2. **Version coupling** — SDK version must match exactly between Basecamp and all modules, with no compatibility detection
3. **Threading assumptions** — QRemoteObjects threading constraints are undocumented and cause subtle bugs
4. **Codegen limitations** — line-based parser and missing provider methods create gaps between client and server interfaces

All fixes are available in the forks listed in [BUILD.md](BUILD.md).
