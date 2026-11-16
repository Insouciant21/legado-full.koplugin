-- LAN discovery for the paired Legado server.
-- UDP keeps the Kindle dependency surface to LuaSocket and avoids relying on
-- an mDNS resolver that is not consistently available in KOReader packages.
local Discovery = {}

local PROBE_PREFIX = "LEGADO_DISCOVERY_V1"
local DEFAULT_PORT = 47832
local DEFAULT_MULTICAST = "239.255.42.99"
local DEFAULT_MAX_SWEEP_HOSTS = 510

local function identifier(value)
    return type(value) == "string" and #value > 0 and #value <= 128
        and not value:find("[%z\1-\31\127]")
end

local function integer(value)
    return type(value) == "number" and value >= 1 and value <= 65535
        and value == math.floor(value)
end

local function string_value(value)
    return type(value) == "string" and value:match("^%s*(.-)%s*$") or ""
end

local function normalize_host(value)
    value = string_value(value)
    value = value:gsub("^::ffff:", "")
    if value == "" or value:find("[^%x%.:%-]") then return nil end
    if value:find(":", 1, true) and value:sub(1, 1) ~= "[" then value = "[" .. value .. "]" end
    return value
end

local function server_url(transport, host, port)
    if transport == "https" then
        return "https://" .. host .. (port == 443 and "" or ":" .. tostring(port))
    end
    if transport ~= "http" then return nil end
    return "http://" .. host .. (port == 80 and "" or ":" .. tostring(port))
end

local function supports_kindle(message)
    if type(message.capabilities) ~= "table" then return false end
    for capability_index, capability in ipairs(message.capabilities) do
        if capability == "kindle-sync-v1" then return true end
    end
    return false
end

local function ipv4_number(first, second, third, fourth)
    return ((first * 256 + second) * 256 + third) * 256 + fourth
end

local function ipv4_octets(value)
    if type(value) ~= "number" or value < 0 or value > 4294967295
        or value ~= math.floor(value) then return nil end
    local fourth = value % 256
    value = math.floor(value / 256)
    local third = value % 256
    value = math.floor(value / 256)
    local second = value % 256
    local first = math.floor(value / 256)
    return first, second, third, fourth
end

local function ipv4_text(value)
    local first, second, third, fourth = ipv4_octets(value)
    if not first then return nil end
    return string.format("%d.%d.%d.%d", first, second, third, fourth)
end

local function private_ipv4(value)
    local first, second = ipv4_octets(value)
    if not first then return false end
    return first == 10
        or (first == 172 and second >= 16 and second <= 31)
        or (first == 192 and second == 168)
        or (first == 169 and second == 254)
        or first == 127
end

-- Linux /proc/net/route prints IPv4 addresses in host-endian hex groups.
local function route_ipv4(value)
    if type(value) ~= "string" or #value ~= 8 or not value:match("^%x+$") then return nil end
    local first = tonumber(value:sub(7, 8), 16)
    local second = tonumber(value:sub(5, 6), 16)
    local third = tonumber(value:sub(3, 4), 16)
    local fourth = tonumber(value:sub(1, 2), 16)
    return ipv4_number(first, second, third, fourth)
end

local function prefix_length(mask)
    local first, second, third, fourth = ipv4_octets(mask)
    if not first then return nil end
    local prefix, saw_zero = 0, false
    for octet_index, octet in ipairs({ first, second, third, fourth }) do
        for bit_index = 7, 0, -1 do
            local bit = 2 ^ bit_index
            local set = octet >= bit
            if set then
                if saw_zero then return nil end
                octet = octet - bit
                prefix = prefix + 1
            elseif octet_index < 4 or bit_index > 0 then
                saw_zero = true
            end
        end
    end
    return prefix
end

local function read_private_routes(path)
    if type(path) ~= "string" or path == "" then return {} end
    local file = io.open(path, "rb")
    if not file then return {} end
    local routes = {}
    for line in file:lines() do
        local fields = {}
        for field in line:gmatch("%S+") do fields[#fields + 1] = field end
        if #fields >= 8 and fields[2] ~= "Destination" then
            local destination = route_ipv4(fields[2])
            local gateway = route_ipv4(fields[3])
            local mask = route_ipv4(fields[8])
            local prefix = mask and prefix_length(mask)
            if destination and gateway and prefix and prefix >= 8 and prefix < 32
                and private_ipv4(destination) then
                routes[#routes + 1] = {
                    destination = destination,
                    gateway = gateway,
                    prefix = prefix,
                }
            end
        end
    end
    file:close()
    return routes
end

local function bound_address(socket_module, target, port)
    local udp = socket_module.udp()
    if not udp then return nil end
    local connected = udp:connect(target, port)
    if not connected then udp:close(); return nil end
    local address = udp:getsockname()
    udp:close()
    return type(address) == "string" and address or nil
end

-- Some Wi-Fi access points drop broadcast and multicast between clients even
-- though unicast works. Sweep only small connected private IPv4 subnets and
-- keep a /24 window when a larger private subnet is configured.
local function add_subnet_targets(add_target, socket_module, route_path, port, maximum)
    maximum = tonumber(maximum) or DEFAULT_MAX_SWEEP_HOSTS
    maximum = math.max(1, math.min(1022, math.floor(maximum)))
    local swept = 0
    for route_index, route in ipairs(read_private_routes(route_path)) do
        local size = 2 ^ (32 - route.prefix)
        local first = route.destination + 1
        local last = route.destination + size - 2
        if size - 2 > maximum then
            local local_address = bound_address(socket_module, ipv4_text(route.gateway), port)
            local first_octet, second_octet, third_octet, fourth_octet =
                local_address and local_address:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
            if first_octet then
                local local_ip = ipv4_number(
                    tonumber(first_octet),
                    tonumber(second_octet),
                    tonumber(third_octet),
                    tonumber(fourth_octet)
                )
                local window = math.floor(local_ip / 256) * 256
                first = math.max(route.destination + 1, window + 1)
                last = math.min(route.destination + size - 2, window + 254)
            else
                first, last = 1, 0
            end
        end
        for value = first, last do
            if swept >= maximum then return end
            add_target(ipv4_text(value))
            swept = swept + 1
        end
    end
end

local function load_module(value, default_name)
    if type(value) == "table" then return true, value end
    return pcall(require, value or default_name)
end

local function decode_announcement(json, payload, probe, address)
    local decoded, message = pcall(json.decode, payload)
    if not decoded or type(message) ~= "table" then return nil end
    if message.protocol_version ~= 1 or message.type ~= "legado-server"
        or message.probe ~= probe or not identifier(message.server_id)
        or not integer(message.http_port) or not supports_kindle(message) then
        return nil
    end
    local server_name = string_value(message.server_name)
    if server_name == "" or #server_name > 100 then return nil end
    local transport = message.transport == nil and "http" or string_value(message.transport)
    local host = normalize_host(address)
    local base_url = host and server_url(transport, host, message.http_port)
    if not base_url then return nil end
    return {
        protocol_version = 1,
        server_id = message.server_id,
        server_name = server_name,
        transport = transport,
        http_port = message.http_port,
        discovery_port = integer(message.discovery_port) and message.discovery_port or DEFAULT_PORT,
        address = host,
        server_url = base_url,
    }
end

function Discovery.scan(options)
    options = options or {}
    local loaded_socket, socket_module = load_module(options.socket_module, "socket")
    if not loaded_socket or type(socket_module) ~= "table" then
        return nil, "LuaSocket is unavailable"
    end
    local loaded_json, json = load_module(options.json_module, "rapidjson")
    if not loaded_json or type(json) ~= "table" or type(json.decode) ~= "function" then
        return nil, "rapidjson is unavailable"
    end

    local udp, socket_err = socket_module.udp()
    if not udp then return nil, tostring(socket_err or "cannot create discovery socket") end
    local bound = udp:setsockname("*", 0)
    if not bound then udp:close(); return nil, "cannot bind discovery socket" end
    udp:settimeout(0)
    pcall(udp.setoption, udp, "broadcast", true)
    pcall(udp.setoption, udp, "reuseaddr", true)
    pcall(udp.setoption, udp, "multicast_ttl", 1)

    local port = integer(options.port) and options.port or DEFAULT_PORT
    local multicast = string_value(options.multicast or DEFAULT_MULTICAST)
    local nonce = string.format("%x%x", os.time(), math.floor((socket_module.gettime() % 1) * 1000000000))
    local probe = PROBE_PREFIX .. "|" .. nonce
    local targets, target_set = {}, {}
    local function add_target(target)
        target = string_value(target)
        if target ~= "" and not target_set[target] then
            target_set[target] = true
            targets[#targets + 1] = target
        end
    end
    if type(options.targets) == "table" then
        for target_index, target in ipairs(options.targets) do add_target(target) end
    else
        add_target("255.255.255.255")
        add_target(multicast)
        add_target("127.0.0.1")
        if options.sweep ~= false then
            add_subnet_targets(
                add_target,
                socket_module,
                options.route_path or "/proc/net/route",
                port,
                options.max_sweep_hosts
            )
        end
    end
    local sent_count = 0
    local last_send_error
    for target_index, target in ipairs(targets) do
        local sent, send_err = udp:sendto(probe, target, port)
        if sent then sent_count = sent_count + 1 else last_send_error = send_err end
    end
    if sent_count == 0 then
        udp:close()
        return nil, "cannot send discovery probe: " .. tostring(last_send_error or "unknown error")
    end

    local timeout = tonumber(options.timeout) or 2.5
    if timeout < 0.1 then timeout = 0.1 end
    if timeout > 10 then timeout = 10 end
    local deadline = socket_module.gettime() + timeout
    local by_id, servers = {}, json.array and json.array() or {}
    while socket_module.gettime() < deadline do
        local remaining = deadline - socket_module.gettime()
        udp:settimeout(math.max(0.05, math.min(0.2, remaining)))
        local payload, address = udp:receivefrom()
        if payload then
            local server = decode_announcement(json, payload, nonce, address)
            if server and not by_id[server.server_id] then
                by_id[server.server_id] = true
                servers[#servers + 1] = server
            end
        end
    end
    udp:close()
    table.sort(servers, function(left, right)
        if left.server_name == right.server_name then return left.server_id < right.server_id end
        return left.server_name < right.server_name
    end)
    return servers
end

function Discovery.find_server(server_id, options)
    if not identifier(server_id) then return nil, "invalid server id" end
    options = options or {}
    options.server_id = server_id
    local servers, err = Discovery.scan(options)
    if not servers then return nil, err end
    for server_index, server in ipairs(servers) do
        if server.server_id == server_id then return server end
    end
    return nil
end

return Discovery
