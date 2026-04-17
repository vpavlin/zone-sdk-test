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

### 14. Module plugins don't link SDK with `--whole-archive` → ModuleProxy stripped

**Severity:** Critical — cross-module IPC hangs 20s per call

By default `target_link_libraries(... liblogos_sdk.a)` only pulls in directly-referenced SDK symbols. `ModuleProxy::informModuleToken` (called by `capability_module` to notify the target module of a new auth token) is never directly referenced by the module's own code — so the linker strips it.

Result: when module A calls module B via IPC, `capability_module` tries to inform module B about A's token, B's `informModuleToken` handler doesn't exist → the inform call times out after 20 seconds. The actual A→B call then proceeds (token-less), but every first-time call between any two modules incurs a 20s token-exchange timeout.

**Fix:** Link the SDK archive with `--whole-archive`:

```cmake
target_link_libraries(${PLUGIN_TARGET} PRIVATE
    Qt6::Core Qt6::Concurrent
    -Wl,--whole-archive
    ${LOGOS_CPP_SDK_ROOT}/lib/liblogos_sdk.a
    -Wl,--no-whole-archive
)
```

**Recommendation:** Make `logos_module()` CMake macro (or the SDK install) use `--whole-archive` by default. Or register `ModuleProxy` via `Q_COREAPP_STARTUP_FUNCTION` in the SDK so it's always referenced.

---

### 15. Plugin-local `ModuleProxy` is shadowed by host-process `ModuleProxy` via RTLD_GLOBAL

**Severity:** Critical — can't fix serialization by rebuilding individual modules

QPluginLoader loads plugins with `RTLD_GLOBAL` (Qt default). Once the host process has loaded `liblogos_core.so` (or any .so containing `ModuleProxy`), the dynamic linker resolves all subsequent `ModuleProxy::callRemoteMethod` calls to that first-loaded copy. Even if a plugin is rebuilt with an updated SDK, its own `ModuleProxy` symbols are shadowed at runtime.

**Concrete scenario:** We shipped the `LogosResult → JSON` fix (issue #2) in our cpp-sdk fork. `storage_module_plugin.so` built against the fork has the fix baked in (verified with `strings`). But when loaded by Basecamp's `logos_host` (which was built against the unfixed SDK), the plugin's `ModuleProxy` is shadowed — Basecamp's version runs. Result: `LogosResult` still returns empty across the wire, even though every module binary on disk has the fix.

**Impact:** To deploy a fix to `ModuleProxy` (or any class in `liblogos_sdk.a`), every process in the entire system — Basecamp, every `logos_host`, every plugin — must be rebuilt together with the same SDK. There's no way to hotfix individual modules.

**Workaround options:**
- Use `RTLD_LOCAL` when loading plugins (Qt setting)
- Expose `ModuleProxy` only as a C API in the SDK so name mangling doesn't collide
- Make `ModuleProxy` a runtime-dispatched interface (vtable lookup) so plugin-local symbols win

**Recommendation:** This is a serious deployability constraint. The SDK effectively becomes an ABI that locks all components to the same build.

---

### 16. Module-to-module sync IPC deadlocks on token handshake

**Severity:** High — makes cleanly-layered architectures impractical

When module A (running in logos_host_A) calls module B (running in logos_host_B):

1. A's `LogosAPIClient::invokeRemoteMethod` needs a token for B
2. No cached token → calls `capability_module.requestModule(A, B)`
3. capability_module issues token T
4. capability_module calls `B.informModuleToken(A, T)` via IPC
5. But A is blocked inside its own incoming IPC handler (from the original caller) → A's event loop is busy → A can't receive the inform call
6. 20s timeout → capability_module logs "Failed to inform" → eventually the call proceeds

Combined with issues #14 and #15, this makes the "middleware module" pattern (UI → yolo_board_module → zone-sequencer_module) unworkable. We wanted to build `yolo_board_module` to own all business logic (polling, media cache, backfill) and expose a clean API to the QML UI, but any synchronous cross-module call from within an incoming IPC handler deadlocks on the token handshake.

**Recommendations:**
1. Pre-warm tokens at module startup: have `logos_host` call `capability_module.requestModule` for all declared dependencies before the module's first user-facing IPC is dispatched.
2. Make `informModuleToken` reliably asynchronous — don't require the target to drain its event loop.
3. Document that sync cross-module calls from within an IPC handler are not supported.

---

### 17. `ui_qml` sandbox blocks legitimate imports

**Severity:** Medium — forces awkward UX workarounds

Basecamp's `ui_qml` plugin loader restricts QML import paths to:
- `qrc:/qt-project.org/imports`
- `qrc:/qt/qml`
- Plugin-local directory

This blocks `QtQuick.Dialogs` (file picker), `Qt.labs.folderlistmodel`, `Qt.labs.platform`, etc. — so there's no way for a UI plugin to open a native file dialog or list local files.

**Workarounds we resorted to:**
- Drag-and-drop onto a `DropArea` (works, but not discoverable)
- Manual path input dialog (terrible UX)

**Recommendation:** Expose a file-picker method on `LogosQmlBridge` (e.g. `logos.pickFile(filters, callback)`) that goes through the host's permission model. Or relax the import restrictions for a curated safe-list (Dialogs, FolderListModel).

---

### 18. `logos.onModuleEvent` / `callModuleAsync` missing in current Basecamp

**Severity:** Medium — forces blocking UI during IPC

`LogosQmlBridge` in the current Basecamp build only has synchronous `callModule(module, method, args) → QString`. The newer SDK has `callModuleAsync(module, method, args, callback, timeoutMs)` and `onModuleEvent(module, event)` + `moduleEventReceived` signal, but Basecamp hasn't been rebuilt with the newer SDK.

Without async IPC, every user action that hits a core module freezes the UI for the duration of the round-trip (1–20s depending on state). History backfill (paginated query) is effectively unusable — each page blocks the main thread.

**Recommendation:** Rebuild and ship a Basecamp that has `callModuleAsync` + `onModuleEvent`. Until then, UI plugins are forced into a sync-only IPC model that can't handle long-running or high-frequency operations.

---

### 19. Storage module's `manifests()` / `uploadUrl()` return `LogosResult` — unusable without #2 fix

**Severity:** High — breaks the advertised upload flow

The storage module returns `StdLogosResult` (→ `LogosResult`) from all its Q_INVOKABLE methods (init, start, uploadUrl, manifests, downloadFile, etc.). Without the `ModuleProxy` serialization fix (#2), every IPC caller receives an empty QString for all storage calls.

**Concrete effect in our plugin:** `callStorage("uploadUrl", ...)` returns empty → we fall back to polling `callStorage("manifests", ...)` → also returns empty → we time out waiting for the CID → the uploaded file is stored in Codex but we can't publish a message referencing it.

The `storageUploadDone` event DOES carry the CID, but `logos.onModuleEvent` isn't available in current Basecamp (#18).

**Recommendations (any one):**
1. Land #2 (LogosResult → JSON conversion) in upstream SDK and rebuild Basecamp
2. Add plain-QString wrapper methods (e.g. `manifestsJson() → QString`) to the storage module as a bridging option
3. Land `callModuleAsync` + `onModuleEvent` so plugins can subscribe to `storageUploadDone` instead of polling

---

## Summary

The Basecamp module system works well architecturally. The main pain points are:

1. **Silent failures** — IPC calls fail silently (empty results, 20s timeouts) instead of producing clear error messages
2. **ABI coupling at runtime** — `RTLD_GLOBAL` plugin loading means fixes to the SDK require rebuilding everything in lockstep (#15). There's no per-plugin upgrade path.
3. **Cross-module sync IPC deadlocks** on token handshake (#16) — the middleware pattern (UI → domain_module → backing_modules) is impractical
4. **Version coupling** — SDK version must match exactly between Basecamp and all modules, with no compatibility detection
5. **Threading assumptions** — QRemoteObjects threading constraints are undocumented and cause subtle bugs
6. **Codegen limitations** — line-based parser and missing provider methods create gaps between client and server interfaces
7. **UI sandbox over-restrictive** — blocks `QtQuick.Dialogs` etc., leaving no path to native file pickers (#17)
8. **Sync-only `LogosQmlBridge`** in current Basecamp (#18) — freezes UI for every IPC call

All fixes are available in the forks listed in [BUILD.md](BUILD.md). For the user-facing Yolo Board, we ended up with a pragmatic architecture: pure QML plugin calling core modules directly via `callModule()`, with the zone-sequencer module extended to own file persistence (subscriptions, config) since the QML sandbox can't write files. Publishing text works end-to-end; file upload stores bytes but can't retrieve the CID due to #19.
