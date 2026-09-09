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
                || strcmp(operation, "get") == 0
                || strcmp(operation, "head") == 0
                || strcmp(operation, "connect") == 0
                || strcmp(operation, "getResponse") == 0
                || strcmp(operation, "getStrResponse") == 0
                || strcmp(operation, "ajaxAll") == 0
                || strcmp(operation, "ajaxTestAll") == 0
                || strcmp(operation, "importScript") == 0
                || strcmp(operation, "startBrowserAwait") == 0
                || strcmp(operation, "webView") == 0
                || strcmp(operation, "webViewSource") == 0
                || strcmp(operation, "webViewOverride") == 0)) {
        /* Preserve the historical maximum for network-shaped results and
         * browser-returned documents, avoiding truncation of source pages. */
        return 16U * 1024U * 1024U;
    }
    if (operation != NULL
            && (strcmp(operation, "getString") == 0
                || strcmp(operation, "getStringList") == 0
                || strcmp(operation, "getElement") == 0
                || strcmp(operation, "getElements") == 0
                || strcmp(operation, "bytesToArray") == 0
                || strcmp(operation, "readFile") == 0
                || strcmp(operation, "archiveBytes") == 0
                || strcmp(operation, "source.getHeaderMap") == 0
                || strcmp(operation, "source.getLoginHeaderMap") == 0
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
    /* Preserve explicitly installed package/class members.  The old trap
     * returned a fresh proxy for every property, which made
     * Packages.org.jsoup.Jsoup.parse look callable but discarded the actual
     * Jsoup shim before invocation.  Unknown Java packages still resolve to
     * a lazy proxy. */
    "get:function(target,key){if(key in target)return target[key];return __legado_proxy();},"
    "apply:function(){return {};},"
    "construct:function(){throw new Error('Java class is unavailable on Kindle');}});"
    "}\n"
    "var Packages=__legado_proxy();"
    "function __legado_define(target,key,value){try{Object.defineProperty(target,key,{value:value,writable:true,configurable:true,enumerable:false});}catch(e){target[key]=value;}return value;}"
    "function __legado_wrap_attribute(value){"
        "if(!value||typeof value!=='object')return value;"
        "var a=value;"
        "__legado_define(a,'getKey',function(){return String(a.key===undefined?'':a.key);});"
        "__legado_define(a,'getValue',function(){return String(a.value===undefined?'':a.value);});"
        "__legado_define(a,'toString',function(){return a.getKey()+'=\"'+a.getValue()+'\"';});"
        "return a;"
    "}"
    "function __legado_bytes(value){"
        "var b={__legado_bytes:String(value&&value.__legado_bytes||value||'')};"
        "b.length=Number(__legado_host('bytesLength',[b]));"
        "b.byteAt=function(i){return Number(__legado_host('bytesAt',[b,Number(i)]));};"
        "b.toArray=function(){return __legado_list(__legado_host('bytesToArray',[b]));};"
        "b.toString=function(){return String(__legado_host('bytesToStr',[b]));};"
        "b.toByteArray=function(){return b;};"
        "b.getBytes=function(){return b;};"
        "return b;"
    "}"
    "function __legado_map(value){"
        "var map=value&&typeof value==='object'?value:{};"
        "__legado_define(map,'get',function(k){if(arguments.length===0)return map;var key=String(k===undefined?'':k);return map[key];});"
        "__legado_define(map,'set',function(k,v){"
            "if(arguments.length===1&&k&&typeof k==='object'){"
                "for(var oldKey in map)if(typeof map[oldKey]!=='function')delete map[oldKey];"
                "for(var newKey in k)if(typeof k[newKey]!=='function')map[newKey]=k[newKey];"
                "return map;"
            "}"
            "map[String(k===undefined?'':k)]=v;return map;"
        "});"
        "__legado_define(map,'put',function(k,v){var key=String(k===undefined?'':k),old=map[key];map[key]=v;return old;});"
        "__legado_define(map,'putAll',function(other){if(other)for(var k in other){if(typeof other[k]!=='function')map[k]=other[k];}return map;});"
        "__legado_define(map,'remove',function(k){var key=String(k===undefined?'':k),old=map[key];delete map[key];return old;});"
        "__legado_define(map,'has',function(k){return map[String(k)]!==undefined;});"
        "__legado_define(map,'containsKey',function(k){return map[String(k)]!==undefined;});"
        "__legado_define(map,'containsValue',function(v){for(var k in map){if(typeof map[k]!=='function'&&map[k]===v)return true;}return false;});"
        "__legado_define(map,'isEmpty',function(){for(var k in map){if(typeof map[k]!=='function')return false;}return true;});"
        "__legado_define(map,'size',function(){var n=0;for(var k in map){if(typeof map[k]!=='function')n++;}return n;});"
        "__legado_define(map,'keySet',function(){var a=[];for(var k in map){if(typeof map[k]!=='function')a.push(k);}return __legado_list(a);});"
        "__legado_define(map,'values',function(){var a=[];for(var k in map){if(typeof map[k]!=='function')a.push(map[k]);}return __legado_list(a);});"
        "__legado_define(map,'forEach',function(fn){if(typeof fn==='function')for(var k in map)if(typeof map[k]!=='function')fn(map[k],k,map);return map;});"
        "__legado_define(map,'clear',function(){for(var k in map)if(typeof map[k]!=='function')delete map[k];return null;});"
        "__legado_define(map,'getOrDefault',function(k,v){var value=map[String(k)];return value===undefined?v:value;});"
        "__legado_define(map,'save',function(){__legado_host('infoMap.save',[map]);return null;});"
        "__legado_define(map,'saveNow',function(){__legado_host('infoMap.save',[map]);return null;});"
        "__legado_define(map,'toString',function(){var a=[];for(var k in map){if(typeof map[k]!=='function')a.push(k+'='+map[k]);}return a.join(',');});"
        "return map;"
    "}"
    "function __legado_list(value){"
        "var list=Array.isArray(value)?value:[];"
        "if(list.__legado_list_ready)return list;"
        "__legado_define(list,'__legado_list_ready',true);"
        "__legado_define(list,'get',function(i){var n=Number(i);if(n<0)n=list.length+n;return list[n]===undefined?null:list[n];});"
        "__legado_define(list,'set',function(i,v){var n=Number(i);if(n<0)n=list.length+n;list[n]=v;return v;});"
        "__legado_define(list,'add',function(v){list.push(v);return true;});"
        "__legado_define(list,'addAll',function(v){if(v)for(var i=0;i<v.length;i++)list.push(v[i]);return true;});"
        "__legado_define(list,'size',function(){return list.length;});"
        "__legado_define(list,'isEmpty',function(){return list.length===0;});"
        "__legado_define(list,'toArray',function(){return __legado_list(list.slice());});"
        "__legado_define(list,'contains',function(v){return list.indexOf(v)>=0;});"
        "__legado_define(list,'remove',function(i){var n=Number(i);if(n<0)n=list.length+n;if(n<0||n>=list.length)return null;return list.splice(n,1)[0];});"
        "return list;"
    "}"
    "function __legado_file(path){"
        "var file={path:String(path||'')};"
        "file.exists=function(){return !!__legado_host('file.exists',[file.path]);};"
        "file.isFile=function(){return !!__legado_host('file.isFile',[file.path]);};"
        "file.isDirectory=function(){return !!__legado_host('file.isDirectory',[file.path]);};"
        "file.readText=function(enc){return __legado_host('readTxtFile',[file.path,enc===undefined?null:String(enc)]);};"
        "file.readBytes=function(){return __legado_wrap_value(__legado_host('readFile',[file.path]));};"
        "file.delete=function(){return !!__legado_host('deleteFile',[file.path]);};"
        "file.listFiles=function(){return __legado_list(__legado_host('file.list',[file.path]));};"
        "file.toString=function(){return file.path;};"
        "return file;"
    "}"
    "function __legado_wrap_element(value){"
        "if(!value)return value;"
        "if(value.__legado_html!==undefined&&value.__legado_element===undefined)value.__legado_element=value.__legado_html;"
        "if(value.__legado_element===undefined)return value;"
        "var e=value;"
        "e.__legado_html=String(e.__legado_element);"
        "e.select=function(r){return __legado_wrap_elements(__legado_host('getElements',[String(r===undefined?'':r),e.__legado_html]));};"
        "e.selectFirst=function(r){var a=e.select(r);return a.length?a[0]:null;};"
        "e.first=function(){var a=e.select('*');return a.length?a[0]:null;};"
        "e.last=function(){var a=e.select('*');return a.length?a[a.length-1]:null;};"
        "e.get=function(i){var a=e.select('*'),n=Number(i);return a[n<0?a.length+n:n]||null;};"
        "e.toArray=function(){return [e];};"
        "e.children=function(){return __legado_wrap_elements(__legado_host('element.children',[e.__legado_html]));};"
        "e.parent=function(){var p=e.__legado_parent;return __legado_wrap_value(__legado_host('element.parent',[p?{__legado_parent:p}:e.__legado_html]));};"
        "e.attr=function(k){return String(__legado_host('element.property',[e.__legado_html,String(k===undefined?'':k)]));};"
        "e.hasAttr=function(k){return e.attr(k)!=='';};"
        "e.hasClass=function(k){var c=e.attr('class').split(/\\s+/);return c.indexOf(String(k))>=0;};"
        "e.text=function(){return String(__legado_host('element.property',[e.__legado_html,'text']));};"
        "e.ownText=function(){return String(__legado_host('element.property',[e.__legado_html,'ownText']));};"
        "e.html=function(){return String(__legado_host('element.property',[e.__legado_html,'html']));};"
        "e.outerHtml=function(){return String(__legado_host('element.property',[e.__legado_html,'outerHtml']));};"
        "e.toString=function(){return e.outerHtml();};"
        "e.tagName=function(){return String(__legado_host('element.property',[e.__legado_html,'tagName']));};"
        "e.className=function(){return String(__legado_host('element.property',[e.__legado_html,'className']));};"
        "e.id=function(){return String(__legado_host('element.property',[e.__legado_html,'id']));};"
        "e.textNodes=function(){var s=String(__legado_host('element.property',[e.__legado_html,'textNodes']));return s===''?[]:[s];};"
        "e.attributes=function(){return __legado_wrap_attributes(__legado_host('element.attributes',[e.__legado_html]));};"
        "e.remove=function(){return e;};"
        "return e;"
    "}"
    "function __legado_wrap_attributes(value){"
        "if(!Array.isArray(value))return [];"
        "return __legado_list(value.map(__legado_wrap_attribute));"
    "}"
    "function __legado_wrap_value(value){"
        "if(Array.isArray(value))return __legado_list(value.map(__legado_wrap_value));"
        "if(value&&typeof value==='object'){"
            "if(value.__legado_element!==undefined||value.__legado_html!==undefined)return __legado_wrap_element(value);"
            "if(value.__legado_bytes!==undefined)return __legado_bytes(value);"
            "if(value.__legado_attribute!==undefined)return __legado_wrap_attribute(value);"
            "return __legado_map(value);"
        "}"
        "return value;"
    "}"
    "function __legado_context_value(value){"
        "if(Array.isArray(value))return __legado_list(value.map(__legado_context_value));"
        "return __legado_wrap_value(value);"
    "}"
    "function __legado_bind_rule_object(value,kind){"
        "var object=__legado_context_value(value||{});"
        "if(kind==='book'){"
            "__legado_define(object,'getName',function(){return String(object.name===undefined?'':object.name);});"
            "__legado_define(object,'getAuthor',function(){return String(object.author===undefined?'':object.author);});"
            "__legado_define(object,'getBookUrl',function(){return String(object.bookUrl===undefined?'':object.bookUrl);});"
            "__legado_define(object,'getCoverUrl',function(){return String(object.customCoverUrl||object.coverUrl||'');});"
            "__legado_define(object,'getTotalChapterNum',function(){return Number(object.totalChapterNum||0);});"
            "__legado_define(object,'getCustomVariable',function(){return __legado_host('book.getVariable',['custom']);});"
            "__legado_define(object,'putCustomVariable',function(v){return __legado_host('book.setVariable',['custom',v]);});"
            "__legado_define(object,'getKindList',function(){var a=[];if(object.wordCount)a.push(String(object.wordCount));if(object.kind)String(object.kind).split(/[,\\n]/).forEach(function(v){if(v.trim())a.push(v.trim());});return __legado_list(a);});"
            "__legado_define(object,'getVariableMap',function(){return __legado_map(__legado_host('book.getVariableMap',[]));});"
            "__legado_define(object,'getVariable',function(k){return __legado_host('book.getVariable',[String(k===undefined?'':k)]);});"
            "__legado_define(object,'putVariable',function(k,v){return __legado_host('book.setVariable',[String(k===undefined?'':k),v]);});"
            "__legado_define(object,'setVariable',function(k,v){return __legado_host('book.setVariable',[String(k===undefined?'':k),v]);});"
            "__legado_define(object,'getBigVariable',function(k){return __legado_host('book.getBigVariable',[String(k===undefined?'':k)]);});"
            "__legado_define(object,'setBigVariable',function(k,v){return __legado_host('book.setBigVariable',[String(k===undefined?'':k),v]);});"
            "__legado_define(object,'setUseReplaceRule',function(v){return '';});"
        "}else if(kind==='chapter'){"
            "__legado_define(object,'getUrl',function(){return String(object.url===undefined?'':object.url);});"
            "__legado_define(object,'getTitle',function(){return String(object.title===undefined?'':object.title);});"
            "__legado_define(object,'getBookUrl',function(){return String(object.bookUrl===undefined?'':object.bookUrl);});"
            "__legado_define(object,'getBaseUrl',function(){return String(object.baseUrl===undefined?'':object.baseUrl);});"
            "__legado_define(object,'getIndex',function(){return Number(object.index||0);});"
            "__legado_define(object,'getVariableMap',function(){return __legado_map(__legado_host('chapter.getVariableMap',[]));});"
            "__legado_define(object,'getVariable',function(k){return __legado_host('chapter.getVariable',[String(k===undefined?'':k)]);});"
            "__legado_define(object,'putVariable',function(k,v){return __legado_host('chapter.setVariable',[String(k===undefined?'':k),v]);});"
            "__legado_define(object,'setVariable',function(k,v){return __legado_host('chapter.setVariable',[String(k===undefined?'':k),v]);});"
            "__legado_define(object,'getBigVariable',function(k){return __legado_host('chapter.getBigVariable',[String(k===undefined?'':k)]);});"
            "__legado_define(object,'setBigVariable',function(k,v){return __legado_host('chapter.setBigVariable',[String(k===undefined?'':k),v]);});"
        "}"
        "return object;"
    "}"
    "function __legado_wrap_elements(value){"
        "if(!Array.isArray(value))return [];"
        "var a=__legado_list(value.map(__legado_wrap_value));"
        /* Jsoup's Elements is a Java collection, not a bare JavaScript
         * array.  A fair number of imported sources use select(...).first(),
         * get(), or size() before converting it with Array.from().  Keep the
         * array behaviour (including Array.from and indexing) while exposing
         * the small collection surface those sources expect. */
        "__legado_define(a,'first',function(){return a.length?a[0]:null;});"
        "__legado_define(a,'last',function(){return a.length?a[a.length-1]:null;});"
        "__legado_define(a,'get',function(i){var n=Number(i);if(n<0)n=a.length+n;return a[n]===undefined?null:a[n];});"
        "__legado_define(a,'size',function(){return a.length;});"
        "__legado_define(a,'isEmpty',function(){return a.length===0;});"
        "__legado_define(a,'toArray',function(){return __legado_list(a.slice());});"
        "__legado_define(a,'each',function(fn){if(typeof fn==='function')for(var i=0;i<a.length;i++)fn(a[i],i);return a;});"
        "__legado_define(a,'text',function(){var out=[];for(var i=0;i<a.length;i++)if(a[i])out.push(a[i].text());return out.join(' ');});"
        "__legado_define(a,'html',function(){var out=[];for(var i=0;i<a.length;i++)if(a[i])out.push(a[i].html());return out.join('');});"
        "__legado_define(a,'toString',function(){return a.text();});"
        "return a;"
    "}"
    "function __legado_wrap_response(value,fallback){"
        "var r=value&&typeof value==='object'?value:{};"
        "if(r._body===undefined&&typeof r.body!=='function')r._body=r.body;"
        "if(r._url===undefined&&typeof r.url!=='function')r._url=r.url;"
        "if(r._code===undefined&&typeof r.code!=='function')r._code=r.code;"
        "if(r._message===undefined&&typeof r.message!=='function')r._message=r.message;"
        "if(r._headers===undefined&&typeof r.headers!=='function')r._headers=r.headers;"
        "if(r._cookies===undefined&&typeof r.cookies!=='function')r._cookies=r.cookies;"
        "if(r._errorBody===undefined&&typeof r.errorBody!=='function')r._errorBody=r.errorBody;"
        "r.body=function(){return r._body===undefined?'':r._body;};"
        "r.url=function(){return String(r._url===undefined?fallback||'':r._url);};"
        "r.code=function(){return r._code===undefined?200:r._code;};"
        "r.message=function(){return String(r._message===undefined?'OK':r._message);};"
        "r.headers=function(name){var headers=__legado_map(r._headers||{});if(arguments.length===0)return headers;var wanted=String(name===undefined?'':name).toLowerCase();var found;for(var key in headers){if(String(key).toLowerCase()===wanted){found=headers[key];break;}}return found===undefined?[]:__legado_list([found]);};"
        "r.header=function(k){var wanted=String(k===undefined?'':k).toLowerCase();var headers=r._headers||{};for(var key in headers){if(String(key).toLowerCase()===wanted)return headers[key];}return '';};"
        "r.cookies=function(){var result=[];var cookies=r._cookies||{};for(var key in cookies){result.push([key,cookies[key]]);}return __legado_list(result);};"
        /* StrResponse.raw() is used by redirect-aware sources as
         * `raw().request().url()`. Keep a small request/response facade here
         * and keep the LuaSocket object outside QuickJS. */
        "r.raw=function(){var request={url:function(){return r.url();},toString:function(){return r.url();}};return {request:function(){return request;},url:function(){return r.url();},code:function(){return r.code();},message:function(){return r.message();},headers:function(){return r.headers();},header:function(k){return r.header(k);},toString:function(){return r.toString();}};};"
        "r.isSuccessful=function(){var code=Number(r._code===undefined?200:r._code);return code>=200&&code<300;};"
        "r.callTime=function(){return Number(r._callTime||0);};"
        "r.errorBody=function(){return r._errorBody||null;};"
        "r.toString=function(){return r.body();};"
        "return r;"
    "}"
    "function __legado_wrap_responses(value){if(!Array.isArray(value))return __legado_list([]);var result=[];for(var i=0;i<value.length;i++)result.push(__legado_wrap_response(value[i]));return __legado_list(result);}"
    "var __legado_org=__legado_proxy();"
    "__legado_org.jsoup=__legado_proxy();"
    "__legado_org.jsoup.Jsoup={parse:function(v){return __legado_wrap_element({__legado_element:String(v===undefined?'':v)});}};"
    "Packages.org=__legado_org;"
    /* Rhino exposes imported packages both through Packages.* and through a
     * short global name.  Imported sources use both spellings. */
    "globalThis.org=__legado_org;"
    "var __legado_android=__legado_proxy();"
    "__legado_android.util=__legado_proxy();"
    "__legado_android.util.Base64={encodeToString:function(v,f){return java.base64Encode(v,f);},decode:function(v,f){return __legado_wrap_value(__legado_host('base64DecodeBytes',[v,f===undefined?0:f]));}};"
    "Packages.android=__legado_android;"
    "globalThis.android=__legado_android;"
    "var __legado_java=__legado_proxy();"
    "__legado_java.lang=__legado_proxy();"
    "__legado_java.lang.Thread={sleep:function(v){return __legado_host('sleep',[v]);}};"
    "__legado_java.lang.System={currentTimeMillis:function(){return Date.now();},getProperty:function(v){return '';}};"
    "__legado_java.lang.String=function(v,c){var s=(v&&typeof v==='object'&&v.__legado_bytes)?String(__legado_host('bytesToStr',[v,c===undefined?null:String(c)])):String(v===undefined?'':v);if(new.target){this.value=s;this.toString=function(){return s;};this.valueOf=function(){return s;};this.getBytes=function(enc){return __legado_wrap_value(__legado_host('strToBytes',[s,enc===undefined?null:String(enc)]));};this.length=s.length;return this;}return s;};"
    "__legado_java.lang.Integer=function(v){var n=Number(v||0);if(new.target){this.value=n;this.toString=function(){return String(n);};this.valueOf=function(){return n;};return this;}return n;};"
    "__legado_java.lang.Long=__legado_java.lang.Integer;"
    "__legado_java.lang.Double=__legado_java.lang.Integer;"
    "__legado_java.lang.Boolean=function(v){var b=typeof v==='string'?/^(true|1|yes)$/i.test(v):!!v;if(new.target){this.value=b;this.toString=function(){return String(b);};this.valueOf=function(){return b;};return this;}return b;};"
    "__legado_java.lang.String.valueOf=function(v){return String(v===undefined?'':v);};"
    "__legado_java.lang.Integer.parseInt=function(v,r){return parseInt(String(v),r===undefined?10:Number(r));};"
    "__legado_java.lang.Integer.valueOf=function(v,r){return Number(__legado_java.lang.Integer.parseInt(v,r));};"
    "__legado_java.lang.Long.parseLong=__legado_java.lang.Integer.parseInt;"
    "__legado_java.lang.Long.valueOf=__legado_java.lang.Integer.valueOf;"
    "__legado_java.lang.Double.parseDouble=function(v){return Number(v);};"
    "__legado_java.lang.Double.valueOf=function(v){return Number(v);};"
    "__legado_java.lang.Boolean.parseBoolean=function(v){return /^(true|1|yes)$/i.test(String(v));};"
    "__legado_java.util=__legado_proxy();"
    "__legado_java.util.Base64={getDecoder:function(){return {decode:function(v){return __legado_wrap_value(__legado_host('base64DecodeBytes',[v,0]));}};},getUrlDecoder:function(){return {decode:function(v){return __legado_wrap_value(__legado_host('base64DecodeBytes',[v,8]));}};},getEncoder:function(){return {encodeToString:function(v){return java.base64Encode(v,2);}};},getUrlEncoder:function(){return {encodeToString:function(v){return java.base64Encode(v,10);}};}};"
    "__legado_java.util.HashMap=function(){return __legado_map({});};"
    "__legado_java.util.ArrayList=function(){return __legado_list([]);};"
    "__legado_java.net=__legado_proxy();"
    "__legado_java.net.URL=function(v,b){var u=__legado_url(v,b);if(new.target){for(var k in u)this[k]=u[k];this.toString=u.toString;return this;}return u;};"
    "__legado_java.io=__legado_proxy();"
    /* Small byte-stream shims cover the common XOR/decode helpers used by
     * sources. They operate on the bridge's base64-backed byte marker, so
     * binary data never has to be placed directly in JSON. */
    "__legado_java.io.ByteArrayInputStream=function(v){var data=__legado_wrap_value(v&&v.__legado_bytes?v:__legado_host('strToBytes',[v===undefined?'':v]));var p=0;return {read:function(){if(p>=data.length)return -1;return data.byteAt(p++);},available:function(){return data.length-p;},close:function(){p=data.length;}};};"
    "__legado_java.io.ByteArrayOutputStream=function(){var data=[];return {write:function(v,o,l){if(v&&typeof v==='object'&&v.__legado_bytes){var a=__legado_host('bytesToArray',[v]);var start=Math.max(0,Number(o)||0);var end=l===undefined?a.length:start+Math.max(0,Number(l)||0);for(var i=start;i<end&&i<a.length;i++)data.push(Number(a[i])&255);}else if(Array.isArray(v)){var start2=Math.max(0,Number(o)||0);var end2=l===undefined?v.length:start2+Math.max(0,Number(l)||0);for(var j=start2;j<end2&&j<v.length;j++)data.push(Number(v[j])&255);}else if(v!==undefined)data.push(Number(v)&255);return null;},toByteArray:function(){return __legado_wrap_value(__legado_host('bytesFromArray',[data]));},toString:function(){var out='';for(var i=0;i<data.length;i++)out+=String.fromCharCode(data[i]);return out;},close:function(){}};};"
    "Packages.java=__legado_java;"
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
    "globalThis.result=__legado_context_value(__ctx.result===undefined?'':__ctx.result);"
    "globalThis.src=__legado_context_value(__ctx.src===undefined?globalThis.result:__ctx.src);"
    "globalThis.nextChapterUrl=String(__ctx.nextChapterUrl||'');"
    "globalThis.rssArticle=__legado_context_value(__ctx.rssArticle||{});"
    "globalThis.isFromBookInfo=__ctx.isFromBookInfo===true;"
    "globalThis.book=__legado_bind_rule_object(__ctx.book||{},'book');"
    "globalThis.chapter=__legado_bind_rule_object(__ctx.chapter||{},'chapter');"
    "globalThis.host=__legado_context_value(__ctx.host||[]);\n"
    /* Explore scripts use a source-local InfoMap to remember the selected
     * category/filter.  It is deliberately separate from Android UI settings
     * and is serialized by the Lua session layer only for this source. */
    "globalThis.infoMap=__legado_map(__ctx.infoMap||{});\n"
    "globalThis.source=__legado_map(__ctx.sourceData||{});"
    "source.bookSourceUrl=String(source.bookSourceUrl===undefined?__ctx.sourceUrl||'':source.bookSourceUrl);"
    "source.bookSourceName=String(source.bookSourceName===undefined?__ctx.sourceName||'':source.bookSourceName);"
    "source.bookSourceComment=String(source.bookSourceComment===undefined?__ctx.sourceComment||'':source.bookSourceComment);"
    "source.key=String(source.bookSourceUrl||__ctx.sourceUrl||'');"
    "source.getTag=function(){return __legado_host('source.getTag',[]);};"
    "source.header=source.header===undefined?__ctx.sourceHeader||'':source.header;"
    "source.getVariable=function(){return __legado_host('source.getVariable',[]);};"
    "source.setVariable=function(v){var value=String(v===undefined?'':v);source.variable=value;return __legado_host('source.setVariable',[value]);};"
    "source.getLoginInfo=function(){return __legado_host('source.getLoginInfo',[]);};"
    "source.getLoginInfoMap=function(){return __legado_map(__legado_host('source.getLoginInfoMap',[]));};"
    "source.login=function(){return __legado_host('source.login',[]);};"
    "source.getHeaderMap=function(v){return __legado_map(__legado_host('source.getHeaderMap',[v===undefined?true:!!v]));};"
    "source.getLoginHeader=function(){return __legado_host('source.getLoginHeader',[]);};"
    "source.getLoginHeaderMap=function(){return __legado_map(__legado_host('source.getLoginHeaderMap',[]));};"
    "source.putLoginHeader=function(v){source.loginHeader=v;return __legado_host('source.putLoginHeader',[v]);};"
    "source.removeLoginHeader=function(){source.loginHeader='';return __legado_host('source.removeLoginHeader',[]);};"
    "source.putLoginInfo=function(v){source.loginInfo=v;return __legado_host('source.putLoginInfo',[v]);};"
    "source.removeLoginInfo=function(){source.loginInfo='{}';return __legado_host('source.removeLoginInfo',[]);};"
    "source.putVariable=function(v){return source.setVariable(v);};"
    "source.refreshExplore=function(){return __legado_host('refreshExplore',[]);};"
    "source.refreshJSLib=function(){return __legado_host('refreshJSLib',[]);};"
    "source.putConcurrent=function(v){var value=String(v===undefined?'':v);source.concurrentRate=value;return __legado_host('source.putConcurrent',[value]);};"
    "source.getKey=function(){return __legado_host('source.getKey',[]);};"
    "source.get=function(k){return __legado_host('source.get',[String(k)]);};"
    "source.put=function(k,v){var key=String(k);source[key]=v;return __legado_host('source.put',[key,v]);};"
    /* Do not overwrite the serialized loginUi field. On Android it is
     * generally an array or a rule string, and source scripts may inspect it. */
    "\n"
    /* A small JsURL-compatible value.  The Android helper exposes only a
     * handful of URL fields, but source scripts use those fields heavily for
     * redirects, signatures and query parameters. */
    "function __legado_url(value,base){"
        "var input=String(value||'');"
        "var baseValue=String(base||globalThis.baseUrl||'');"
        "if(!/^[a-z][a-z0-9+.-]*:\\/\\//i.test(input)&&baseValue){"
            "try{input=String(__legado_host('url.absolute',[baseValue,input]));}catch(e){"
                "if(input.charAt(0)==='/'){var bm=baseValue.match(/^[a-z][a-z0-9+.-]*:\\/\\/[^\\/?#]+/i);input=(bm?bm[0]:'')+input;}"
                "else{input=baseValue.replace(/[^\\/?#]*([?#].*)?$/,'')+input;}"
            "}"
        "}"
        "var match=input.match(/^([a-z][a-z0-9+.-]*):\\/\\/([^\\/?#]*)([^?#]*)(?:\\?([^#]*))?(?:#(.*))?$/i);"
        "var protocol=match?match[1]+':':'';"
        "var authority=match?match[2]:'';"
        "var hostPort=authority.replace(/^.*@/,'');"
        "var hostname=hostPort.replace(/^\\[|\\]$/g,'').replace(/:\\d+$/,'');"
        "var portMatch=hostPort.match(/:(\\d+)$/);"
        "var port=portMatch?portMatch[1]:'';"
        "var path=match?(match[3]||'/'):input.split(/[?#]/)[0];"
        "var query=match?match[4]||'':(input.match(/^.*?\\?([^#]*)/)||['',''])[1];"
        "var fragment=match?match[5]||'':(input.match(/#(.*)$/)||['',''])[1];"
        "var params={};"
        "if(query!=='')for(var part of query.split('&')){if(part==='')continue;var pair=part.split('=');var pk=pair.shift()||'';var pv=pair.join('=');try{pk=decodeURIComponent(pk.replace(/\\+/g,' '));pv=decodeURIComponent(pv.replace(/\\+/g,' '));}catch(e){}params[pk]=pv;}"
        "var origin=match?protocol+'//'+authority:'';"
        "var result={href:input,url:input,protocol:protocol,host:hostPort,hostname:hostname,port:port,origin:origin,pathname:path,path:path,query:query,search:query?'?'+query:'',hash:fragment?'#'+fragment:'',searchParams:__legado_map(params)};"
        "__legado_define(result,'toString',function(){return input;});"
        "return result;"
    "}\n"
    /* Keep the imported Java package tree visible on the short `java` name.
     * Android/Rhino sources commonly use `java.lang.Thread.sleep(...)` and
     * `java.util.*` directly, while other sources use `Packages.java.*`. */
    "java={"
    "ajax:function(url,options){var request=Array.isArray(url)?(url.length?url[0]:''):url;var opts=typeof options==='number'?{timeout:options}:options;return __legado_host('ajax',[String(request===undefined?'':request),opts===undefined?null:opts]);},"
    "ajaxAll:function(urls,skipRateLimit){return __legado_wrap_responses(__legado_host('ajaxAll',[urls===undefined?[]:urls,skipRateLimit===undefined?false:!!skipRateLimit]));},"
    "ajaxTestAll:function(urls,timeout,skipRateLimit){return __legado_wrap_responses(__legado_host('ajaxTestAll',[urls===undefined?[]:urls,timeout===undefined?0:timeout,skipRateLimit===undefined?false:!!skipRateLimit]));},"
    "base64Encode:function(v,f){return __legado_host('base64Encode',[v===undefined?'':v,f===undefined?null:f]);},"
    "base64Decode:function(v,c){return __legado_host('base64Decode',[v===undefined?'':v,c===undefined?null:c]);},"
    "base64DecodeToByteArray:function(v,f){return __legado_wrap_value(__legado_host('base64DecodeBytes',[v===undefined?'':v,f===undefined?0:f]));},"
    "hexDecodeToString:function(v){return __legado_host('hexDecodeToString',[String(v===undefined?'':v)]);},"
    "hexDecode:function(v){return __legado_host('hexDecode',[v===undefined?'':v]);},"
    "hexDecodeToByteArray:function(v){return __legado_wrap_value(__legado_host('hexDecodeBytes',[String(v===undefined?'':v)]));},"
    "hexEncodeToString:function(v){return __legado_host('hexEncode',[v===undefined?'':v]);},"
    "md5Encode:function(v){return __legado_host('md5Encode',[String(v===undefined?'':v)]);},"
    "md5Encode16:function(v){return __legado_host('md5Encode16',[String(v===undefined?'':v)]);},"
    "strToBytes:function(v,c){return __legado_wrap_value(__legado_host('strToBytes',[v===undefined?'':v,c===undefined?null:String(c)]));},"
    "bytesToStr:function(v,c){return __legado_host('bytesToStr',[v===undefined?'':v,c===undefined?null:c]);},"
    "getString:function(r,c,u){return __legado_host('getString',[String(r===undefined?'':r),c===undefined?null:c,u===undefined?false:!!u]);},"
    "getStringList:function(r,c,u){return __legado_list(__legado_host('getStringList',[String(r===undefined?'':r),c===undefined?null:c,u===undefined?false:!!u]));},"
    "getElement:function(r,c){return __legado_wrap_value(__legado_host('getElement',[String(r===undefined?'':r),c===undefined?null:c]));},"
    "getElements:function(r,c){return __legado_wrap_elements(__legado_host('getElements',[String(r===undefined?'':r),c===undefined?null:c]));},"
    "setContent:function(v,b){return __legado_host('setContent',[v===undefined?'':v,b===undefined?null:b]);},"
    "post:function(u,b,h,t){return __legado_wrap_response(__legado_host('post',[String(u===undefined?'':u),b===undefined?null:b,h===undefined?null:h,t===undefined?null:t]),u);},"
    "head:function(u,h,t){return __legado_wrap_response(__legado_host('head',[String(u===undefined?'':u),h===undefined?null:h,t===undefined?null:t]),u);},"
    "connect:function(u,h,t){return __legado_wrap_response(__legado_host('connect',[String(u===undefined?'':u),h===undefined?null:h,t===undefined?null:t]),u);},"
    "getStrResponse:function(js,r){var u=String(java.url||'');return __legado_wrap_response(__legado_host('getStrResponse',[js===undefined?null:js,r===undefined?null:r,u,java.headerMap||{}]),u);},"
    "getResponse:function(){var u=String(java.url||'');return __legado_wrap_response(__legado_host('getResponse',[u,java.headerMap||{}]),u);},"
    "initUrl:function(){var value=__legado_host('initUrl',[String(java.url||''),java.headerMap||{}]);if(value!==undefined&&value!==null&&String(value)!=='')java.url=String(value);return value;},"
    "encodeURI:function(v,c){return __legado_host('encodeURI',[String(v===undefined?'':v),c===undefined?null:String(c)]);},"
    "importScript:function(u){"
        "var code=__legado_host('importScript',[String(u===undefined?'':u)]);"
        "if(code)(0,eval)(code);"
        "return code;"
    "},"
    "openUrl:function(u,m){return __legado_host('openUrl',[String(u===undefined?'':u),m===undefined?null:String(m)]);},"
    "reGetBook:function(){return __legado_host('reGetBook',[]);},"
    "refreshTocUrl:function(){return __legado_host('refreshTocUrl',[]);},"
    "get:function(k,h,t){var key=String(k===undefined?'':k);"
        "if(arguments.length>1||/^(?:https?|data):/i.test(key)||key.indexOf('/')===0){"
            "return __legado_wrap_response(__legado_host('get',[key,h===undefined?null:h,t===undefined?null:t]),key);"
        "}"
        "return __legado_host('store.get',[key]);},"
    "put:function(k,v){return __legado_host('store.put',[String(k),v]);},"
    "getVariable:function(k){return __legado_host('variable.get',[k===undefined?null:String(k)]);},"
    "setVariable:function(k,v){return __legado_host('variable.set',[String(k),v]);},"
    "putMemory:function(k,v){return __legado_host('memory.put',[String(k),v]);},"
    "getFromMemory:function(k){return __legado_host('memory.get',[String(k)]);},"
    "setMemory:function(k,v){return __legado_host('memory.put',[String(k),v]);},"
    "getCookie:function(u,k){var url=String(u===undefined?'':u);return k===undefined?__legado_host('cookie.get',[url]):__legado_host('cookie.key',[url,String(k)]);},"
    "setCookie:function(u,v){return __legado_host('cookie.set',[String(u),String(v)]);},"
    "removeCookie:function(u){return __legado_host('cookie.remove',[String(u)]);},"
    "replaceCookie:function(u,v){return __legado_host('cookie.replace',[String(u),String(v)]);},"
    "getWebViewUA:function(){return __legado_host('userAgent',[]);},"
    "deviceID:function(){return __legado_host('deviceId',[]);},"
    "androidId:function(){return __legado_host('androidId',[]);},"
    "qread:function(){return __legado_host('unsupported',['qread']);},"
    "reLoginView:function(){return '';},"
    "hasJavaClass:function(n){return false;},"
    "log:function(v){return __legado_host('log',[String(v)]);},"
    "toast:function(v){return __legado_host('toast',[String(v)]);},"
    "longToast:function(v){return __legado_host('toast',[String(v)]);},"
    "refreshExplore:function(){return __legado_host('refreshExplore',[]);},"
    "timeFormat:function(v,f){return __legado_host('timeFormat',[v===undefined?'':v,f===undefined?null:f]);},"
    "timeFormatUTC:function(v,f,s){return __legado_host('timeFormatUTC',[v===undefined?'':v,f===undefined?null:f,s===undefined?0:s]);},"
    "randomUUID:function(){return __legado_host('randomUUID',[]);},"
    "t2s:function(v){return __legado_host('t2s',[String(v===undefined?'':v)]);},"
    "s2t:function(v){return __legado_host('s2t',[String(v===undefined?'':v)]);},"
    "logType:function(v){return __legado_host('logType',[typeof v]);},"
    "getVerificationCode:function(u){return __legado_host('getVerificationCode',[String(u===undefined?'':u)]);},"
    "cacheFile:function(u,t){return __legado_host('cacheFile',[String(u===undefined?'':u),t===undefined?0:t]);},"
    "downloadFile:function(a,b){return __legado_host('downloadFile',[String(a===undefined?'':a),b===undefined?null:String(b)]);},"
    "unArchiveFile:function(p){return __legado_host('unArchiveFile',[String(p===undefined?'':p)]);},"
    "unzipFile:function(p){return __legado_host('unzipFile',[String(p===undefined?'':p)]);},"
    "unrarFile:function(p){return __legado_host('unrarFile',[String(p===undefined?'':p)]);},"
    "un7zFile:function(p){return __legado_host('un7zFile',[String(p===undefined?'':p)]);},"
    "getTxtInFolder:function(p){return __legado_host('getTxtInFolder',[String(p===undefined?'':p)]);},"
    "getFile:function(p){return __legado_file(String(p===undefined?'':p));},"
    "readFile:function(p){return __legado_wrap_value(__legado_host('readFile',[String(p===undefined?'':p)]));},"
    "readTxtFile:function(p,c){return __legado_host('readTxtFile',[String(p===undefined?'':p),c===undefined?null:String(c)]);},"
    "deleteFile:function(p){return __legado_host('deleteFile',[String(p===undefined?'':p)]);},"
    "htmlFormat:function(v){return __legado_host('htmlFormat',[String(v===undefined?'':v)]);},"
    "toNumChapter:function(v){return __legado_host('toNumChapter',[v===undefined?'':String(v)]);},"
    "queryTTF:function(v,c){return __legado_wrap_value(__legado_host('queryTTF',[v===undefined?null:v,c===undefined?true:!!c]));},"
    "queryBase64TTF:function(v){return __legado_host('queryBase64TTF',[v===undefined?null:v]);},"
    "replaceFont:function(v,a,b,c){return __legado_host('replaceFont',[v===undefined?'':String(v),a===undefined?null:a,b===undefined?null:b,c===undefined?false:!!c]);},"
    "getZipStringContent:function(u,p,c){return __legado_host('archiveString',[String(u||''),String(p||''),c===undefined?null:String(c),'zip']);},"
    "getRarStringContent:function(u,p,c){return __legado_host('archiveString',[String(u||''),String(p||''),c===undefined?null:String(c),'rar']);},"
    "get7zStringContent:function(u,p,c){return __legado_host('archiveString',[String(u||''),String(p||''),c===undefined?null:String(c),'7z']);},"
    "getZipByteArrayContent:function(u,p){return __legado_wrap_value(__legado_host('archiveBytes',[String(u||''),String(p||''),'zip']));},"
    "getRarByteArrayContent:function(u,p){return __legado_wrap_value(__legado_host('archiveBytes',[String(u||''),String(p||''),'rar']));},"
    "get7zByteArrayContent:function(u,p){return __legado_wrap_value(__legado_host('archiveBytes',[String(u||''),String(p||''),'7z']));},"
    "toURL:function(u,b){return __legado_url(String(u===undefined?'':u),b===undefined?null:String(b));},"
    "digestHex:function(v,a){return __legado_host('digestHex',[v===undefined?'':v,a===undefined?'SHA-256':String(a)]);},"
    "digestBase64Str:function(v,a){return __legado_host('digestBase64',[v===undefined?'':v,a===undefined?'SHA-256':String(a)]);},"
    "HMacHex:function(v,a,k){return __legado_host('hmacHex',[v===undefined?'':v,String(a===undefined?'SHA-256':a),k===undefined?'':k]);},"
    "HMacBase64:function(v,a,k){return __legado_host('hmacBase64',[v===undefined?'':v,String(a===undefined?'SHA-256':a),k===undefined?'':k]);},"
    /* Keep the deprecated AES/DES/3DES helpers used by older community
     * sources. They are aliases over the same transformation implementation
     * as createSymmetricCrypto, so legacy and modern rules share padding and
     * binary-value semantics. */
    "aesDecodeToByteArray:function(d,k,t,i){return __legado_wrap_value(__legado_host('crypto.decrypt',[String(t||''),k,i,d]));},"
    "aesDecodeToString:function(d,k,t,i){return __legado_host('crypto.decryptStr',[String(t||''),k,i,d]);},"
    "aesBase64DecodeToByteArray:function(d,k,t,i){return __legado_wrap_value(__legado_host('crypto.decrypt',[String(t||''),k,i,d]));},"
    "aesBase64DecodeToString:function(d,k,t,i){return __legado_host('crypto.decryptStr',[String(t||''),k,i,d]);},"
    "aesEncodeToByteArray:function(d,k,t,i){return __legado_wrap_value(__legado_host('crypto.encrypt',[String(t||''),k,i,d]));},"
    "aesEncodeToString:function(d,k,t,i){return __legado_host('crypto.encryptBase64',[String(t||''),k,i,d]);},"
    "aesEncodeToBase64ByteArray:function(d,k,t,i){var v=__legado_host('crypto.encryptBase64',[String(t||''),k,i,d]);return __legado_wrap_value(__legado_host('strToBytes',[v]));},"
    "aesEncodeToBase64String:function(d,k,t,i){return __legado_host('crypto.encryptBase64',[String(t||''),k,i,d]);},"
    "aesDecodeArgsBase64Str:function(d,k,m,p,i){var kk=java.base64DecodeToByteArray(k),iv=java.base64DecodeToByteArray(i);return __legado_host('crypto.decryptStr',['AES/'+m+'/'+p,kk,iv,d]);},"
    "aesEncodeArgsBase64Str:function(d,k,m,p,i){var kk=java.base64DecodeToByteArray(k),iv=java.base64DecodeToByteArray(i);return __legado_host('crypto.encryptBase64',['AES/'+m+'/'+p,kk,iv,d]);},"
    "desDecodeToString:function(d,k,t,i){return __legado_host('crypto.decryptStr',[String(t||''),k,i,d]);},"
    "desBase64DecodeToString:function(d,k,t,i){return __legado_host('crypto.decryptStr',[String(t||''),k,i,d]);},"
    "desEncodeToString:function(d,k,t,i){return __legado_host('crypto.encryptBase64',[String(t||''),k,i,d]);},"
    "desEncodeToBase64String:function(d,k,t,i){return __legado_host('crypto.encryptBase64',[String(t||''),k,i,d]);},"
    "tripleDESDecodeStr:function(d,k,m,p,i){return __legado_host('crypto.decryptStr',['DESede/'+m+'/'+p,k,i,d]);},"
    "tripleDESDecodeArgsBase64Str:function(d,k,m,p,i){var kk=java.base64DecodeToByteArray(k);return __legado_host('crypto.decryptStr',['DESede/'+m+'/'+p,kk,i,d]);},"
    "tripleDESEncodeBase64Str:function(d,k,m,p,i){return __legado_host('crypto.encryptBase64',['DESede/'+m+'/'+p,k,i,d]);},"
    "tripleDESEncodeArgsBase64Str:function(d,k,m,p,i){var kk=java.base64DecodeToByteArray(k);return __legado_host('crypto.encryptBase64',['DESede/'+m+'/'+p,kk,i,d]);},"
    "url:String(__ctx.baseUrl||''),"
    "urlNoQuery:String(__ctx.baseUrl||''),"
    "key:String(__ctx.key||''),"
    "headerMap:__legado_map(__legado_host('source.getHeaderMap',[true])),"
    "getHeaderMap:function(){return java.headerMap;},"
    "getSource:function(){return source;},"
    "getTag:function(){return __legado_host('source.getTag',[]);},"
    "createSymmetricCrypto:function(t,k,i){var c={transformation:String(t||''),key:k,iv:i};"
        "c.decrypt=function(v){return __legado_wrap_value(__legado_host('crypto.decrypt',[c.transformation,c.key,c.iv,v]));};"
        "c.decryptStr=function(v){return __legado_host('crypto.decryptStr',[c.transformation,c.key,c.iv,v]);};"
        "c.encrypt=function(v){return __legado_wrap_value(__legado_host('crypto.encrypt',[c.transformation,c.key,c.iv,v]));};"
        "c.encryptBase64=function(v){return __legado_host('crypto.encryptBase64',[c.transformation,c.key,c.iv,v]);};"
        "c.encryptHex=function(v){return __legado_host('crypto.encryptHex',[c.transformation,c.key,c.iv,v]);};return c;},"
    "createAsymmetricCrypto:function(t){var c={transformation:String(t||''),publicKey:null,privateKey:null};"
        "c.setPublicKey=function(v){c.publicKey=v;return c;};"
        "c.setPrivateKey=function(v){c.privateKey=v;return c;};"
        "c.decrypt=function(v,p){return __legado_wrap_value(__legado_host('crypto.asym.decrypt',[c.transformation,c.publicKey,c.privateKey,v,p===undefined?true:!!p]));};"
        "c.decryptStr=function(v,p){return __legado_host('crypto.asym.decryptStr',[c.transformation,c.publicKey,c.privateKey,v,p===undefined?true:!!p]);};"
        "c.encrypt=function(v,p){return __legado_wrap_value(__legado_host('crypto.asym.encrypt',[c.transformation,c.publicKey,c.privateKey,v,p===undefined?true:!!p]));};"
        "c.encryptBase64=function(v,p){return __legado_host('crypto.asym.encryptBase64',[c.transformation,c.publicKey,c.privateKey,v,p===undefined?true:!!p]);};"
        "c.encryptHex=function(v,p){return __legado_host('crypto.asym.encryptHex',[c.transformation,c.publicKey,c.privateKey,v,p===undefined?true:!!p]);};return c;},"
    "createSign:function(a){var c={algorithm:String(a||''),publicKey:null,privateKey:null};"
        "c.setPublicKey=function(v){c.publicKey=v;return c;};"
        "c.setPrivateKey=function(v){c.privateKey=v;return c;};"
        "c.sign=function(v){return __legado_wrap_value(__legado_host('crypto.sign',[c.algorithm,c.publicKey,c.privateKey,v]));};"
        "c.signHex=function(v){return __legado_host('crypto.signHex',[c.algorithm,c.publicKey,c.privateKey,v]);};return c;},"
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
    "webView:function(h,u,s){return __legado_host('webView',[h===undefined?null:h,u===undefined?null:u,s===undefined?null:s]);},"
    "webViewGetOverrideUrl:function(h,u,s,r){return __legado_host('webViewOverride',[h===undefined?null:h,u===undefined?null:u,s===undefined?null:s,r===undefined?'':String(r)]);},"
    "webViewGetSource:function(h,u,s,r){return __legado_host('webViewSource',[h===undefined?null:h,u===undefined?null:u,s===undefined?null:s,r===undefined?'':String(r)]);},"
    "startBrowserAwait:function(u,t,r,h){"
        "var response=__legado_host('startBrowserAwait',["
            "String(u===undefined?'':u),"
            "t===undefined?'':String(t),"
            "r===undefined?true:!!r,"
            "h===undefined?null:String(h)"
        "]);"
        "return __legado_wrap_response(response,u);"
    "}"
    "};"
    "java.key=String(__ctx.key===undefined?'':__ctx.key);"
    "java.lang=__legado_java.lang;"
    "java.util=__legado_java.util;"
    "java.net=__legado_java.net;"
    "java.io=__legado_java.io;\n"
    /* Rhino makes the most frequently used extensions available as global
     * names as well as java.* members.  Keep both spellings; this is
     * especially important for older community sources. */
    "globalThis.ajax=java.ajax;"
    "globalThis.ajaxAll=java.ajaxAll;"
    "globalThis.ajaxTestAll=java.ajaxTestAll;"
    "globalThis.base64Encode=java.base64Encode;"
    "globalThis.base64Decode=java.base64Decode;"
    "globalThis.base64DecodeToByteArray=java.base64DecodeToByteArray;"
    "globalThis.strToBytes=java.strToBytes;"
    "globalThis.bytesToStr=java.bytesToStr;"
    "globalThis.hexDecodeToString=java.hexDecodeToString;"
    "globalThis.hexDecodeToByteArray=java.hexDecodeToByteArray;"
    "globalThis.hexEncodeToString=java.hexEncodeToString;"
    "globalThis.md5Encode=java.md5Encode;"
    "globalThis.md5Encode16=java.md5Encode16;"
    "globalThis.createSymmetricCrypto=java.createSymmetricCrypto;"
    "globalThis.createAsymmetricCrypto=java.createAsymmetricCrypto;"
    "globalThis.createSign=java.createSign;"
    "globalThis.digestHex=java.digestHex;"
    "globalThis.digestBase64Str=java.digestBase64Str;"
    "globalThis.HMacHex=java.HMacHex;"
    "globalThis.HMacBase64=java.HMacBase64;"
    "globalThis.getString=java.getString;"
    "globalThis.getStringList=java.getStringList;"
    "globalThis.getElement=java.getElement;"
    "globalThis.getElements=java.getElements;"
    "globalThis.getHeaderMap=java.getHeaderMap;"
    "globalThis.getSource=java.getSource;"
    "globalThis.getTag=java.getTag;"
    "globalThis.setContent=java.setContent;"
    "globalThis.post=java.post;"
    "globalThis.head=java.head;"
    "globalThis.connect=java.connect;"
    "globalThis.startBrowser=java.startBrowser;"
    "globalThis.startBrowserAwait=java.startBrowserAwait;"
    "globalThis.startBrowserDp=java.startBrowserDp;"
    "globalThis.showBrowser=java.showBrowser;"
    "globalThis.showReadingBrowser=java.showReadingBrowser;"
    "globalThis.webView=java.webView;"
    "globalThis.getWebViewUA=java.getWebViewUA;"
    "globalThis.timeFormat=java.timeFormat;"
    "globalThis.timeFormatUTC=java.timeFormatUTC;"
    "globalThis.randomUUID=java.randomUUID;"
    "globalThis.htmlFormat=java.htmlFormat;"
    "globalThis.toNumChapter=java.toNumChapter;"
    "globalThis.getVerificationCode=java.getVerificationCode;"
    "globalThis.importScript=java.importScript;"
    "globalThis.cacheFile=java.cacheFile;"
    "globalThis.downloadFile=java.downloadFile;"
    "globalThis.getFile=java.getFile;"
    "globalThis.readFile=java.readFile;"
    "globalThis.readTxtFile=java.readTxtFile;"
    "globalThis.deleteFile=java.deleteFile;"
    "globalThis.unArchiveFile=java.unArchiveFile;"
    "globalThis.unzipFile=java.unzipFile;"
    "globalThis.unrarFile=java.unrarFile;"
    "globalThis.un7zFile=java.un7zFile;"
    "globalThis.getTxtInFolder=java.getTxtInFolder;"
    "globalThis.getZipStringContent=java.getZipStringContent;"
    "globalThis.getRarStringContent=java.getRarStringContent;"
    "globalThis.get7zStringContent=java.get7zStringContent;"
    "globalThis.getZipByteArrayContent=java.getZipByteArrayContent;"
    "globalThis.getRarByteArrayContent=java.getRarByteArrayContent;"
    "globalThis.get7zByteArrayContent=java.get7zByteArrayContent;"
    "globalThis.openUrl=java.openUrl;"
    "globalThis.getStrResponse=java.getStrResponse;"
    "globalThis.getResponse=java.getResponse;"
    "globalThis.reGetBook=java.reGetBook;"
    "globalThis.refreshTocUrl=java.refreshTocUrl;"
    "globalThis.console={log:function(v){return java.log(v);},error:function(v){return java.log(v);},warn:function(v){return java.log(v);}};"
    "globalThis.cookie={"
    "getCookie:function(u){return __legado_host('cookie.get',[String(u===undefined?'':u)]);},"
    "setCookie:function(u,v){return __legado_host('cookie.set',[String(u),String(v)]);},"
    "removeCookie:function(u){return __legado_host('cookie.remove',[String(u)]);},"
    "replaceCookie:function(u,v){return __legado_host('cookie.replace',[String(u),String(v)]);},"
    "getKey:function(u,k){return __legado_host('cookie.key',[String(u),String(k)]);},"
    "length:function(u){return String(cookie.getCookie(u)||'').split(';').filter(function(v){return v.trim()!=='';}).length;}"
    "};\n"
    "function ajax(u,o){return java.ajax(u,o);}"
    "function getCookie(u,k){return cookie.getCookie(u,k);}"
    "function setCookie(u,v){return cookie.setCookie(u,v);}"
    "function removeCookie(u){return cookie.removeCookie(u);}"
    "function getVariable(k){return java.getVariable(k);}"
    "function setVariable(k,v){return java.setVariable(k,v);}"
    "function put(k,v){return java.put(k,v);}"
    "function get(k,h,t){return java.get(k,h,t);}"
    "function putMemory(k,v){return java.putMemory(k,v);}"
    "function getFromMemory(k){return java.getFromMemory(k);}"
    "globalThis.cache={"
        "get:function(k){return __legado_host('cache.get',[String(k)]);},"
        "put:function(k,v,t){return __legado_host('cache.put',[String(k),v,t===undefined?0:t]);},"
        "delete:function(k){return __legado_host('cache.delete',[String(k)]);},"
        "remove:function(k){return __legado_host('cache.delete',[String(k)]);},"
        "getFile:function(k){return __legado_host('cache.getFile',[String(k)]);},"
        "putFile:function(k,v,t){return __legado_host('cache.putFile',[String(k),v,t===undefined?0:t]);},"
        "deleteFile:function(k){return __legado_host('cache.deleteFile',[String(k)]);},"
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
    "function URL(value,base){return __legado_url(value,base);}"
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
