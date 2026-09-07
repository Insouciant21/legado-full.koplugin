/*
 * QuickJS bridge for the KOReader Legado plugin.
 *
 * The Android source format is intentionally JavaScript based.  KOReader
 * itself is a Lua application, so this small C ABI keeps the JavaScript
 * engine behind one call and lets Lua provide the Legado host objects
 * (network, cookies, variables and the small java.* compatibility surface).
 *
 * QuickJS is distributed under the MIT license.  This file only depends on
 * its public quickjs.h API; build-quickjs.sh supplies the engine sources.
 */

#include "quickjs.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__linux__)
#include <sys/time.h>
#include <time.h>
#endif

/* Ubuntu's current 32-bit glibc headers redirect clock_gettime to the
 * time64 ABI.  Older Kindle firmware does not provide that symbol.  QuickJS
 * only needs a wall-clock source for its internal bookkeeping here, so keep a
 * legacy-compatible implementation in the bridge and let the ARM build map
 * clock_gettime to it. */
#if defined(__linux__) && defined(LEGADO_LEGACY_TIME32)
int legado_clock_gettime(clockid_t clock_id, struct timespec *timespec_value) {
    (void)clock_id;
    struct timeval value;
    if (gettimeofday(&value, NULL) != 0) {
        return -1;
    }
    timespec_value->tv_sec = value.tv_sec;
    timespec_value->tv_nsec = value.tv_usec * 1000;
    return 0;
}
#endif

typedef int (*legado_js_host_callback)(const char *operation,
                                       const char *arguments_json,
                                       char *output,
                                       size_t output_size);

typedef struct {
    legado_js_host_callback callback;
} LegadoJsHost;

static size_t host_output_size(const char *operation) {
    /* Most bridge calls return a cookie, variable or scalar.  A fixed 16 MiB
     * allocation for those calls is particularly expensive on the 32-bit
     * Kindle because large TOCs can invoke java.get()/java.put() once per
     * chapter.  Network-shaped calls retain a generous ceiling for a page of
     * HTML/JSON; the final JavaScript result has its own reusable buffer. */
    if (operation != NULL
            && (strcmp(operation, "ajax") == 0
                || strcmp(operation, "post") == 0
                || strcmp(operation, "importScript") == 0
                || strcmp(operation, "startBrowserAwait") == 0)) {
        /* Preserve the historical maximum for network-shaped results and
         * browser-returned documents, avoiding truncation of source pages. */
        return 16U * 1024U * 1024U;
    }
    if (operation != NULL
            && (strcmp(operation, "getString") == 0
                || strcmp(operation, "getElement") == 0
                || strcmp(operation, "getElements") == 0
                || strcmp(operation, "source.getLoginInfo") == 0
                || strcmp(operation, "source.getLoginInfoMap") == 0)) {
        return 2U * 1024U * 1024U;
    }
    return 512U * 1024U;
}

static void set_output(char *output, size_t output_size, const char *message) {
    if (output == NULL || output_size == 0) {
        return;
    }
    if (message == NULL) {
        message = "unknown JavaScript error";
    }
    snprintf(output, output_size, "%s", message);
    output[output_size - 1] = '\0';
}

static JSValue host_call(JSContext *ctx,
                         JSValueConst this_val,
                         int argc,
                         JSValueConst *argv) {
    (void)this_val;
    LegadoJsHost *host = (LegadoJsHost *)JS_GetContextOpaque(ctx);
    if (host == NULL || host->callback == NULL) {
        return JS_ThrowInternalError(ctx, "Legado host callback is unavailable");
    }
    if (argc < 2) {
        return JS_ThrowTypeError(ctx, "Legado host call requires operation and arguments");
    }

    const char *operation = JS_ToCString(ctx, argv[0]);
    const char *arguments = JS_ToCString(ctx, argv[1]);
    if (operation == NULL || arguments == NULL) {
        if (operation != NULL) JS_FreeCString(ctx, operation);
        if (arguments != NULL) JS_FreeCString(ctx, arguments);
        return JS_EXCEPTION;
    }

    /* The Lua callback still applies its own response limit, while this
     * temporary buffer avoids returning a pointer into Lua memory across the
     * C boundary.  Keep scalar calls small; see host_output_size(). */
    const size_t output_size = host_output_size(operation);
    char *output = (char *)malloc(output_size);
    if (output == NULL) {
        JS_FreeCString(ctx, operation);
        JS_FreeCString(ctx, arguments);
        return JS_ThrowInternalError(ctx, "cannot allocate JavaScript host buffer");
    }
    output[0] = '\0';
    int callback_result = host->callback(operation, arguments, output, output_size);
    JS_FreeCString(ctx, operation);
    JS_FreeCString(ctx, arguments);
    if (callback_result != 0) {
        free(output);
        return JS_ThrowInternalError(ctx, "Legado host callback failed");
    }

    /* Keep the callback result as JSON text.  The JavaScript prelude parses
     * it once, which is important for a callback result that itself is a
     * JSON string (for example source.getVariable() or an HTTP body). */
    JSValue value = JS_NewStringLen(ctx, output, strlen(output));
    free(output);
    return value;
}

/*
 * The prelude deliberately models only the host boundary.  Source authors
 * can still use normal JavaScript and the Legado helper names, while all
 * operations which would otherwise touch Android are routed to Lua.
 */
static const char *LEGADO_PRELUDE =
    "function __legado_host(op,args){"
    "var raw=__legado_host_raw(String(op),JSON.stringify(args===undefined?[]:args));"
    "var value=JSON.parse(raw);"
    "if(value&&value.__legado_error)throw new Error(value.__legado_error);"
    "return value;"
    "}\n"
    "function __legado_proxy(){"
    "return new Proxy(function(){return {};},{"
    "get:function(){return __legado_proxy();},"
    "apply:function(){return {};},"
    "construct:function(){throw new Error('Java class is unavailable on Kindle');}});"
    "}\n"
    "var Packages=__legado_proxy();"
    "function JavaImporter(){return __legado_proxy();}"
    "function importClass(){}"
    "function importPackage(){}\n"
    "var __ctx=globalThis.__ctx||{};"
    /* Use global properties for per-rule bindings.  A number of imported
     * sources declare `let title`, `let result`, or `let baseUrl` at global
     * scope; a prelude-level `var` would create a conflicting lexical
     * binding in QuickJS.  Global object properties remain visible as normal
     * identifiers without causing that redeclaration failure. */
    "globalThis.key=__ctx.key===undefined?'':__ctx.key;"
    "globalThis.page=Number(__ctx.page||1);"
    "globalThis.index=Number(__ctx.index||1);"
    "globalThis.gInt=Number(__ctx.gInt||0);"
    "globalThis.title=String(__ctx.title===undefined?'':__ctx.title);"
    "globalThis.baseUrl=__ctx.baseUrl===undefined?'':__ctx.baseUrl;"
    "globalThis.result=__ctx.result===undefined?'':__ctx.result;"
    "globalThis.book=__ctx.book||{};"
    "globalThis.chapter=__ctx.chapter||{};"
    "globalThis.host=__ctx.host||[];\n"
    "book.getVariable=function(k){return __legado_host('book.getVariable',[String(k===undefined?'':k)]);};"
    "book.setVariable=function(k,v){return __legado_host('book.setVariable',[String(k===undefined?'':k),v]);};\n"
    "book.setUseReplaceRule=function(){return '';};"
    "globalThis.source={"
    "bookSourceUrl:String(__ctx.sourceUrl||''),"
    "bookSourceName:String(__ctx.sourceName||''),"
    "bookSourceComment:String(__ctx.sourceComment||''),"
    "key:String(__ctx.sourceUrl||''),"
    "header:__ctx.sourceHeader||'',"
    "getVariable:function(){return __legado_host('source.getVariable',[]);},"
    "setVariable:function(v){return __legado_host('source.setVariable',[String(v===undefined?'':v)]);},"
    "getLoginInfo:function(){return __legado_host('source.getLoginInfo',[]);},"
    "getLoginInfoMap:function(){"
        "var map=__legado_host('source.getLoginInfoMap',[]);"
        "if(map&&typeof map.get!=='function')map.get=function(k){return map[k];};"
        "return map;"
    "},"
    "getKey:function(){return __legado_host('source.getKey',[]);},"
    "getLoginHeader:function(){return __legado_host('source.getLoginHeader',[]);},"
    "putLoginInfo:function(v){return __legado_host('source.putLoginInfo',[v]);},"
    "loginUi:function(){}"
    "};\n"
    "globalThis.java={"
    "ajax:function(url,options){return __legado_host('ajax',[String(url===undefined?'':url),options===undefined?null:options]);},"
    "base64Encode:function(v){return __legado_host('base64Encode',[String(v===undefined?'':v)]);},"
    "base64Decode:function(v){return __legado_host('base64Decode',[String(v===undefined?'':v)]);},"
    "hexDecodeToString:function(v){return __legado_host('hexDecodeToString',[String(v===undefined?'':v)]);},"
    "hexDecode:function(v){return __legado_host('hexDecode',[String(v===undefined?'':v)]);},"
    "md5Encode:function(v){return __legado_host('md5Encode',[String(v===undefined?'':v)]);},"
    "md5Encode16:function(v){return __legado_host('md5Encode16',[String(v===undefined?'':v)]);},"
    "getString:function(r,c){return __legado_host('getString',[String(r===undefined?'':r),c===undefined?null:c]);},"
    "getElement:function(r,c){return __legado_host('getElement',[String(r===undefined?'':r),c===undefined?null:c]);},"
    "getElements:function(r,c){return __legado_host('getElements',[String(r===undefined?'':r),c===undefined?null:c]);},"
    "setContent:function(v){return __legado_host('setContent',[v===undefined?'':v]);},"
    "post:function(u,b,h){return __legado_host('post',[String(u===undefined?'':u),b===undefined?null:b,h===undefined?null:h]);},"
    "encodeURI:function(v){return globalThis.encodeURI(String(v===undefined?'':v));},"
    "importScript:function(u){"
        "var code=__legado_host('importScript',[String(u===undefined?'':u)]);"
        "if(code)(0,eval)(code);"
        "return code;"
    "},"
    "openUrl:function(){return '';},"
    "get:function(k){return __legado_host('store.get',[String(k)]);},"
    "put:function(k,v){return __legado_host('store.put',[String(k),v]);},"
    "getVariable:function(k){return __legado_host('variable.get',[k===undefined?null:String(k)]);},"
    "setVariable:function(k,v){return __legado_host('variable.set',[String(k),v]);},"
    "putMemory:function(k,v){return __legado_host('memory.put',[String(k),v]);},"
    "getFromMemory:function(k){return __legado_host('memory.get',[String(k)]);},"
    "setMemory:function(k,v){return __legado_host('memory.put',[String(k),v]);},"
    "getCookie:function(u){return __legado_host('cookie.get',[String(u===undefined?'':u)]);},"
    "setCookie:function(u,v){return __legado_host('cookie.set',[String(u),String(v)]);},"
    "removeCookie:function(u){return __legado_host('cookie.remove',[String(u)]);},"
    "getWebViewUA:function(){return __legado_host('userAgent',[]);},"
    "deviceID:function(){if(__ctx.deviceMode==='android')throw new Error('deviceID is unavailable on Kindle');return __legado_host('deviceId',[]);},"
    "androidId:function(){return __legado_host('androidId',[]);},"
    "qread:function(){return __legado_host('unsupported',['qread']);},"
    "reLoginView:undefined,"
    "hasJavaClass:function(n){return false;},"
    "log:function(v){return __legado_host('log',[String(v)]);},"
    "toast:function(v){return __legado_host('toast',[String(v)]);},"
    "longToast:function(v){return __legado_host('toast',[String(v)]);},"
    "refreshExplore:function(){return '';},"
    "timeFormat:function(v){return String(v===undefined?'':v);},"
    /* Force Android-only crypto callers into their source-provided fallback
     * (usually source.putLoginInfo) instead of returning a fake object that
     * silently loses the updated login payload. */
    "createSymmetricCrypto:function(){return __legado_host('unsupported',['createSymmetricCrypto']);},"
    "lang:__legado_proxy(),"
    "net:__legado_proxy(),"
    "startBrowser:function(u,t,h){return __legado_host('startBrowser',["
        "String(u===undefined?'':u),t===undefined?'':String(t),h===undefined?null:String(h)]);},"
    "startBrowserDp:function(u,t,h){return __legado_host('startBrowserDp',["
        "String(u===undefined?'':u),t===undefined?'':String(t),h===undefined?null:String(h)]);},"
    "showBrowser:function(u,t,h){return __legado_host('showBrowser',["
        "String(u===undefined?'':u),t===undefined?'':String(t),h===undefined?null:String(h)]);},"
    "showReadingBrowser:function(u,t,h){return __legado_host('showReadingBrowser',["
        "String(u===undefined?'':u),t===undefined?'':String(t),h===undefined?null:String(h)]);},"
    "webView:function(){return __legado_host('unsupported',['webView']);},"
    "startBrowserAwait:function(u,t,r,h){"
        "var response=__legado_host('startBrowserAwait',["
            "String(u===undefined?'':u),"
            "t===undefined?'':String(t),"
            "r===undefined?true:!!r,"
            "h===undefined?null:String(h)"
        "]);"
        "var value=response&&typeof response==='object'?response:{};"
        "return {"
            "body:function(){return value.body===undefined?String(response||''):value.body;},"
            "url:function(){return value.url===undefined?String(u||''):value.url;},"
            "code:function(){return value.code===undefined?200:value.code;},"
            "headers:function(){"
                "var headers=value.headers||{};"
                "if(typeof headers.get!=='function')headers.get=function(n){"
                    "var key=String(n===undefined?'':n).toLowerCase();"
                    "for(var k in headers){if(String(k).toLowerCase()===key)return headers[k];}"
                    "return '';"
                "};"
                "return headers;"
            "},"
            "header:function(n){"
                "var headers=value.headers||{};"
                "var key=String(n===undefined?'':n).toLowerCase();"
                "for(var k in headers){if(String(k).toLowerCase()===key)return headers[k];}"
                "return '';"
            "}"
        "};"
    "}"
    "};\n"
    "globalThis.cookie={"
    "getCookie:function(u){return __legado_host('cookie.get',[String(u===undefined?'':u)]);},"
    "setCookie:function(u,v){return __legado_host('cookie.set',[String(u),String(v)]);},"
    "removeCookie:function(u){return __legado_host('cookie.remove',[String(u)]);},"
    "getKey:function(u,k){return __legado_host('cookie.key',[String(u),String(k)]);},"
    "length:function(u){return String(cookie.getCookie(u)||'').split(';').filter(function(v){return v.trim()!=='';}).length;}"
    "};\n"
    "function ajax(u,o){return java.ajax(u,o);}"
    "function getCookie(u){return cookie.getCookie(u);}"
    "function setCookie(u,v){return cookie.setCookie(u,v);}"
    "function removeCookie(u){return cookie.removeCookie(u);}"
    "function getVariable(k){return java.getVariable(k);}"
    "function setVariable(k,v){return java.setVariable(k,v);}"
    "function put(k,v){return java.put(k,v);}"
    "function get(k){return java.get(k);}"
    "function putMemory(k,v){return java.putMemory(k,v);}"
    "function getFromMemory(k){return java.getFromMemory(k);}"
    "globalThis.cache={"
        "get:function(k){return java.get(k);},"
        "put:function(k,v){return java.put(k,v);},"
        "getFromMemory:function(k){return java.getFromMemory(k);},"
        "getMemory:function(k){return java.getFromMemory(k);},"
        "putMemory:function(k,v){return java.putMemory(k,v);},"
        "deleteMemory:function(k){return __legado_host('memory.delete',[String(k)]);},"
        "removeMemory:function(k){return __legado_host('memory.delete',[String(k)]);}};"
    "function base64Encode(v){return java.base64Encode(v);}"
    "function deviceID(){return java.deviceID();}"
    "function qread(){return java.qread();}\n"
    "function getArgument(k){return __legado_host('argument.get',[String(k)]);}"
    "function setArgument(k,v){return __legado_host('argument.set',[String(k),v]);}"
    "function getArguments(v,k){return __legado_host('arguments.get',[String(v===undefined?'':v),k===undefined?null:String(k)]);}"
    "function setArguments(k,v){return __legado_host('arguments.set',[String(k),v]);}\n"
    "function URL(value){"
        "var s=String(value||'');"
        "var m=s.match(/^[a-z][a-z0-9+.-]*:\\/\\/([^\\/?#]+)/i);"
        "var h=m?m[1]:'';"
        "return {host:h,_origin:m?(s.match(/^[a-z][a-z0-9+.-]*:\\/\\/[^\\/?#]+/i)||[''])[0]:''};"
    "}"
    "globalThis.HttpUrl={parse:function(value){"
        "var u=URL(value);"
        "return {topPrivateDomain:function(){"
            "var p=String(u.host||'').split('.');"
            "return p.length>=2?p.slice(-2).join('.'):String(u.host||'');"
        "}};"
    "}};\n"
    "function setTimeout(fn){if(typeof fn==='function')fn();return 0;}"
    "function clearTimeout(){}"
    "globalThis.window=typeof globalThis.window==='undefined'?{}:globalThis.window;"
    "globalThis.document=typeof globalThis.document==='undefined'?{}:globalThis.document;";

static const char *LEGADO_RUNNER =
    "(function(){"
    /* Use indirect eval for the library and rule.  Imported Legado libraries
     * commonly call helper functions through `this` (for example
     * `this.createSvg.bind(this)`).  Direct eval keeps function declarations
     * in the temporary IIFE environment, where they are not properties of
     * globalThis and those Android sources fail at runtime. */
    "(0,eval)(__legado_runner_prelude);"
    "(0,eval)(__legado_runner_library);"
    "return (0,eval)(__legado_runner_script);"
    "})()";

static int eval_piece(JSContext *ctx,
                      const char *source,
                      size_t source_length,
                      const char *filename,
                      char *error,
                      size_t error_size) {
    JSValue value = JS_Eval(ctx, source, source_length, filename, JS_EVAL_TYPE_GLOBAL);
    if (!JS_IsException(value)) {
        JS_FreeValue(ctx, value);
        return 0;
    }
    JSValue exception = JS_GetException(ctx);
    const char *message = JS_ToCString(ctx, exception);
    set_output(error, error_size, message != NULL ? message : "JavaScript evaluation failed");
    if (message != NULL) JS_FreeCString(ctx, message);
    JS_FreeValue(ctx, exception);
    return 1;
}

static int serialize_value(JSContext *ctx,
                           JSValue value,
                           char *output,
                           size_t output_size) {
    JSValue encoded = JS_JSONStringify(ctx, value, JS_UNDEFINED, JS_UNDEFINED);
    if (JS_IsException(encoded)) {
        JSValue exception = JS_GetException(ctx);
        const char *message = JS_ToCString(ctx, exception);
        set_output(output, output_size, message != NULL ? message : "cannot serialize JavaScript result");
        if (message != NULL) JS_FreeCString(ctx, message);
        JS_FreeValue(ctx, exception);
        return 1;
    }
    if (JS_IsUndefined(encoded)) {
        set_output(output, output_size, "null");
        JS_FreeValue(ctx, encoded);
        return 0;
    }
    const char *text = JS_ToCString(ctx, encoded);
    if (text == NULL) {
        JS_FreeValue(ctx, encoded);
        set_output(output, output_size, "cannot convert JavaScript result to UTF-8");
        return 1;
    }
    if (strlen(text) + 1 > output_size) {
        JS_FreeCString(ctx, text);
        JS_FreeValue(ctx, encoded);
        set_output(output, output_size, "JavaScript result exceeds bridge buffer");
        return 1;
    }
    memcpy(output, text, strlen(text) + 1);
    JS_FreeCString(ctx, text);
    JS_FreeValue(ctx, encoded);
    return 0;
}

int legado_js_eval(const char *library,
                   const char *script,
                   const char *context_json,
                   legado_js_host_callback callback,
                   char *output,
                   size_t output_size) {
    if (output != NULL && output_size > 0) output[0] = '\0';
    if (library == NULL || script == NULL || context_json == NULL || callback == NULL) {
        set_output(output, output_size, "invalid JavaScript bridge arguments");
        return 2;
    }

    JSRuntime *runtime = JS_NewRuntime();
    if (runtime == NULL) {
        set_output(output, output_size, "cannot create QuickJS runtime");
        return 2;
    }
    /* Keep one evaluation bounded on the low-memory Kindle while leaving
     * enough room for the source library and a normal chapter response. */
    JS_SetMemoryLimit(runtime, 48U * 1024U * 1024U);
    JS_SetMaxStackSize(runtime, 2U * 1024U * 1024U);
    JSContext *ctx = JS_NewContext(runtime);
    if (ctx == NULL) {
        JS_FreeRuntime(runtime);
        set_output(output, output_size, "cannot create QuickJS context");
        return 2;
    }
    LegadoJsHost host = { callback };
    JS_SetContextOpaque(ctx, &host);

    JSValue global = JS_GetGlobalObject(ctx);
    JS_SetPropertyStr(ctx, global, "__legado_host_raw",
                      JS_NewCFunction(ctx, host_call, "__legado_host_raw", 2));
    JSValue context = JS_ParseJSON(ctx, context_json, strlen(context_json), "<legado-context>");
    if (JS_IsException(context)) {
        JS_FreeValue(ctx, global);
        JSValue exception = JS_GetException(ctx);
        const char *message = JS_ToCString(ctx, exception);
        set_output(output, output_size, message != NULL ? message : "invalid JavaScript context JSON");
        if (message != NULL) JS_FreeCString(ctx, message);
        JS_FreeValue(ctx, exception);
        JS_FreeContext(ctx);
        JS_FreeRuntime(runtime);
        return 2;
    }
    JS_SetPropertyStr(ctx, global, "__ctx", context);
    JS_SetPropertyStr(ctx, global, "__legado_runner_prelude",
                      JS_NewString(ctx, LEGADO_PRELUDE));
    JS_SetPropertyStr(ctx, global, "__legado_runner_library",
                      JS_NewString(ctx, library));
    JS_SetPropertyStr(ctx, global, "__legado_runner_script",
                      JS_NewString(ctx, script));
    JS_FreeValue(ctx, global);

    JSValue value = JS_Eval(ctx, LEGADO_RUNNER, strlen(LEGADO_RUNNER),
                            "<legado-runner>", JS_EVAL_TYPE_GLOBAL);
    int failed = 0;
    if (JS_IsException(value)) {
        JSValue exception = JS_GetException(ctx);
        const char *message = JS_ToCString(ctx, exception);
        set_output(output, output_size, message != NULL ? message : "JavaScript rule failed");
        if (message != NULL) JS_FreeCString(ctx, message);
        JS_FreeValue(ctx, exception);
        failed = 1;
    } else {
        failed = serialize_value(ctx, value, output, output_size);
        JS_FreeValue(ctx, value);
    }

    JS_FreeContext(ctx);
    JS_FreeRuntime(runtime);
    return failed ? 1 : 0;
}

const char *legado_js_engine_version(void) {
    return "QuickJS";
}
