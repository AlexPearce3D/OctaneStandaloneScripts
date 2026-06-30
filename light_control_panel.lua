-- Octane Standalone Light Control Panel
--
-- Run this from Octane's Lua script editor while a project is open.
-- It scans the current scene graph for nodes with a "power" pin and creates
-- a small floating window with per-light sliders plus global off/reset controls.

local SCRIPT_VERSION = "v0.1.23"
local MAX_LIGHTS_IN_WINDOW = 500
local ROW_PANEL_HEIGHT = 520
local COMPACT_CONTROL_HEIGHT = 18
local POWER_SLIDER_MAX = 100000.0
local LIGHT_PASS_ID_MAX = 100
local SLIDER_STEP = 0.01
local FILE_BACKUP_EXT = ".lightpanel.bak"

local SCENE_LINES = nil
local SCENE_PATH = nil
local SCENE_BACKED_UP = false
local SCENE_NODE_SPANS = nil

local function call_method(obj, name, ...)
    if not obj then
        return false, nil
    end
    local fn = obj[name]
    if type(fn) ~= "function" then
        return false, nil
    end
    return pcall(fn, obj, ...)
end

local function first_number(v)
    if v == nil then
        return nil
    end
    if type(v) == "number" then
        return v
    end
    local s = tostring(v)
    local tok = s:match("([%+%-]?%d+%.?%d*)")
    if not tok then
        return nil
    end
    return tonumber(tok)
end

local function has_pin(node, pin_name)
    local ok, v = call_method(node, "hasPin", pin_name)
    return ok and v == true
end

local function get_pin_value(node, pin_name)
    local ok, v = call_method(node, "getPinValue", pin_name)
    if ok then
        return v
    end
    return nil
end

local function get_pin_number(node, pin_name)
    local v = get_pin_value(node, pin_name)
    if v ~= nil then
        return first_number(v)
    end
    return nil
end

local function set_pin_number(node, pin_name, value)
    local ok, err = call_method(node, "setPinValue", pin_name, value)
    if not ok then
        print("Could not set " .. tostring(pin_name) .. ": " .. tostring(err))
    end
    return ok
end

local function node_info(node)
    local ok, info = call_method(node, "getNodeInfo")
    if ok and type(info) == "table" then
        return info
    end
    return {}
end

local function node_name(node)
    local info = node_info(node)
    return info.name or info.nodeName or "<unnamed>"
end

local function node_id(node)
    local info = node_info(node)
    return math.floor(first_number(info.id) or first_number(info.nodeId) or -1)
end

local function node_type(node)
    local info = node_info(node)
    return math.floor(first_number(info.type) or first_number(info.typeId) or -1)
end

local function collect_nodes_via_find(graph)
    local variants = {
        {},
        {"*"},
        {"node"},
    }
    for _, args in ipairs(variants) do
        local ok, ret = call_method(graph, "findNodes", table.unpack(args))
        if ok and type(ret) == "table" and #ret > 0 then
            return ret
        end
    end
    return nil
end

local function collect_nodes_via_owned_items(graph)
    local out = {}
    local seen = {}

    local function visit(item)
        if not item then
            return
        end

        local marker = tostring(item)
        if seen[marker] then
            return
        end
        seen[marker] = true

        local ok_count = call_method(item, "getPinCount")
        if ok_count then
            out[#out + 1] = item
        end

        local ok_items, children = call_method(item, "getOwnedItems")
        if ok_items and type(children) == "table" then
            for _, child in ipairs(children) do
                visit(child)
            end
        end
    end

    visit(graph)
    if #out > 0 then
        return out
    end
    return nil
end

local function collect_all_nodes(graph)
    local nodes = collect_nodes_via_find(graph)
    if nodes and #nodes > 0 then
        return nodes, "findNodes"
    end
    nodes = collect_nodes_via_owned_items(graph)
    if nodes and #nodes > 0 then
        return nodes, "getOwnedItems"
    end
    return nil, nil
end

local function node_owner_graph(node)
    if not node then
        return nil
    end

    local methods = {
        "getOwnerGraph",
        "getParentGraph",
        "getNodeGraph",
        "getGraph",
        "getOwner",
    }

    for _, method in ipairs(methods) do
        local ok, ret = call_method(node, method)
        if ok and ret then
            return ret, method
        end
    end

    return nil, nil
end

local function read_all(path)
    local f, err = io.open(path, "rb")
    if not f then
        return nil, err
    end
    local s = f:read("*a")
    f:close()
    return s
end

local function write_all(path, content)
    local f, err = io.open(path, "wb")
    if not f then
        return false, err
    end
    f:write(content)
    f:close()
    return true
end

local function split_lines(s)
    local lines = {}
    s = (s or ""):gsub("\r\n", "\n")
    if s ~= "" and s:sub(-1) ~= "\n" then
        s = s .. "\n"
    end
    for line in s:gmatch("(.-)\n") do
        lines[#lines + 1] = line
    end
    return lines
end

local function join_lines(lines)
    return table.concat(lines, "\n") .. "\n"
end

local function parse_attrs(tag_text)
    local attrs = {}
    for k, _, v in tag_text:gmatch("([%w_:%-]+)%s*=%s*(['\"])(.-)%2") do
        attrs[k] = v
    end
    return attrs
end

local function push(t, v)
    t[#t + 1] = v
end

local function pop(t)
    local v = t[#t]
    t[#t] = nil
    return v
end

local function top(t)
    return t[#t]
end

local function replace_attr_numeric_line(line, value)
    local open_pos = line:find(">")
    local close_pos = line:find("</attr>")
    if not open_pos or not close_pos or close_pos <= open_pos then
        return line
    end

    local prefix = line:sub(1, open_pos)
    local mid = line:sub(open_pos + 1, close_pos - 1)
    local suffix = line:sub(close_pos)
    local replacement = tostring(value)

    local replaced = false
    mid = mid:gsub("([%+%-]?%d+%.?%d*)", function(old)
        if replaced then
            return old
        end
        replaced = true
        return replacement
    end, 1)

    if not replaced then
        mid = replacement
    end

    return prefix .. mid .. suffix
end

local function call_project_zero_arg(name)
    if not octane or not octane.project then
        return false, nil
    end
    local f = octane.project[name]
    if type(f) ~= "function" then
        return false, nil
    end
    local ok, ret = pcall(f)
    if not ok then
        return false, nil
    end
    return true, ret
end

local function detect_current_scene_path()
    local ok, ret = call_project_zero_arg("getCurrentProject")
    if ok and type(ret) == "string" and ret ~= "" and ret:match("%.ocs$") then
        return ret, "getCurrentProject"
    end

    if not octane or not octane.help or not octane.project then
        return nil, "Octane API modules missing"
    end

    local funcs = octane.help.functions("project") or {}
    for _, fn in ipairs(funcs) do
        local ok2, ret2 = call_project_zero_arg(fn)
        if ok2 and type(ret2) == "string" and ret2 ~= "" and ret2:match("%.ocs$") then
            return ret2, fn
        end
    end

    return nil, "No project function returned an .ocs path"
end

local function ensure_scene_backup()
    if SCENE_BACKED_UP or not SCENE_PATH then
        return true
    end

    local raw, err = read_all(SCENE_PATH)
    if not raw then
        print("Could not create backup: " .. tostring(err))
        return false
    end

    local ok, write_err = write_all(SCENE_PATH .. FILE_BACKUP_EXT, raw)
    if not ok then
        print("Could not write backup: " .. tostring(write_err))
        return false
    end

    SCENE_BACKED_UP = true
    print("Backup written: " .. SCENE_PATH .. FILE_BACKUP_EXT)
    return true
end

local function write_scene_lines()
    if not SCENE_PATH or not SCENE_LINES then
        return false
    end
    if not ensure_scene_backup() then
        return false
    end
    local ok, err = write_all(SCENE_PATH, join_lines(SCENE_LINES))
    if not ok then
        print("Could not write scene: " .. tostring(err))
        return false
    end
    return true
end

local function function_name_matches_render_start(name)
    local low = string.lower(tostring(name or ""))
    if low:find("stop", 1, true) or low:find("pause", 1, true) or low:find("reset", 1, true) then
        return false
    end
    if low == "start" or low == "render" then
        return true
    end
    return low:find("startrender", 1, true)
        or low:find("start_render", 1, true)
        or low:find("startrendering", 1, true)
        or low:find("start_rendering", 1, true)
        or low:find("continuerender", 1, true)
        or low:find("continue_render", 1, true)
        or low:find("resume", 1, true)
        or low:find("restart", 1, true)
        or low:find("activate", 1, true)
        or low:find("evaluate", 1, true)
        or low:find("preview", 1, true)
        or low:find("tonemap", 1, true)
end

local function try_render_start_module(module_name)
    if not octane or type(octane[module_name]) ~= "table" then
        return false
    end

    local module = octane[module_name]
    local names = {
        "start",
        "restart",
        "render",
        "startRender",
        "startRendering",
        "continueRender",
        "resume",
        "activate",
        "evaluate",
        "preview",
    }

    if octane.help and type(octane.help.functions) == "function" then
        local ok, discovered = pcall(octane.help.functions, module_name)
        if ok and type(discovered) == "table" then
            for _, name in ipairs(discovered) do
                if function_name_matches_render_start(name) then
                    names[#names + 1] = name
                end
            end
        end
    end

    local tried = {}
    for _, name in ipairs(names) do
        if not tried[name] and type(module[name]) == "function" then
            tried[name] = true
            local ok, result = pcall(module[name])
            if ok and result ~= false then
                print("Started rendering via octane." .. module_name .. "." .. tostring(name) .. "()")
                return true
            end
            if not ok then
                print("Tried octane." .. module_name .. "." .. tostring(name) .. "() -> " .. tostring(result))
            else
                print("Tried octane." .. module_name .. "." .. tostring(name) .. "() -> returned false")
            end
        end
    end

    return false
end

local function print_module_all_functions(module_name)
    if not octane or not octane.help or type(octane.help.functions) ~= "function" then
        return
    end
    local ok, funcs = pcall(octane.help.functions, module_name)
    if not ok or type(funcs) ~= "table" or #funcs == 0 then
        return
    end
    print("All available octane." .. module_name .. " functions:")
    for _, fn in ipairs(funcs) do
        print("  " .. tostring(fn))
    end
end

local function start_render_after_reload()
    local modules = {
        "render",
        "project",
        "rendertarget",
        "renderTarget",
        "renderTargetNode",
        "rendertargetnode",
        "nodegraph",
        "gui",
    }

    for _, module_name in ipairs(modules) do
        if try_render_start_module(module_name) then
            return true
        end
    end

    print("Could not auto-start rendering after reload.")
    print("If Octane exposes a different render-start API, paste the script output and I will wire that exact call.")
    if octane and octane.help and type(octane.help.functions) == "function" then
        for _, module_name in ipairs(modules) do
            print_module_all_functions(module_name)
        end
    end
    return false
end

local function reload_scene()
    if SCENE_PATH and octane and octane.project and type(octane.project.load) == "function" then
        local ok, result = pcall(octane.project.load, SCENE_PATH)
        if ok and result ~= false then
            print("Reloaded scene: " .. SCENE_PATH)
            start_render_after_reload()
            return true
        end
        print("Scene reload failed; use File > Open to reload:")
        print("  " .. SCENE_PATH)
        return false
    end

    print("octane.project.load() is not available; use File > Open to reload:")
    print("  " .. tostring(SCENE_PATH))
    return false
end

local function get_root_graph()
    if octane and octane.nodegraph and type(octane.nodegraph.getRootGraph) == "function" then
        local ok, graph = pcall(octane.nodegraph.getRootGraph)
        if ok and graph then
            return graph, "octane.nodegraph.getRootGraph"
        end
    end

    if octane and octane.project and type(octane.project.getSceneGraph) == "function" then
        local ok, graph = pcall(octane.project.getSceneGraph)
        if ok and graph then
            return graph, "octane.project.getSceneGraph"
        end
    end

    return nil, "no root scene graph API was available"
end

local function parse_position(text)
    if not text or text == "" then
        return nil
    end
    local x, y = tostring(text):match("^%s*([%+%-]?%d+%.?%d*)%s+([%+%-]?%d+%.?%d*)")
    if not x or not y then
        return nil
    end
    return {
        x = tonumber(x),
        y = tonumber(y),
        raw = tostring(text),
    }
end

local function graph_path_for(graph)
    if not graph then
        return nil
    end

    local parts = {}
    local current = graph
    while current do
        local name = tostring(current.name or "")
        if name ~= "" then
            table.insert(parts, 1, name)
        end
        current = current.parent
    end

    if #parts == 0 then
        return nil
    end
    return table.concat(parts, " / ")
end

local function collect_file_lights()
    if octane and octane.project and type(octane.project.save) == "function" then
        local ok_save, save_err = pcall(octane.project.save)
        if ok_save then
            print("Auto-saved current scene before file-backed light scan.")
        else
            print("Warning: auto-save failed; file-backed scan may use last saved state.")
            print("  " .. tostring(save_err))
        end
    end

    local scene_path, path_source = detect_current_scene_path()
    if not scene_path then
        return nil, "Could not detect current .ocs path: " .. tostring(path_source)
    end

    local raw, read_err = read_all(scene_path)
    if not raw then
        return nil, "Could not read current scene: " .. tostring(read_err)
    end

    SCENE_PATH = scene_path
    SCENE_LINES = split_lines(raw)
    SCENE_BACKED_UP = false
    SCENE_NODE_SPANS = {}

    local graph_stack = {}
    local node_stack = {}
    local pin_stack = {}
    local nodes_by_id = {}
    local parent_by_emission_id = {}
    local parent_by_material_id = {}
    local emission_nodes_by_id = {}
    local pins_by_connected_id = {}
    local rows_by_key = {}
    local rows = {}
    local tracked_pins = {
        power = true,
        lightPassId = true,
        sunIntensity = true,
        turbidity = true,
    }

    local function current_emission_owner()
        for i = #pin_stack, 1, -1 do
            local p = pin_stack[i]
            if p and p.name == "emission" and p.owner then
                return p.owner
            end
        end
        return nil
    end

    local function nearest_named_node()
        for i = #node_stack, 1, -1 do
            local n = node_stack[i]
            if n and n.name and n.name ~= "" then
                return n
            end
        end
        return nil
    end

    local function nearest_emission_node()
        for i = #node_stack, 1, -1 do
            local n = node_stack[i]
            if n and tostring(n.type) == "54" then
                return n
            end
        end
        return nil
    end

    local function is_light_node(node)
        local t = tostring(node and node.type or "")
        return t == "148" or t == "149" or t == "402" or t == "403"
    end

    local function is_daylight_environment_node(node)
        if tostring(node and node.type or "") ~= "14" then
            return false
        end

        local fields = node and node.fields or {}
        return fields.power ~= nil
            and (fields.sunIntensity ~= nil
                or fields.turbidity ~= nil
                or tostring(node and node.name or ""):lower():find("daylight", 1, true) ~= nil
                or tostring(node and node.name or ""):lower():find("environment", 1, true) ~= nil)
    end

    local function nearest_light_node()
        for i = #node_stack, 1, -1 do
            local n = node_stack[i]
            if is_light_node(n) then
                return n
            end
        end
        return nil
    end

    local function is_real_light_owner(owner, emission_node)
        local owner_type = tostring(owner and owner.type or "")
        local owner_name = tostring(owner and owner.name or "")
        local emission_name = tostring(emission_node and emission_node.name or "")

        -- Octane quad/sphere/analytic/directional light nodes in these scenes.
        if owner_type == "148" or owner_type == "149" or owner_type == "402" or owner_type == "403" then
            return true
        end

        -- Keep intentionally named standalone emission nodes, but skip generic
        -- material internals that otherwise clutter the light list.
        if (not owner or owner == emission_node) and tostring(emission_node and emission_node.type or "") == "54" then
            if emission_name ~= "" and emission_name ~= "Texture emission" then
                return true
            end
        end

        if owner_name:find("light") or owner_name:find("Light") then
            return owner_type ~= "17"
        end

        return false
    end

    local function resolve_connected_field(field)
        if not field or field.value ~= nil or not field.connect then
            return field
        end

        local connected_node = nodes_by_id[tostring(field.connect)]
        if connected_node and connected_node.value_line and connected_node.value ~= nil then
            field.line = connected_node.value_line
            field.value = connected_node.value
            field.connected_node_id = connected_node.id
            field.connected_node_name = connected_node.name
        end

        return field
    end

    local function add_file_light(owner, emission_node)
        local fields = emission_node and emission_node.fields or {}
        local power_field = resolve_connected_field(fields.power)
        if not power_field or not power_field.line or power_field.value == nil then
            return
        end

        local emission_is_named_control =
            emission_node
            and tostring(emission_node.type or "") == "54"
            and tostring(emission_node.name or "") ~= ""
            and tostring(emission_node.name or "") ~= "Texture emission"

        if emission_is_named_control and (not owner or not is_light_node(owner)) then
            owner = emission_node
        end

        owner = owner or emission_node or nearest_named_node()
        if not is_real_light_owner(owner, emission_node) then
            return
        end

        local owner_id = tonumber(owner and owner.id) or tonumber(emission_node and emission_node.id) or -1
        local power_node_id = tonumber(power_field.connected_node_id) or tonumber(emission_node and emission_node.id) or -1
        local key = tostring(owner_id) .. ":" .. tostring(power_field.line)
        if rows_by_key[key] then
            return
        end
        rows_by_key[key] = true

        local owner_name = owner and owner.name or ""
        local emission_name = emission_node and emission_node.name or ""
        local display_name = owner_name
        if display_name == "" then
            display_name = emission_name
        end
        if display_name == "" then
            display_name = "<unnamed light>"
        end

        rows[#rows + 1] = {
            backend = "file",
            scene_path = scene_path,
            power_line = power_field.line,
            fields = fields,
            node_id = owner_id,
            node_type = tonumber(owner and owner.type) or -1,
            power_node_id = power_node_id,
            graph_id = owner and owner.graph_id or emission_node and emission_node.graph_id or nil,
            graph_name = owner and owner.graph_name or emission_node and emission_node.graph_name or nil,
            graph_path = owner and owner.graph_path or emission_node and emission_node.graph_path or nil,
            graph_position = owner and owner.position or emission_node and emission_node.position or nil,
            goto_node_id = tonumber(emission_node and emission_node.id) or owner_id,
            goto_node_name = emission_node and emission_node.name or display_name,
            goto_node_type = tonumber(emission_node and emission_node.type) or tonumber(owner and owner.type) or -1,
            goto_graph_id = emission_node and emission_node.graph_id or owner and owner.graph_id or nil,
            goto_graph_name = emission_node and emission_node.graph_name or owner and owner.graph_name or nil,
            goto_graph_path = emission_node and emission_node.graph_path or owner and owner.graph_path or nil,
            goto_graph_position = emission_node and emission_node.position or owner and owner.position or nil,
            name = display_name,
            original_power = power_field.value,
            current_power = power_field.value,
            slider = nil,
            value_label = nil,
        }
    end

    local function add_file_daylight_environment(node)
        if not is_daylight_environment_node(node) then
            return
        end

        local fields = node.fields or {}
        local power_field = fields.power
        if not power_field or not power_field.line or power_field.value == nil then
            return
        end

        local node_id_num = tonumber(node.id) or -1
        local key = "daylight:" .. tostring(node_id_num) .. ":" .. tostring(power_field.line)
        if rows_by_key[key] then
            return
        end
        rows_by_key[key] = true

        local display_name = node.name
        if not display_name or display_name == "" then
            display_name = "Daylight environment"
        end

        rows[#rows + 1] = {
            backend = "file",
            scene_path = scene_path,
            power_line = power_field.line,
            fields = fields,
            node_id = node_id_num,
            node_type = tonumber(node.type) or -1,
            power_node_id = node_id_num,
            goto_node_id = node_id_num,
            goto_node_name = display_name,
            goto_node_type = tonumber(node.type) or -1,
            graph_id = node.graph_id,
            graph_name = node.graph_name,
            graph_path = node.graph_path,
            graph_position = node.position,
            name = display_name,
            original_power = power_field.value,
            current_power = power_field.value,
            slider = nil,
            value_label = nil,
            is_daylight_environment = true,
        }
    end

    local function is_exposed_light_control_node(node)
        if tostring(node and node.type or "") ~= "6" then
            return false
        end

        local name = tostring(node and node.name or "")
        if name == "" then
            return false
        end

        return name:match("[Pp]ower$") ~= nil
            or name:match("[Ii]ntensity$") ~= nil
    end

    local function add_file_exposed_control(node)
        if not is_exposed_light_control_node(node) then
            return
        end
        if not node.value_line or node.value == nil then
            return
        end

        local node_id_num = tonumber(node.id) or -1
        local key = "exposed:" .. tostring(node_id_num) .. ":" .. tostring(node.value_line)
        if rows_by_key[key] then
            return
        end
        rows_by_key[key] = true

        rows[#rows + 1] = {
            backend = "file",
            scene_path = scene_path,
            power_line = node.value_line,
            fields = {},
            node_id = node_id_num,
            node_type = tonumber(node.type) or -1,
            power_node_id = node_id_num,
            goto_node_id = node_id_num,
            goto_node_name = node.name,
            goto_node_type = tonumber(node.type) or -1,
            graph_id = node.graph_id,
            graph_name = node.graph_name,
            graph_path = node.graph_path,
            graph_position = node.position,
            name = node.name,
            original_power = node.value,
            current_power = node.value,
            slider = nil,
            value_label = nil,
            is_exposed_control = true,
        }
    end

    for i, line in ipairs(SCENE_LINES) do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed:match("^<graph[%s>]") then
            local attrs = parse_attrs(trimmed)
            local graph = {
                id = attrs.id or "",
                name = attrs.name or "",
                type = attrs.type or "",
                position = parse_position(attrs.position),
                parent = top(graph_stack),
            }
            graph.path = graph_path_for(graph)
            push(graph_stack, graph)
            if trimmed:match("/>%s*$") then
                pop(graph_stack)
            end
        elseif trimmed:match("^</graph>") then
            pop(graph_stack)
        elseif trimmed:match("^</node>") then
            local closing_node = top(node_stack)
            if closing_node then
                closing_node["end"] = i
                SCENE_NODE_SPANS[tostring(closing_node.id)] = {
                    start = closing_node.start,
                    ["end"] = closing_node["end"],
                    name = closing_node.name,
                    type = closing_node.type,
                }
            end
            if closing_node and tostring(closing_node.type) == "54" then
                emission_nodes_by_id[tostring(closing_node.id)] = closing_node
                local emission_owner = current_emission_owner()
                local owner = nearest_light_node()
                    or parent_by_material_id[tostring(emission_owner and emission_owner.id or "")]
                    or parent_by_emission_id[tostring(closing_node.id)]
                    or emission_owner
                add_file_light(owner, closing_node)
            elseif closing_node and is_daylight_environment_node(closing_node) then
                add_file_daylight_environment(closing_node)
            elseif closing_node and is_exposed_light_control_node(closing_node) then
                add_file_exposed_control(closing_node)
            end
            pop(node_stack)
        elseif trimmed:match("^<node[%s>]") then
            local attrs = parse_attrs(trimmed)
            local graph = top(graph_stack)
            local n = {
                id = attrs.id or "-1",
                name = attrs.name or "",
                type = attrs.type or "",
                position = parse_position(attrs.position),
                start = i,
                fields = {},
                graph_id = graph and graph.id or nil,
                graph_name = graph and graph.name or nil,
                graph_path = graph and graph.path or nil,
            }
            nodes_by_id[tostring(n.id)] = n
            push(node_stack, n)
        elseif trimmed:match("^</pin>") then
            pop(pin_stack)
        elseif trimmed:match("^<pin[%s>]") then
            local attrs = parse_attrs(trimmed)
            local pin_name = attrs.name or ""
            local pin_owner = top(node_stack)
            if attrs.connect and attrs.connect ~= "" and pin_owner then
                local key = tostring(attrs.connect)
                pins_by_connected_id[key] = pins_by_connected_id[key] or {}
                pins_by_connected_id[key][#pins_by_connected_id[key] + 1] = {
                    owner = pin_owner,
                    name = pin_name,
                }

                if tracked_pins[pin_name] then
                    pin_owner.fields[pin_name] = {
                        connect = key,
                    }
                end
            end

            local owner = pin_owner
            if pin_name == "emission" then
                owner = pin_owner
                if attrs.connect and attrs.connect ~= "" then
                    parent_by_emission_id[tostring(attrs.connect)] = owner
                end
            elseif pin_name == "material1" then
                owner = pin_owner
                if attrs.connect and attrs.connect ~= "" then
                    parent_by_material_id[tostring(attrs.connect)] = owner
                end
            end

            if not trimmed:match("/>%s*$") then
                push(pin_stack, { name = pin_name, owner = owner })
            end
        else
            local attr_name = trimmed:match("^<attr%s+[^>]-name%s*=%s*['\"](.-)['\"][^>]*>")
            if attr_name == "value" then
                local pin_top = top(pin_stack)
                local pin_name = pin_top and pin_top.name or ""
                local current_node = top(node_stack)
                if current_node and tostring(current_node.type) == "6" then
                    current_node.value_line = i
                    current_node.value = first_number(trimmed:match(">([^<]*)</attr>"))
                end
                if tracked_pins[pin_name] then
                    local value = first_number(trimmed:match(">([^<]*)</attr>"))
                    local field_owner = pin_top and pin_top.owner or current_node
                    if field_owner then
                        field_owner.fields[pin_name] = {
                            line = i,
                            value = value,
                        }
                    end
                    local emission_node = nearest_emission_node()
                    if emission_node and tostring(emission_node.type) == "54" then
                        emission_node.fields[pin_name] = {
                            line = i,
                            value = value,
                        }
                    end
                end

                -- Rows are created when the emission node closes, after all
                -- sibling option pins have been read.
            end
        end
    end

    for _, node in pairs(nodes_by_id) do
        if node.fields then
            for _, field in pairs(node.fields) do
                resolve_connected_field(field)
            end
        end
    end

    for _, emission_node in pairs(emission_nodes_by_id) do
        add_file_light(nil, emission_node)
    end

    for emission_id, owner in pairs(parent_by_emission_id) do
        local emission_node = emission_nodes_by_id[tostring(emission_id)]
        if emission_node then
            add_file_light(owner, emission_node)
        end
    end

    local function exposure_base_name(name)
        local base = tostring(name or "")
        base = base:gsub("%s+[Pp]ower$", "")
        base = base:gsub("%s+[Ii]ntensity$", "")
        return base
    end

    local function find_emission_by_name(base_name)
        local wanted = tostring(base_name or "")
        if wanted == "" then
            return nil
        end

        for _, emission_node in pairs(emission_nodes_by_id) do
            if tostring(emission_node.name or "") == wanted then
                return emission_node
            end
        end

        local wanted_low = wanted:lower()
        for _, emission_node in pairs(emission_nodes_by_id) do
            local name_low = tostring(emission_node.name or ""):lower()
            if name_low == wanted_low then
                return emission_node
            end
        end

        return nil
    end

    local function find_emission_from_float_control(float_node_id, row_name)
        local first_emission = nil
        local linkers = pins_by_connected_id[tostring(float_node_id)] or {}
        for _, connected_pin in ipairs(linkers) do
            local connected_owner = connected_pin.owner
            if connected_owner and tostring(connected_owner.type) == "54" then
                if connected_pin.name == "power" or connected_pin.name == "efficiency or texture" then
                    return connected_owner, "direct-connection"
                end
                first_emission = first_emission or connected_owner
            end
        end

        for _, linker_pin in ipairs(linkers) do
            local linker = linker_pin.owner
            if linker and linker_pin.name == "input" then
                local emission_pins = pins_by_connected_id[tostring(linker.id)] or {}
                for _, emission_pin in ipairs(emission_pins) do
                    local emission_node = emission_pin.owner
                    if emission_node and tostring(emission_node.type) == "54" then
                        if emission_pin.name == "power" or emission_pin.name == "efficiency or texture" then
                            return emission_node, "connection"
                        end
                        first_emission = first_emission or emission_node
                    end
                end
            end
        end

        if first_emission then
            return first_emission, "connection-nearest"
        end

        local base = exposure_base_name(row_name)
        local by_name = find_emission_by_name(base)
        if by_name then
            return by_name, "name"
        end

        return nil, nil
    end

    -- Second pass handles emission nodes that were connected before their node
    -- definitions appeared in the file.
    for _, row in ipairs(rows) do
        if row.name == "<unnamed light>" then
            local owner = parent_by_emission_id[tostring(row.power_node_id)]
            if owner and owner.name and owner.name ~= "" then
                row.name = owner.name
                row.node_id = tonumber(owner.id) or row.node_id
            end
        end

        if row.is_exposed_control then
            local emission_node, target_source = find_emission_from_float_control(row.power_node_id, row.name)
            if emission_node then
                row.goto_node_id = tonumber(emission_node.id) or row.goto_node_id
                row.goto_node_name = emission_node.name
                row.goto_node_type = tonumber(emission_node.type) or row.goto_node_type
                row.goto_graph_id = emission_node.graph_id
                row.goto_graph_name = emission_node.graph_name
                row.goto_graph_path = emission_node.graph_path
                row.goto_graph_position = emission_node.position
                row.goto_target_source = target_source
                row.fields = row.fields or {}
                if emission_node.fields and emission_node.fields.lightPassId then
                    row.fields.lightPassId = emission_node.fields.lightPassId
                end
            end
        end
    end

    local function row_light_id(row)
        local field = row.fields and row.fields.lightPassId
        if not field or field.value == nil then
            return nil
        end
        return math.floor((tonumber(field.value) or 0) + 0.0000001)
    end

    table.sort(rows, function(a, b)
        local a_id = row_light_id(a)
        local b_id = row_light_id(b)
        if a_id and b_id and a_id ~= b_id then
            return a_id < b_id
        end
        if a_id and not b_id then
            return true
        end
        if b_id and not a_id then
            return false
        end
        if a.name == b.name then
            return a.node_id < b.node_id
        end
        return a.name < b.name
    end)

    print("File-backed scene path from octane.project." .. tostring(path_source) .. "():")
    print("  " .. scene_path)
    print("Found " .. tostring(#rows) .. " file-backed light/emission rows.")
    local exposed_count = 0
    local daylight_count = 0
    for _, row in ipairs(rows) do
        if row.is_exposed_control then
            exposed_count = exposed_count + 1
        end
        if row.is_daylight_environment then
            daylight_count = daylight_count + 1
        end
    end
    if exposed_count > 0 then
        print("  Includes " .. tostring(exposed_count) .. " exposed Float control rows.")
    end
    if daylight_count > 0 then
        print("  Includes " .. tostring(daylight_count) .. " daylight environment rows.")
    end
    local function debug_row_light_id(row)
        local field = row.fields and row.fields.lightPassId
        if field and field.value ~= nil then
            return tostring(math.floor((tonumber(field.value) or 0) + 0.0000001))
        end
        return "--"
    end
    for _, row in ipairs(rows) do
        print(string.format(
            "  %s [%d] -> file power node [%d], line %d, power %.3f, Light ID %s%s",
            tostring(row.name),
            tonumber(row.node_id) or -1,
            tonumber(row.power_node_id) or -1,
            tonumber(row.power_line) or -1,
            tonumber(row.current_power) or 0,
            debug_row_light_id(row),
            row.goto_node_id and row.goto_node_id ~= row.node_id
                and ("; Go targets emission [" .. tostring(row.goto_node_id) .. "] via " .. tostring(row.goto_target_source))
                or ""
        ))
    end

    return rows, nil
end

local function create_label(text, width)
    return octane.gui.create
    {
        type   = octane.gui.componentType.LABEL,
        text   = text,
        width  = width or 120,
        height = COMPACT_CONTROL_HEIGHT,
    }
end

local function create_button(text, width, callback)
    return octane.gui.create
    {
        type     = octane.gui.componentType.BUTTON,
        text     = text,
        width    = width or 58,
        height   = COMPACT_CONTROL_HEIGHT,
        callback = callback,
    }
end

local function slider_max_for_power(power)
    return POWER_SLIDER_MAX
end

local function create_slider(value, max_value, callback)
    return octane.gui.create
    {
        type     = octane.gui.componentType.SLIDER,
        minValue = 0,
        maxValue = max_value or slider_max_for_power(value),
        step     = SLIDER_STEP,
        value    = value,
        width    = 170,
        height   = COMPACT_CONTROL_HEIGHT,
        callback = callback,
    }
end

local function short_name(name, max_len)
    max_len = max_len or 34
    name = tostring(name or "<unnamed>")
    if #name <= max_len then
        return name
    end
    return name:sub(1, max_len - 3) .. "..."
end

local function row_label_text(light)
    return short_name(light.name, 34) .. "  [" .. tostring(light.node_id) .. "]"
end

local function create_scrollable_row_area(rows_group)
    local panel_type = octane.gui.componentType.PANEL_STACK
    if not panel_type then
        return rows_group
    end

    return octane.gui.create
    {
        type     = panel_type,
        width    = 1320,
        height   = ROW_PANEL_HEIGHT,
        children = { rows_group },
        captions = { "Lights" },
        open     = { true },
    }
end

local function collect_lights()
    local graph, graph_api = get_root_graph()
    if not graph then
        return nil, graph_api
    end

    local nodes, source = collect_all_nodes(graph)
    if not nodes then
        return nil, "could not enumerate scene nodes"
    end

    local lights = {}
    local seen = {}
    local function add_light(display_node, power_node, mode)
        if not power_node or not has_pin(power_node, "power") then
            return
        end

        local power = get_pin_number(power_node, "power")
        if power ~= nil then
            local display_id = node_id(display_node or power_node)
            local power_id = node_id(power_node)
            local key = tostring(power_id) .. ":" .. tostring(power_node)
            if not seen[key] then
                seen[key] = true
                local display_name = node_name(display_node or power_node)
                if display_name == "<unnamed>" or display_name == "" then
                    display_name = node_name(power_node)
                end
                lights[#lights + 1] = {
                    node = power_node,
                    node_id = display_id,
                    power_node_id = power_id,
                    node_type = node_type(display_node or power_node),
                    name = display_name,
                    original_power = power,
                    current_power = power,
                    mode = mode or "power",
                    slider = nil,
                    value_label = nil,
                }
            end
        end
    end

    for _, node in ipairs(nodes) do
        -- Geometry light nodes usually expose an "emission" pin whose value is
        -- the emission node. The emission node owns the actual "power" pin.
        if has_pin(node, "emission") then
            local emission_node = get_pin_value(node, "emission")
            if type(emission_node) == "table" or type(emission_node) == "userdata" then
                add_light(node, emission_node, "emission")
            end
        end
    end

    for _, node in ipairs(nodes) do
        -- Also include standalone emission nodes or already-expanded nested
        -- emission nodes. Dedupe keeps these from duplicating parent light rows.
        add_light(node, node, "direct")
    end

    -- Last chance: if the nodegraph only exposes top-level light nodes, try
    -- common getter names that may return the connected node behind a pin.
    for _, node in ipairs(nodes) do
        if has_pin(node, "emission") then
            local variants = {
                "getConnectedNode",
                "getInputNode",
                "getPinNode",
            }
            for _, method in ipairs(variants) do
                local ok, emission_node = call_method(node, method, "emission")
                if ok and emission_node and (type(emission_node) == "table" or type(emission_node) == "userdata") then
                    add_light(node, emission_node, method)
                    break
                end
            end
        end
    end

    -- Some Octane builds only materialize nested emission nodes when they are
    -- expanded in the graph. In that case, the row will still appear, but with
    -- the nested node's own name if there is no parent link available.
    for _, node in ipairs(nodes) do
        if has_pin(node, "power") then
            local power = get_pin_number(node, "power")
            if power ~= nil then
                local name = node_name(node)
                if name ~= "<unnamed>" and name ~= "" then
                    add_light(node, node, "named-direct")
                end
            end
        end
    end

    table.sort(lights, function(a, b)
        if a.name == b.name then
            return a.node_id < b.node_id
        end
        return a.name < b.name
    end)

    print("Root graph API: " .. tostring(graph_api))
    print("Enumerated nodes via nodegraph." .. tostring(source) .. "()")
    print("Found " .. tostring(#lights) .. " controllable light/emission nodes with a power pin.")
    for i, light in ipairs(lights) do
        if i > MAX_LIGHTS_IN_WINDOW then
            print("  ... " .. tostring(#lights - MAX_LIGHTS_IN_WINDOW) .. " more live rows hidden from log")
            break
        end
        print(string.format(
            "  %s [%d] -> power node [%d], power %.3f, source %s",
            tostring(light.name),
            tonumber(light.node_id) or -1,
            tonumber(light.power_node_id) or -1,
            tonumber(light.current_power) or 0,
            tostring(light.mode)
        ))
    end

    local named_count = 0
    local anonymous_count = 0
    for _, light in ipairs(lights) do
        if light.name and light.name ~= "" and light.name ~= "<unnamed>" and light.node_id and light.node_id >= 0 then
            named_count = named_count + 1
        else
            anonymous_count = anonymous_count + 1
        end
    end

    if named_count == 0 or anonymous_count > named_count or #lights > (MAX_LIGHTS_IN_WINDOW * 3) then
        print(string.format(
            "Live graph exposed noisy anonymous internals (%d named, %d anonymous); switching to file-backed scan.",
            named_count,
            anonymous_count
        ))
        return collect_file_lights()
    end

    return lights, nil
end

local function format_power(value)
    return string.format("%.3f", tonumber(value) or 0)
end

local function update_component(component, props)
    if component and type(component.updateProperties) == "function" then
        component:updateProperties(props)
        return true
    end
    return false
end

local function select_panel_row(light)
    -- No visual selection marker; Octane keeps stale label text in some builds.
end

local function get_component_value(component, event, fallback)
    if component and type(component.getProperties) == "function" then
        local ok, props = pcall(function()
            return component:getProperties()
        end)
        if ok and type(props) == "table" and props.value ~= nil then
            return tonumber(props.value) or fallback
        end
    end

    if type(event) == "table" and event.value ~= nil then
        return tonumber(event.value) or fallback
    end

    return fallback
end

local function update_value_label(light)
    if light.value_label then
        update_component(light.value_label, { text = format_power(light.current_power) })
    end
end

local function format_light_id(light)
    local field = light.fields and light.fields.lightPassId
    if field and field.value ~= nil then
        return tostring(math.floor((tonumber(field.value) or 0) + 0.0000001))
    end

    return "--"
end

local function update_light_id_label(light)
    if light.light_id_label then
        update_component(light.light_id_label, { text = format_light_id(light) })
    end
end

local function set_light_pass_id(light, value)
    if light.deleted then
        print("Skipping deleted row: " .. tostring(light.name))
        return false
    end

    local field = light.fields and light.fields.lightPassId
    if not field or not field.line or not SCENE_LINES or not SCENE_LINES[field.line] then
        print("No editable Light ID found for " .. tostring(light.name))
        return false
    end

    value = math.max(0, math.min(LIGHT_PASS_ID_MAX, math.floor((tonumber(value) or 0) + 0.5)))
    SCENE_LINES[field.line] = replace_attr_numeric_line(SCENE_LINES[field.line], value)
    field.value = value
    update_light_id_label(light)
    return true
end

local function create_light_id_control(light)
    local field = light.fields and light.fields.lightPassId
    if not field then
        return create_label(format_light_id(light), 86)
    end

    light.light_id_label = create_button(format_light_id(light), 38, function()
        -- Centered value display; use -/+ to edit.
    end)
    local minus = create_button("-", 24, function()
        select_panel_row(light)
        set_light_pass_id(light, (tonumber(field.value) or 0) - 1)
    end)
    local plus = create_button("+", 24, function()
        select_panel_row(light)
        set_light_pass_id(light, (tonumber(field.value) or 0) + 1)
    end)

    return octane.gui.create
    {
        type     = octane.gui.componentType.GROUP,
        text     = "",
        rows     = 1,
        cols     = 3,
        children = { minus, light.light_id_label, plus },
        padding  = { 0 },
        border   = false,
    }
end

local function set_light_power(light, value)
    if light.deleted then
        print("Skipping deleted row: " .. tostring(light.name))
        return false
    end

    if light.backend == "file" then
        if SCENE_LINES and light.power_line and SCENE_LINES[light.power_line] then
            SCENE_LINES[light.power_line] = replace_attr_numeric_line(SCENE_LINES[light.power_line], value)
            light.current_power = value
            update_value_label(light)
            return true
        end
        print("Could not update file-backed row for " .. tostring(light.name))
        return false
    end

    if set_pin_number(light.node, "power", value) then
        light.current_power = value
        update_value_label(light)
        return true
    end

    return false
end

local function apply_power(light, power)
    power = tonumber(power) or 0
    if set_light_power(light, power) then
        light.current_power = power
        update_value_label(light)
    end
end

local function set_light_off(light)
    if set_light_power(light, 0) then
        light.current_power = 0
        if light.slider then
            update_component(light.slider, { value = 0 })
        end
        update_value_label(light)
    end
end

local function reset_light(light)
    if set_light_power(light, light.original_power) then
        light.current_power = light.original_power
        if light.slider then
            update_component(light.slider, { value = light.original_power })
        end
        update_value_label(light)
    end
end

local function remove_connect_attr_to_node(line, node_id)
    local id = tostring(node_id)
    local changed = false

    line = line:gsub("%s+connect%s*=%s*\"" .. id .. "\"", function()
        changed = true
        return ""
    end)
    line = line:gsub("%s+connect%s*=%s*'" .. id .. "'", function()
        changed = true
        return ""
    end)

    return line, changed
end

local function mark_file_node_deleted(light)
    if not light or light.backend ~= "file" then
        print("Delete is only available in file-backed mode.")
        return false
    end
    if light.deleted then
        print("Already marked deleted: " .. tostring(light.name))
        return false
    end
    if not SCENE_LINES or not SCENE_NODE_SPANS then
        print("No file-backed scene data is loaded; cannot delete.")
        return false
    end

    local target_id = tonumber(light.goto_node_id or light.node_id)
    if not target_id or target_id < 0 then
        print("Cannot delete " .. tostring(light.name) .. ": no target node id.")
        return false
    end

    local span = SCENE_NODE_SPANS[tostring(target_id)]
    if not span or not span.start or not span["end"] then
        print("Cannot delete " .. tostring(light.name) .. ": target node block not found for id " .. tostring(target_id))
        return false
    end

    for i, line in ipairs(SCENE_LINES) do
        if i < span.start or i > span["end"] then
            SCENE_LINES[i] = remove_connect_attr_to_node(line, target_id)
        end
    end

    for i = span.start, span["end"] do
        SCENE_LINES[i] = ""
    end

    light.deleted = true
    light.current_power = 0
    if light.slider then
        update_component(light.slider, { value = 0 })
    end
    if light.value_label then
        update_component(light.value_label, { text = "DELETED" })
    end

    print("Marked node for deletion: " .. tostring(light.goto_node_name or light.name) .. " [" .. tostring(target_id) .. "]")
    print("Click Apply+Render to write the scene and reload.")
    return true
end

local function max_visible_power(lights, shown_count)
    return POWER_SLIDER_MAX
end

local function find_live_node_by_id(target_id)
    target_id = tonumber(target_id)
    if not target_id then
        return nil
    end

    local graph = get_root_graph()
    if not graph then
        return nil
    end

    local nodes = collect_all_nodes(graph)
    if not nodes then
        return nil
    end

    for _, node in ipairs(nodes) do
        if node_id(node) == target_id then
            local owner_graph = node_owner_graph(node)
            return node, owner_graph or graph
        end
    end
    return nil, graph
end

local function graph_leaf_name(path)
    local s = tostring(path or "")
    if s == "" then
        return ""
    end

    local last = s
    for part in s:gmatch("[^/]+") do
        last = part
    end
    return (last:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function live_graph_label(graph, fallback)
    local parts = {}
    if fallback and fallback ~= "" then
        parts[#parts + 1] = fallback
    end
    if graph then
        parts[#parts + 1] = tostring(graph)
        local info = nil
        if octane and octane.nodegraph and type(octane.nodegraph.getNodeGraphInfo) == "function" then
            local ok, ret = pcall(octane.nodegraph.getNodeGraphInfo, graph)
            if ok then
                info = ret
            end
        end
        if type(info) == "table" then
            parts[#parts + 1] = tostring(info.name or "")
            parts[#parts + 1] = tostring(info.id or "")
        end
    end
    return table.concat(parts, " ")
end

local function graph_score_for_light(graph, live_path, light)
    local target_path = tostring(light.goto_graph_path or light.graph_path or "")
    if target_path == "" then
        return 0
    end

    local target_leaf = graph_leaf_name(target_path)
    local label = live_graph_label(graph, live_path):lower()
    local target_low = target_path:lower()
    local leaf_low = target_leaf:lower()

    if label:find(target_low, 1, true) then
        return 100
    end

    if leaf_low ~= "" and label:find(leaf_low, 1, true) then
        return 50
    end

    if leaf_low == "scene" and not label:find("static", 1, true) then
        return 20
    end

    return 0
end

local function collect_live_nodes_with_paths(graph)
    local out = {}
    local seen = {}

    local function item_name(item)
        if not item then
            return ""
        end
        local info = nil
        if octane and octane.nodegraph and type(octane.nodegraph.getNodeGraphInfo) == "function" then
            local ok, ret = pcall(octane.nodegraph.getNodeGraphInfo, item)
            if ok then
                info = ret
            end
        end
        if type(info) == "table" and info.name and tostring(info.name) ~= "" then
            return tostring(info.name)
        end
        local s = tostring(item)
        local name = s:match("name=([^,%}]+)")
            or s:match("name%s*:%s*([^,%}]+)")
            or s:match("%(([^%)]-)%)")
        return tostring(name or "")
    end

    local function visit(item, path)
        if not item then
            return
        end

        local marker = tostring(item) .. "|" .. tostring(path)
        if seen[marker] then
            return
        end
        seen[marker] = true

        local ok_count = call_method(item, "getPinCount")
        if ok_count then
            out[#out + 1] = {
                node = item,
                graph = nil,
                path = path,
            }
        end

        local ok_items, children = call_method(item, "getOwnedItems")
        if ok_items and type(children) == "table" then
            local child_path = path
            if not ok_count then
                local label = item_name(item)
                if label ~= "" then
                    child_path = path ~= "" and (path .. " / " .. label) or label
                end
            end
            for _, child in ipairs(children) do
                visit(child, child_path)
            end
        end
    end

    visit(graph, "")

    for _, entry in ipairs(out) do
        local owner_graph = node_owner_graph(entry.node)
        entry.graph = owner_graph or graph
    end

    return out
end

local function live_node_matches_light(node, light)
    local info = node_info(node)
    local type_id = tonumber(info.type) or tonumber(info.typeId) or node_type(node)
    local display = tostring(node)
    local wanted_name = tostring(light.goto_node_name or light.name or "")

    local wanted_type = light.goto_node_type or light.node_type
    if tonumber(wanted_type) == 54 then
        local display_low = display:lower()
        if display_low:find("nt_in_float", 1, true)
            or display_low:find("float in", 1, true)
            or (wanted_name ~= "" and display:find(wanted_name .. " Power", 1, true))
        then
            return false
        end
    end

    if wanted_type and tonumber(wanted_type) == tonumber(type_id) then
        if wanted_name ~= "" and display:find(wanted_name, 1, true) then
            return true
        end
        if tonumber(wanted_type) == 402 and display:find("Analytic light", 1, true) then
            return true
        end
        if tonumber(wanted_type) == 403 and display:find("Directional light", 1, true) then
            return true
        end
    end

    if wanted_name ~= "" and display:find(wanted_name, 1, true) then
        return true
    end

    return false
end

local function find_live_node_for_file_light_by_graph(light)
    local graph = get_root_graph()
    if not graph then
        return nil, nil, "no graph"
    end

    local entries = collect_live_nodes_with_paths(graph)
    local best = nil
    local best_score = -1
    local matched = 0
    local target_leaf = graph_leaf_name(light.goto_graph_path or light.graph_path):lower()
    local prefer_later_duplicate = target_leaf ~= "" and target_leaf ~= "scene"

    for _, entry in ipairs(entries) do
        if live_node_matches_light(entry.node, light) then
            matched = matched + 1
            local score = graph_score_for_light(entry.graph, entry.path, light)
            if score > best_score or (score == best_score and prefer_later_duplicate) then
                best = entry
                best_score = score
            end
        end
    end

    if best then
        return best.node, best.graph or graph, "graph-aware name (" .. tostring(matched) .. " matches, score " .. tostring(best_score) .. ")"
    end

    return nil, graph, "graph-aware name not found"
end

local function find_live_node_for_light(light, allow_file_fuzzy)
    local target_id = light.goto_node_id or light.node_id
    local node, graph = find_live_node_by_id(target_id)
    if node then
        return node, graph, "id"
    end

    graph = get_root_graph()
    if not graph then
        return nil, nil, "no graph"
    end

    if light.backend == "file" and not allow_file_fuzzy then
        return nil, graph, "file-backed id not exposed live"
    end

    if light.backend == "file" and allow_file_fuzzy then
        local source
        node, graph, source = find_live_node_for_file_light_by_graph(light)
        if node then
            return node, graph, source
        end
    end

    local nodes = collect_all_nodes(graph)
    if not nodes then
        return nil, graph, "no nodes"
    end

    local fallback = nil
    local fallback_graph = nil
    for _, candidate in ipairs(nodes) do
        if live_node_matches_light(candidate, light) then
            local owner_graph = node_owner_graph(candidate)
            return candidate, owner_graph or graph, "type/name"
        end
        local wanted_type = light.goto_node_type or light.node_type
        if wanted_type and tonumber(wanted_type) == node_type(candidate) then
            fallback = fallback or candidate
            if not fallback_graph then
                fallback_graph = node_owner_graph(candidate)
            end
        end
    end

    if fallback then
        return fallback, fallback_graph or graph, "type"
    end

    return nil, graph, "not found"
end

local function select_live_node(node, graph)
    if not node or not octane or not octane.project then
        return false
    end

    if type(octane.project.clearSelection) == "function" then
        pcall(octane.project.clearSelection)
    end

    if type(octane.project.select) == "function" then
        local ok, result = pcall(octane.project.select, node)
        if ok and result ~= false then
            print("Selected node via octane.project.select(node)")
            return true
        end

        ok, result = pcall(octane.project.select, graph, node)
        if ok and result ~= false then
            print("Selected node via octane.project.select(graph, node)")
            return true
        end
    end

    if type(octane.project.setSelection) == "function" then
        local ok, result = pcall(octane.project.setSelection, { node })
        if ok and result ~= false then
            print("Selected node via octane.project.setSelection({node})")
            return true
        end

        ok, result = pcall(octane.project.setSelection, node)
        if ok and result ~= false then
            print("Selected node via octane.project.setSelection(node)")
            return true
        end

        ok, result = pcall(octane.project.setSelection, graph, { node })
        if ok and result ~= false then
            print("Selected node via octane.project.setSelection(graph, {node})")
            return true
        end
    end

    return false
end

local function try_select_file_node_by_id(light)
    if not light or not octane or not octane.project then
        return false
    end

    local ids = {}
    local seen_ids = {}
    for _, raw_id in ipairs({ light.goto_node_id, light.node_id, light.power_node_id }) do
        local id = tonumber(raw_id)
        if id and id >= 0 and not seen_ids[id] then
            ids[#ids + 1] = id
            seen_ids[id] = true
        end
    end

    if type(octane.project.clearSelection) == "function" then
        pcall(octane.project.clearSelection)
    end

    for _, id in ipairs(ids) do
        if id and id >= 0 then
            if type(octane.project.select) == "function" then
                local ok, result = pcall(octane.project.select, id)
                if ok and result ~= false then
                    print("Selected file-backed node id via octane.project.select(id): " .. tostring(id))
                    return true
                end

                ok, result = pcall(octane.project.select, tostring(id))
                if ok and result ~= false then
                    print("Selected file-backed node id via octane.project.select(tostring(id)): " .. tostring(id))
                    return true
                end
            end

            if type(octane.project.setSelection) == "function" then
                local ok, result = pcall(octane.project.setSelection, { id })
                if ok and result ~= false then
                    print("Selected file-backed node id via octane.project.setSelection({id}): " .. tostring(id))
                    return true
                end

                ok, result = pcall(octane.project.setSelection, id)
                if ok and result ~= false then
                    print("Selected file-backed node id via octane.project.setSelection(id): " .. tostring(id))
                    return true
                end
            end
        end
    end

    return false
end

local function try_object_methods(obj, label, node, graph)
    if not obj then
        return false
    end

    local method_variants = {
        { "showInGraphEditor", graph, node },
        { "showInGraphEditor", node },
        { "showInGraph", graph, node },
        { "showInGraph", node },
        { "openInGraphEditor", graph, node },
        { "openInGraphEditor", node },
        { "openGraph", graph },
        { "openGraph", node },
        { "open", node },
        { "edit", node },
        { "editNode", node },
        { "inspect", node },
        { "inspectNode", node },
        { "frameSelection" },
        { "frameSelected" },
        { "zoomToSelection" },
        { "zoomToSelected" },
        { "zoomSelected" },
        { "centerOnNode", graph, node },
        { "centerOnNode", node },
        { "centerOnItem", node },
        { "panToNode", graph, node },
        { "panToNode", node },
        { "show", node },
        { "focus", node },
        { "focus", graph, node },
        { "focusNode", node },
        { "focusNode", graph, node },
        { "frame", node },
        { "frame", graph, node },
        { "frameNode", node },
        { "frameNode", graph, node },
    }

    for _, variant in ipairs(method_variants) do
        local name = variant[1]
        local fn = obj[name]
        if type(fn) == "function" then
            local args = {}
            for i = 2, #variant do
                args[#args + 1] = variant[i]
            end

            local ok, result = pcall(fn, obj, table.unpack(args))
            if ok and result ~= false then
                print("Located light via " .. label .. "." .. name .. "()")
                return true
            end

            ok, result = pcall(fn, table.unpack(args))
            if ok and result ~= false then
                print("Located light via " .. label .. "." .. name .. "() direct")
                return true
            end
        end
    end

    return false
end

local function print_navigation_api_hints()
    if not octane or not octane.help or type(octane.help.functions) ~= "function" then
        return
    end

    local modules = { "project", "nodegraph", "gui" }
    local filters = {
        "show",
        "graph",
        "focus",
        "frame",
        "zoom",
        "open",
        "pan",
        "center",
        "select",
    }

    for _, module_name in ipairs(modules) do
        local ok, funcs = pcall(octane.help.functions, module_name)
        if ok and type(funcs) == "table" then
            local matches = {}
            for _, fn in ipairs(funcs) do
                local low = tostring(fn):lower()
                for _, filter in ipairs(filters) do
                    if low:find(filter, 1, true) then
                        matches[#matches + 1] = tostring(fn)
                        break
                    end
                end
            end
            if #matches > 0 then
                print("Relevant octane." .. module_name .. " functions:")
                for _, fn in ipairs(matches) do
                    print("  " .. fn)
                end
            end
        end
    end
end

local function locate_light(light)
    print("")
    print("Locate request:")
    print("  " .. tostring(light.name) .. " [" .. tostring(light.node_id) .. "]")
    if light.goto_node_id and light.goto_node_id ~= light.node_id then
        print("  target emission: " .. tostring(light.goto_node_name or "<unnamed>") .. " [" .. tostring(light.goto_node_id) .. "]")
    end
    local target_graph_path = light.goto_graph_path or light.graph_path
    local target_graph_name = light.goto_graph_name or light.graph_name
    local target_graph_id = light.goto_graph_id or light.graph_id
    local target_position = light.goto_graph_position or light.graph_position
    if target_graph_path then
        print("  graph path: " .. tostring(target_graph_path))
    elseif target_graph_name then
        print("  graph: " .. tostring(target_graph_name) .. " [" .. tostring(target_graph_id) .. "]")
    end
    if target_position then
        print("  graph position: " .. tostring(target_position.raw))
    end

    local node, graph = nil, nil
    if light.node then
        node = light.node
    else
        local source
        node, graph, source = find_live_node_for_light(light)
        print("  live lookup: " .. tostring(source))
    end

    local function try_navigate_node(live_node, live_graph)
        local selected = select_live_node(live_node, live_graph)
        if try_object_methods(live_node, "node", live_node, live_graph) then
            return true
        end
        if try_object_methods(live_graph, "graph", live_node, live_graph) then
            return true
        end
        if octane and octane.nodegraph and try_object_methods(octane.nodegraph, "octane.nodegraph", live_node, live_graph) then
            return true
        end
        if octane and octane.project and try_object_methods(octane.project, "octane.project", live_node, live_graph) then
            return true
        end
        if selected then
            print("Selected live graph node, but no focus/show API succeeded: " .. tostring(live_node))
            return true
        end
        return false
    end

    if node then
        if try_navigate_node(node, graph) then
            return
        end
    elseif light.backend == "file" then
        local fallback_source
        node, graph, fallback_source = find_live_node_for_light(light, true)
        print("  live fuzzy fallback: " .. tostring(fallback_source))
        if node and try_navigate_node(node, graph) then
            return
        end

        if try_select_file_node_by_id(light) then
            print("Octane accepted exact node-id selection, but this Lua API does not expose graph-view panning.")
            return
        end
    end

    print("Could not call a live 'Show in Graph Editor' API from Lua.")
    print("Use this target manually, or send me this output so I can wire the exact Octane function:")
    if target_graph_path then
        print("  graph path: " .. tostring(target_graph_path))
    elseif target_graph_name then
        print("  graph: " .. tostring(target_graph_name) .. " [" .. tostring(target_graph_id) .. "]")
    end
    print("  node id: " .. tostring(light.goto_node_id or light.node_id))
    if light.goto_node_name then
        print("  node name: " .. tostring(light.goto_node_name))
    end
    if light.power_node_id and light.power_node_id ~= light.node_id then
        print("  power node id: " .. tostring(light.power_node_id))
    end
    if target_position then
        print("  position: " .. tostring(target_position.raw))
    end
    print_navigation_api_hints()
end

local function build_window(lights)
    local children = {}
    local has_file_backend = false
    for _, light in ipairs(lights) do
        if light.backend == "file" then
            has_file_backend = true
            break
        end
    end

    local title = create_label("Light Control Panel", 420)
    children[#children + 1] = title

    if has_file_backend then
        children[#children + 1] = create_label("File-backed mode: adjust, then Apply + Reload + Render.", 520)
    end

    local header = octane.gui.create
    {
        type     = octane.gui.componentType.GROUP,
        text     = "",
        rows     = 1,
        cols     = 5,
        children = {
            create_label("Light / emission node", 230),
            create_label("Set Power", 170),
            create_label("Current", 70),
            create_label("Light ID", 86),
            create_label("Actions", 242),
        },
        padding  = { 0 },
        border   = false,
    }
    children[#children + 1] = header

    local shown_count = math.min(#lights, MAX_LIGHTS_IN_WINDOW)
    local row_children = {}
    for i = 1, shown_count do
        local light = lights[i]
        light.row_label = create_label(row_label_text(light), 230)
        light.value_label = create_label(format_power(light.current_power), 70)

        light.slider = create_slider(light.current_power, slider_max_for_power(light.current_power), function(comp, evt)
            select_panel_row(light)
            apply_power(light, get_component_value(comp, evt, light.current_power))
        end)

        local off_button = create_button("Off", 58, function()
            select_panel_row(light)
            set_light_off(light)
        end)

        local reset_button = create_button("Reset", 62, function()
            select_panel_row(light)
            reset_light(light)
        end)

        local go_button = create_button("Go", 42, function()
            select_panel_row(light)
            locate_light(light)
        end)

        local delete_button = create_button("Delete", 72, function()
            select_panel_row(light)
            mark_file_node_deleted(light)
        end)

        local action_group = octane.gui.create
        {
            type     = octane.gui.componentType.GROUP,
            text     = "",
            rows     = 1,
            cols     = 4,
            children = { go_button, off_button, reset_button, delete_button },
            padding  = { 0 },
            border   = false,
        }

        local row = octane.gui.create
        {
            type     = octane.gui.componentType.GROUP,
            text     = "",
            rows     = 1,
            cols     = 5,
            children = {
                light.row_label,
                light.slider,
                light.value_label,
                create_light_id_control(light),
                action_group,
            },
            padding  = { 0 },
            border   = false,
        }

        row_children[#row_children + 1] = row
    end

    local rows_group = octane.gui.create
    {
        type     = octane.gui.componentType.GROUP,
        text     = "",
        rows     = #row_children,
        cols     = 1,
        children = row_children,
        padding  = { 0 },
        border   = false,
    }
    children[#children + 1] = create_scrollable_row_area(rows_group)

    if #lights > shown_count then
        children[#children + 1] = create_label(
            "Showing first " .. tostring(shown_count) .. " of " .. tostring(#lights) .. " lights.",
            420
        )
    end

    local global_slider
    global_slider = create_slider(0, max_visible_power(lights, shown_count), function(comp, evt)
        local power = get_component_value(comp, evt, 0)
        for i = 1, shown_count do
            local light = lights[i]
            apply_power(light, power)
            if light.slider then
                update_component(light.slider, { value = power })
            end
        end
    end)

    local all_off_button = create_button("All Off", 82, function()
        for i = 1, shown_count do
            set_light_off(lights[i])
        end
        update_component(global_slider, { value = 0 })
    end)

    local reset_all_button = create_button("Reset All", 92, function()
        for i = 1, shown_count do
            reset_light(lights[i])
        end
        update_component(global_slider, { value = 0 })
    end)

    local apply_reload_button = create_button("Apply+Render", 118, function()
        if write_scene_lines() then
            print("Scene changes written.")
            reload_scene()
        end
    end)

    local global_group = octane.gui.create
    {
        type     = octane.gui.componentType.GROUP,
        text     = "Global",
        rows     = 1,
        cols     = has_file_backend and 5 or 4,
        children = has_file_backend and {
            create_label("Set all visible powers", 210),
            global_slider,
            all_off_button,
            reset_all_button,
            apply_reload_button,
        } or {
            create_label("Set all visible powers", 210),
            global_slider,
            all_off_button,
            reset_all_button,
        },
        padding  = { 2 },
        inset    = { 3 },
    }
    children[#children + 1] = global_group

    local layout = octane.gui.create
    {
        type     = octane.gui.componentType.GROUP,
        text     = "",
        rows     = #children,
        cols     = 1,
        children = children,
        padding  = { 1 },
        border   = false,
    }

    local props = layout:getProperties()
    local window = octane.gui.create
    {
        type     = octane.gui.componentType.WINDOW,
        width    = props.width,
        height   = props.height,
        children = { layout },
        text     = "Light Control Panel",
    }

    window:showWindow()
end

local function run()
    print("=== light_control_panel.lua " .. SCRIPT_VERSION .. " ===")

    if not octane or not octane.gui then
        print("Error: octane.gui API is not available. Run this inside Octane Standalone.")
        return
    end

    local lights, err = collect_lights()
    if not lights then
        print("Error: " .. tostring(err))
        return
    end

    if #lights == 0 then
        print("No nodes with a controllable 'power' pin were found.")
        print("If your lights are controlled by texture pins or a daylight environment, use the node inspector/API browser to identify the relevant pin names.")
        return
    end

    build_window(lights)
end

run()
