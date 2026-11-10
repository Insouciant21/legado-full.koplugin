-- Host-side smoke test for the WebDAV propfind parser and URL helpers.
--
-- webdav.lua normally runs inside KOReader, where datastorage, LuaSocket and
-- rapidjson are available.  The stubs below stand in for those dependencies
-- and serve one canned 207 listing, so the parsing and URL code can be
-- exercised with a plain Lua interpreter:
--
--   luajit tools/test-webdav-parse.lua
--
-- Run from the repository root.

package.path = "plugin/legado.koplugin/?.lua;" .. package.path

local canned_listing_body = table.concat({
    '<?xml version="1.0"?>',
    '<d:multistatus xmlns:d="DAV:">',
    '<d:response>',
    '  <d:href>/remote.php/webdav/backup/</d:href>',
    '  <d:propstat>',
    '    <d:prop>',
    '      <d:displayname>backup</d:displayname>',
    '      <d:resourcetype><d:collection/></d:resourcetype>',
    '    </d:prop>',
    '    <d:status>HTTP/1.1 200 OK</d:status>',
    '  </d:propstat>',
    '</d:response>',
    '<d:response>',
    '  <d:href>/remote.php/webdav/backup/%E4%B8%89%E5%9B%BD%E6%BC%94%E4%B9%89/</d:href>',
    '  <d:propstat>',
    '    <d:prop>',
    '      <d:displayname>&#x4E09;&#22269;&#x6F14;&#20041;</d:displayname>',
    '      <d:resourcetype><d:collection/></d:resourcetype>',
    '    </d:prop>',
    '    <d:status>HTTP/1.1 200 OK</d:status>',
    '  </d:propstat>',
    '</d:response>',
    '<d:response>',
    '  <d:href>/remote.php/webdav/backup/legado%20backup%202024.zip</d:href>',
    '  <d:propstat>',
    '    <d:prop>',
    '      <d:getcontentlength>1048576</d:getcontentlength>',
    '      <d:resourcetype/>',
    '    </d:prop>',
    '    <d:status>HTTP/1.1 200 OK</d:status>',
    '  </d:propstat>',
    '</d:response>',
    '</d:multistatus>',
}, "\n")

local function http_stub()
    return {
        TIMEOUT = nil,
        request = function(request_table)
            -- Pump the canned listing through the caller's sink, mirroring
            -- how LuaSocket delivers the body, then report a 207.
            if type(request_table.sink) == "function" then
                request_table.sink(canned_listing_body)
                request_table.sink(nil)
            end
            return true, 207, {}, "207 Multi-Status"
        end,
    }
end

package.preload["gettext"] = function()
    return function(value) return value end
end
package.preload["datastorage"] = function()
    return { getDataDir = function() return "/tmp" end }
end
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function() return nil end,
        mkdir = function() return nil end,
        chmod = function() end,
        rmdir = function() end,
    }
end
package.preload["socket"] = function()
    return { sleep = function() end }
end
package.preload["socket.http"] = http_stub
package.preload["ssl.https"] = http_stub
package.preload["ltn12"] = function()
    return {
        sink = {
            -- Capture the caller's chunks table, like the real sink.table.
            table = function(target)
                return function(chunk)
                    if chunk == nil then return true end
                    target[#target + 1] = chunk
                    return true
                end
            end,
            file = function() return function() end end,
        },
        source = { string = function() return function() end end },
    }
end
package.preload["util"] = function()
    return { makePath = function() end }
end
package.preload["rapidjson"] = function()
    return {
        encode = function() return "{}" end,
        decode = function() return nil end,
        array = function() return {} end,
    }
end
package.preload["legado/network"] = function()
    return {
        absolute = function(base, value)
            value = tostring(value)
            if value:match("^%w+://") then return value end
            local origin = tostring(base):match("^%w+://[^/]+")
            if origin and value:sub(1, 1) == "/" then return origin .. value end
            return tostring(base) .. value
        end,
        user_agent = function() return "legado-webdav-test" end,
    }
end

local Webdav = require("legado/webdav")

local checks = {}
local failures = 0

local function check(name, condition)
    checks[#checks + 1] = name
    if not condition then
        failures = failures + 1
        print("FAIL " .. name)
    end
end

-- Parser: d: prefix, collection detection, percent- and entity-encoded names.
local entries = Webdav.parse_propfind(canned_listing_body)
check("parser: entry count", #entries == 3)
check("parser: root is collection", entries[1] and entries[1].collection == true)
check("parser: root displayname", entries[1] and entries[1].displayname == "backup")
check("parser: directory displayname decoded", entries[2] and entries[2].displayname == "三国演义")
check("parser: file is not collection", entries[3] and entries[3].collection == false)
check("parser: content length", entries[3] and entries[3].content_length == 1048576)

-- list_directory: canned transport, self entry dropped, dirs sorted first.
local items = Webdav.list_directory({ url = "https://example.com/remote.php/webdav/" },
    "https://example.com/remote.php/webdav/backup/")
check("list: entry count", #items == 2)
check("list: directory first", items[1] and items[1].is_dir == true)
check("list: directory name", items[1] and items[1].name == "三国演义")
check("list: percent-decoded file name",
    items[2] and items[2].name == "legado backup 2024.zip")
check("list: file size", items[2] and items[2].size == 1048576)
check("list: absolute child url",
    items[1] and items[1].url
        == "https://example.com/remote.php/webdav/backup/%E4%B8%89%E5%9B%BD%E6%BC%94%E4%B9%89/")

-- Uppercase prefix (Apache mod_dav style), responsedescription noise that
-- must not be mistaken for a block boundary, and an entity-encoded href.
local apache_body = table.concat({
    '<?xml version="1.0" encoding="utf-8"?>',
    '<D:multistatus xmlns:D="DAV:">',
    '<D:response>',
    '  <D:href>/dav/</D:href>',
    '  <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>'
        .. '<D:status>HTTP/1.1 200 OK</D:status>',
    '  <D:responsedescription>fine</D:responsedescription>',
    '</D:response>',
    '<D:response>',
    '  <D:href>/dav/A&amp;B.zip</D:href>',
    '  <D:propstat><D:prop><D:getcontentlength>2048</D:getcontentlength></D:prop>'
        .. '<D:status>HTTP/1.1 200 OK</D:status>',
    '</D:response>',
    '</D:multistatus>',
}, "\n")

local apache_entries = Webdav.parse_propfind(apache_body)
check("apache: entry count", #apache_entries == 2)
check("apache: entity-decoded href",
    apache_entries[2] and apache_entries[2].href == "/dav/A&B.zip")
check("apache: file entry parsed",
    apache_entries[2] and apache_entries[2].content_length == 2048)

-- Unprefixed tags.
local unprefixed_body = table.concat({
    '<?xml version="1.0"?>',
    '<multistatus xmlns="DAV:">',
    '<response>',
    '  <href>/dav/only.zip</href>',
    '  <propstat><prop><getcontentlength>10</getcontentlength></prop>'
        .. '<status>HTTP/1.1 200 OK</status></propstat>',
    '</response>',
    '</multistatus>',
}, "\n")

local unprefixed_entries = Webdav.parse_propfind(unprefixed_body)
check("unprefixed: entry count", #unprefixed_entries == 1)
check("unprefixed: href", unprefixed_entries[1] and unprefixed_entries[1].href == "/dav/only.zip")

-- Degenerate inputs must return empty tables, not errors.
check("empty body", #Webdav.parse_propfind("") == 0)
check("nil body", #Webdav.parse_propfind(nil) == 0)
check("garbage body", #Webdav.parse_propfind("this is not xml") == 0)

-- URL helpers.
check("normalize: appends trailing slash",
    Webdav.normalize_directory_url("https://dav.jianguoyun.com/dav")
        == "https://dav.jianguoyun.com/dav/")
check("normalize: rejects empty",
    Webdav.normalize_directory_url("  ") == nil)
check("normalize: rejects non-http scheme",
    Webdav.normalize_directory_url("ftp://example.com/") == nil)
check("parent: descends to root",
    Webdav.parent_url("https://dav.jianguoyun.com/dav/backup/")
        == "https://dav.jianguoyun.com/dav/")
check("parent: root has no parent",
    Webdav.parent_url("https://dav.jianguoyun.com/dav/") == nil)
check("parent: strips query",
    Webdav.parent_url("https://example.com/dav/folder?token=x")
        == "https://example.com/dav/")

print(string.format("%d checks, %d failures", #checks, failures))
if failures > 0 then
    os.exit(1)
end
print("all passed")
