-- Local HTTPS trust checks. LuaSec verifies the X.509 chain; this module
-- performs the RFC 2818 hostname check that stock LuaSec does not provide.
local TLS = {}

local function normalized_host(value)
    if type(value) ~= "string" then return nil end
    value = value:lower():gsub("%.$", "")
    if value == "" or value:find("[%z\1-\31\127/%?#%@\\]") then return nil end
    return value
end

local function ip_address(value)
    if value:find(":", 1, true) then return true end
    local a, b, c, d = value:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then return false end
    return tonumber(a) <= 255 and tonumber(b) <= 255 and tonumber(c) <= 255 and tonumber(d) <= 255
end

local function dns_match(candidate, hostname)
    if not candidate or candidate == "" or candidate:find("[%z\1-\31\127/]") then return false end
    candidate = candidate:lower():gsub("%.$", "")
    if ip_address(hostname) or ip_address(candidate) then return false end
    if candidate == hostname then return true end
    local suffix = candidate:match("^%*%.([^.]+%..+)$")
    if not suffix then return false end
    local hostname_suffix = hostname:match("^[^.]+%.(.+)$")
    return hostname_suffix == suffix and hostname:find("%*", 1, true) == nil
end

function TLS.certificate_matches_hostname(certificate, hostname)
    hostname = normalized_host(hostname)
    if type(certificate) ~= "table" and type(certificate) ~= "userdata" then return false, "peer certificate is unavailable" end
    if not hostname then return false, "invalid HTTPS hostname" end

    local called, extensions = pcall(certificate.extensions, certificate)
    if called and type(extensions) == "table" then
        local saw_san = false
        for key, extension in pairs(extensions) do
            if type(extension) == "table" and (key == "2.5.29.17" or extension.name == "subjectAltName") then
                saw_san = true
                for san_index, name in ipairs(extension.iPAddress or {}) do
                    if normalized_host(tostring(name)) == hostname then return true end
                end
                for san_index, name in ipairs(extension.dNSName or {}) do
                    if dns_match(tostring(name), hostname) then return true end
                end
            end
        end
        if saw_san then return false, "certificate subjectAltName does not match HTTPS hostname" end
    elseif called == false and certificate.extensions then
        return false, "cannot read certificate subjectAltName"
    end

    -- Legacy no-SAN certificates may use one exact CN. A present SAN disables
    -- this fallback, as required for modern HTTPS identity checks.
    if ip_address(hostname) then return false, "certificate has no IP address SAN" end
    local ok_subject, subject = pcall(certificate.subject, certificate)
    if not ok_subject or type(subject) ~= "table" then return false, "cannot read certificate subject" end
    for subject_index, entry in ipairs(subject) do
        if type(entry) == "table" and entry.name == "commonName" then
            if dns_match(tostring(entry.value), hostname) then return true end
        end
    end
    return false, "certificate commonName does not match HTTPS hostname"
end

function TLS.authority(url)
    if type(url) ~= "string" then return nil, "invalid HTTPS URL" end
    local authority = url:match("^https://([^/?#]*)")
    if not authority or authority == "" then return nil, "invalid HTTPS host" end
    if authority:find("@", 1, true) then return nil, "invalid HTTPS host" end
    local host, port
    if authority:sub(1, 1) == "[" then
        host, port = authority:match("^%[([0-9A-Fa-f:]+)%]:(%d+)$")
        if not host then host = authority:match("^%[([0-9A-Fa-f:]+)%]$") end
        if not host then return nil, "invalid HTTPS host" end
    else
        host, port = authority:match("^([^:]+):(%d+)$")
        if not host then host = authority:match("^([^:]+)$") end
        if not host or host == "" or host:find("[%z\1-\31\127/%@\\%[%]]") then return nil, "invalid HTTPS host" end
    end
    if not host or host == "" then return nil, "invalid HTTPS host" end
    port = tonumber(port) or 443
    if not port or port < 1 or port > 65535 or math.floor(port) ~= port then return nil, "invalid HTTPS port" end
    return host, port
end

function TLS.connect(url, options)
    options = options or {}
    local host, port = TLS.authority(url)
    if not host then return nil, port end
    local normalized = normalized_host(host)
    if not normalized then return nil, "invalid HTTPS host" end
    local socket = require("socket")
    local ssl = require("ssl")
    local tcp = socket.tcp()
    if not tcp then return nil, "cannot create HTTPS socket" end
    local timeout = options.timeout or 30
    tcp:settimeout(timeout)
    local connected, connect_err = tcp:connect(host, port)
    if not connected then tcp:close(); return nil, "HTTPS connection failed: " .. tostring(connect_err) end

    local parameters = {
        mode = "client", protocol = "any", options = "all", verify = "peer",
        cafile = options.cafile, depth = options.depth or 10,
    }
    local connection, wrap_err = ssl.wrap(tcp, parameters)
    if not connection then tcp:close(); return nil, "cannot initialize HTTPS: " .. tostring(wrap_err) end
    if type(connection.sni) == "function" then
        local called, named, sni_err = pcall(connection.sni, connection, host)
        if not called then connection:close(); return nil, "cannot set HTTPS SNI: " .. tostring(named) end
        if named == false then connection:close(); return nil, "cannot set HTTPS SNI: " .. tostring(sni_err) end
    else
        connection:close(); return nil, "HTTPS SNI is unavailable"
    end
    connection:settimeout(timeout)
    local shaken, handshake_err = connection:dohandshake()
    if not shaken then connection:close(); return nil, "HTTPS handshake failed: " .. tostring(handshake_err) end

    if type(connection.getpeerverification) == "function" then
        local verified, errors = connection:getpeerverification()
        if not verified then connection:close(); return nil, "HTTPS certificate chain is untrusted" end
    else
        connection:close(); return nil, "HTTPS chain verification is unavailable"
    end
    if type(connection.getpeercertificate) ~= "function" then
        connection:close(); return nil, "HTTPS peer certificate is unavailable"
    end
    local certificate = connection:getpeercertificate()
    local matched, match_err = TLS.certificate_matches_hostname(certificate, host)
    if not matched then connection:close(); return nil, match_err or "HTTPS hostname verification failed" end
    return connection
end

function TLS.lazy_connect(url, options)
    local host, port = TLS.authority(url)
    if not host then return nil, port end
    local normalized = normalized_host(host)
    if not normalized then return nil, "invalid HTTPS host" end
    local effective_options = options or {}
    local connection
    local authorized = false
    return {
        settimeout = function(_, timeout)
            local requested = timeout or effective_options.timeout or 30
            if connection then return connection:settimeout(requested) end
            effective_options = { cafile = effective_options.cafile, depth = effective_options.depth, timeout = requested }
            return true
        end,
        connect = function()
            if connection then return nil, "HTTPS connection already established" end
            local connected, connect_err = TLS.connect(url, effective_options)
            if not connected then return nil, connect_err end
            connection = connected
            authorized = true
            return connection
        end,
        send = function(_, data, first, last)
            if not connection then return nil, "HTTPS connection is not established" end
            if not authorized then return nil, "HTTPS connection is not verified" end
            return connection:send(data, first, last)
        end,
        receive = function(_, pattern, prefix)
            if not connection then return nil, "HTTPS connection is not established" end
            return connection:receive(pattern, prefix)
        end,
        close = function()
            if connection then connection:close(); connection = nil; return true end
            return true
        end,
    }
end

return TLS
