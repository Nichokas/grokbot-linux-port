// linux-stub.cc — placeholder N-API addon for a Windows-only vendored native module.
//
// Some Grok Bot native deps ship no Linux source or prebuild (private Anysphere
// Crates). port.sh rewrites the Windows .node to this stub so node-gyp-build
// resolves a loadable object instead of crashing the process in dlopen.
// The stub exports an empty object: guarded callers (e.g. cursor-proclist's
// scan_async probe) read it as "feature unavailable", and unguarded top-level
// requires (tree-chunk-napi) no longer abort module evaluation at spawn.

#include <node_api.h>

static napi_value StubInit(napi_env env, napi_value exports) {
  (void)env;
  return exports;
}

NAPI_MODULE(NODE_GYP_MODULE_NAME, StubInit)
