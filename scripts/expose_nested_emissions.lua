-- expose_nested_emissions.lua v0.4.07
-- Expose nested Octane emission nodes to their parent graphs.
--
-- Run from Octane's Lua editor while a project is open, or pass an .ocs path
-- when running with Octane --script. By default this writes in place after
-- creating a backup.
--
-- What it does:
--   1. Finds material/light pins named "emission" inside nested node graphs.
--   2. Reads the connected Texture emission node's power value.
--   3. Adds a Float value node to the parent graph.
--   4. Adds a Float input linker inside the nested graph.
--   5. Rewires only the emission node's power pin through that input linker.
--
-- Set WRITE_IN_PLACE=false if you want to dry-run without modifying the scene.

local WRITE_IN_PLACE = true
local RELOAD_AFTER_WRITE = true
local BACKUP_EXT = ".exposed-emissions.bak"
local SCRIPT_VERSION = "v0.4.07"

-- If Octane exposes octane.PT_FLOAT, the script uses that. If your build
-- does not expose the constant, the known fallback is PT_FLOAT = 2.
local FLOAT_PIN_TYPE_OVERRIDE = nil

local SCENE_FILE = nil
if arg and arg[1] and arg[1] ~= "" then
    SCENE_FILE = arg[1]
end
if arg then
    for i = 2, #arg do
        local value = tostring(arg[i] or "")
        if value == "--write" then
            WRITE_IN_PLACE = true
        elseif value == "--dry-run" then
            WRITE_IN_PLACE = false
        else
            local pin_type = value:match("^%-%-pin%-type=(%d+)$")
            if pin_type then
                FLOAT_PIN_TYPE_OVERRIDE = tonumber(pin_type)
            end
        end
    end
end

local INPUT_LINKER_NODE_BASE = 20000
local FLOAT_VALUE_NODE_TYPE = 6
local MULTIPLY_TEXTURE_NODE_TYPE = 39
local FLOAT_PIN_TYPE_FALLBACK = 2
local EMISSION_NODE_TYPES = {
    ["54"] = true, -- Texture emission in the scenes inspected so far.
}

local DIAGNOSTIC_NAME_FRAGMENTS = {
    "KB3D_CBP_AtlasHoloSignal",
    "LogoEmission",
}

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

local function xml_escape(s)
    s = tostring(s or "")
    s = s:gsub("&", "&amp;")
    s = s:gsub('"', "&quot;")
    s = s:gsub("<", "&lt;")
    s = s:gsub(">", "&gt;")
    return s
end

local function first_number_text(value)
    local token = tostring(value or ""):match("([%+%-]?%d+%.?%d*[eE]?[%+%-]?%d*)")
    return token or "1"
end

local function normalize_float_attr_value(value, attr_type)
    local n = first_number_text(value)
    if tostring(attr_type or "") == "9" then
        return n .. " 0 0 0"
    end
    return n .. " 0 0"
end

local function sorted_pin_names(node)
    local names = {}
    for name, _ in pairs((node and node.pins) or {}) do
        names[#names + 1] = tostring(name)
    end
    table.sort(names)
    return names
end

local function pin_summary(pin)
    if not pin then
        return "missing"
    end
    local parts = {}
    if pin.connect and pin.connect ~= "" then
        parts[#parts + 1] = "connect=" .. tostring(pin.connect)
    end
    if pin.dynamicType and pin.dynamicType ~= "" then
        parts[#parts + 1] = "dynamicType=" .. tostring(pin.dynamicType)
    end
    if pin.inline_node_ids and #pin.inline_node_ids > 0 then
        parts[#parts + 1] = "inline=" .. table.concat(pin.inline_node_ids, ",")
    end
    if #parts == 0 then
        return "empty"
    end
    return table.concat(parts, " ")
end

local function candidate_matches_diagnostic(candidate, label)
    local source = candidate and candidate.source_node
    local owner = candidate and candidate.owner
    local haystack = table.concat({
        tostring(label or ""),
        tostring(source and source.name or ""),
        tostring(owner and owner.name or ""),
        tostring(candidate and candidate.graph and candidate.graph.name or ""),
    }, " | ")
    for _, fragment in ipairs(DIAGNOSTIC_NAME_FRAGMENTS) do
        if haystack:find(fragment, 1, true) then
            return true
        end
    end
    return false
end

local function print_candidate_diagnostic(candidate, label, reason)
    local source = candidate and candidate.source_node
    local owner = candidate and candidate.owner
    print("DIAG " .. tostring(reason or "candidate") .. ": " .. tostring(label))
    print("  owner: " .. tostring(owner and owner.name or "") .. " [" .. tostring(owner and owner.type or "") .. "] id " .. tostring(owner and owner.id or ""))
    print("  source: " .. tostring(source and source.name or "") .. " [" .. tostring(source and source.type or "") .. "] id " .. tostring(source and source.id or ""))
    local pin_names = sorted_pin_names(source)
    if #pin_names == 0 then
        print("  source pins: (none parsed)")
    else
        print("  source pins: " .. table.concat(pin_names, ", "))
        for _, pin_name in ipairs(pin_names) do
            print("    " .. pin_name .. ": " .. pin_summary(source.pins[pin_name]))
        end
    end
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

local function is_self_closing_tag(trimmed)
    return trimmed:match("/%s*>%s*$") ~= nil
end

local function tag_indent(line)
    return line:match("^(%s*)") or ""
end

local function detect_current_scene_path()
    if SCENE_FILE and SCENE_FILE ~= "" then
        return SCENE_FILE, "arg[1]"
    end

    if octane and octane.project and type(octane.project.getCurrentProject) == "function" then
        local ok, ret = pcall(octane.project.getCurrentProject)
        if ok and type(ret) == "string" and ret ~= "" and ret:match("%.ocs$") then
            return ret, "octane.project.getCurrentProject"
        end
    end

    if octane and octane.help and octane.project and type(octane.help.functions) == "function" then
        local ok, funcs = pcall(octane.help.functions, "project")
        if ok and type(funcs) == "table" then
            for _, name in ipairs(funcs) do
                local fn = octane.project[name]
                if type(fn) == "function" then
                    local ok2, ret = pcall(fn)
                    if ok2 and type(ret) == "string" and ret ~= "" and ret:match("%.ocs$") then
                        return ret, "octane.project." .. tostring(name)
                    end
                end
            end
        end
    end

    return nil, "could not detect current .ocs path"
end

local function float_input_linker_type()
    if FLOAT_PIN_TYPE_OVERRIDE then
        return INPUT_LINKER_NODE_BASE + FLOAT_PIN_TYPE_OVERRIDE, "override"
    end
    if octane and type(octane.PT_FLOAT) == "number" then
        return INPUT_LINKER_NODE_BASE + octane.PT_FLOAT, "octane.PT_FLOAT"
    end
    return INPUT_LINKER_NODE_BASE + FLOAT_PIN_TYPE_FALLBACK, "fallback PT_FLOAT=2"
end

local function print_pin_type_constants()
    if not octane then
        return
    end
    print("Available octane.PT_* constants:")
    local names = {}
    for k, v in pairs(octane) do
        if type(k) == "string" and k:match("^PT_") and type(v) == "number" then
            names[#names + 1] = k
        end
    end
    table.sort(names)
    for _, name in ipairs(names) do
        print("  " .. name .. " = " .. tostring(octane[name]))
    end
end

local function replace_or_add_attr(line, attr_name, value)
    local escaped = xml_escape(value)
    local pat = "(" .. attr_name .. "%s*=%s*)(['\"])(.-)(%2)"
    local replaced = false
    local out = line:gsub(pat, function(prefix, quote, _, close_quote)
        replaced = true
        return prefix .. quote .. escaped .. close_quote
    end, 1)
    if replaced then
        return out
    end
    if out:match("/%s*>%s*$") then
        return out:gsub("%s*/%s*>%s*$", " " .. attr_name .. "=\"" .. escaped .. "\" />", 1)
    end
    return out:gsub("%s*>%s*$", " " .. attr_name .. "=\"" .. escaped .. "\">", 1)
end

local function replace_connect_attr(line, new_id)
    if line:find("connect%s*=") then
        return line:gsub("(connect%s*=%s*)(['\"])(.-)(%2)", "%1%2" .. tostring(new_id) .. "%4", 1)
    end
    if line:match("/%s*>%s*$") then
        return line:gsub("%s*/%s*>%s*$", " connect=\"" .. tostring(new_id) .. "\" />", 1)
    end
    return line:gsub("%s*>%s*$", " connect=\"" .. tostring(new_id) .. "\">", 1)
end

local function parse_scene(lines)
    local graph_stack = {}
    local node_stack = {}
    local pin_stack = {}

    local graphs = {}
    local nodes_by_id = {}
    local candidates = {}
    local candidate_keys = {}
    local emission_pins = {}
    local forward_resolved_candidates = 0
    local max_id = 0

    local function note_id(id)
        local n = tonumber(id)
        if n and n > max_id then
            max_id = n
        end
    end

    local function add_candidate(pin, is_forward_resolve)
        local graph = pin.graph
        if not graph or not graph.parent then
            return
        end

        local source_node = nil
        if pin.connect and pin.connect ~= "" then
            source_node = nodes_by_id[tostring(pin.connect)]
        elseif pin.inline_node_ids and #pin.inline_node_ids > 0 then
            source_node = nodes_by_id[tostring(pin.inline_node_ids[1])]
        end

        if not source_node then
            return
        end
        if source_node.type and tostring(source_node.type):match("^200%d+$") then
            return
        end
        if not EMISSION_NODE_TYPES[tostring(source_node.type or "")] then
            return
        end
        if source_node.graph ~= graph then
            return
        end

        local key = tostring(graph.id) .. ":" .. tostring(pin.owner and pin.owner.id or "") .. ":" .. tostring(source_node.id)
        if candidate_keys[key] then
            return
        end
        candidate_keys[key] = true
        if is_forward_resolve then
            forward_resolved_candidates = forward_resolved_candidates + 1
        end

        candidates[#candidates + 1] = {
            pin = pin,
            graph = graph,
            parent_graph = graph.parent,
            owner = pin.owner,
            source_node = source_node,
        }
    end

    for i, line in ipairs(lines) do
        local trimmed = line:match("^%s*(.-)%s*$")

        if trimmed:match("^<graph[%s>]") then
            local attrs = parse_attrs(trimmed)
            local graph = {
                id = attrs.id or "",
                type = attrs.type or "",
                name = attrs.name or "",
                position = attrs.position or "",
                start = i,
                parent = top(graph_stack),
            }
            note_id(graph.id)
            graphs[#graphs + 1] = graph
            push(graph_stack, graph)
            if is_self_closing_tag(trimmed) then
                graph["end"] = i
                pop(graph_stack)
            end
        elseif trimmed:match("^</graph>") then
            local graph = pop(graph_stack)
            if graph then
                graph["end"] = i
            end
        elseif trimmed:match("^<node[%s>]") then
            local attrs = parse_attrs(trimmed)
            local node = {
                id = attrs.id or "",
                type = attrs.type or "",
                name = attrs.name or "",
                position = attrs.position or "",
                start = i,
                graph = top(graph_stack),
                parent_node = top(node_stack),
                pins = {},
                attrs = {},
            }
            note_id(node.id)
            if node.id ~= "" then
                nodes_by_id[tostring(node.id)] = node
            end
            local current_pin = top(pin_stack)
            if current_pin then
                current_pin.inline_node_ids[#current_pin.inline_node_ids + 1] = node.id
            end
            push(node_stack, node)
            if is_self_closing_tag(trimmed) then
                node["end"] = i
                pop(node_stack)
            end
        elseif trimmed:match("^</node>") then
            local node = pop(node_stack)
            if node then
                node["end"] = i
            end
        elseif trimmed:match("^<pin[%s>]") then
            local attrs = parse_attrs(trimmed)
            local pin = {
                name = attrs.name or "",
                connect = attrs.connect,
                dynamicType = attrs.dynamicType,
                start = i,
                ["end"] = i,
                graph = top(graph_stack),
                owner = top(node_stack),
                inline_node_ids = {},
            }
            if pin.owner and pin.name ~= "" then
                pin.owner.pins[pin.name] = pin
            end
            if is_self_closing_tag(trimmed) then
                if pin.name == "emission" then
                    emission_pins[#emission_pins + 1] = pin
                    add_candidate(pin)
                end
            else
                push(pin_stack, pin)
            end
        elseif trimmed:match("^<attr[%s>]") then
            local attrs = parse_attrs(trimmed)
            local node = top(node_stack)
            if node and attrs.name then
                node.attrs[attrs.name] = {
                    name = attrs.name,
                    type = attrs.type or "",
                    value = trimmed:match(">(.-)</attr>") or "",
                    line = i,
                }
            end
        elseif trimmed:match("^</pin>") then
            local pin = pop(pin_stack)
            if pin then
                pin["end"] = i
                if pin.name == "emission" then
                    emission_pins[#emission_pins + 1] = pin
                    add_candidate(pin)
                end
            end
        end
    end

    for _, pin in ipairs(emission_pins) do
        add_candidate(pin, true)
    end

    return {
        graphs = graphs,
        nodes_by_id = nodes_by_id,
        candidates = candidates,
        forward_resolved_candidates = forward_resolved_candidates,
        max_id = max_id,
    }
end

local function collect_ids_in_block(lines, start_line, end_line)
    local ids = {}
    for i = start_line, end_line do
        local id = lines[i]:match("<node%s+[^>]-id%s*=%s*['\"](.-)['\"]")
        if id then
            ids[tostring(id)] = true
        end
    end
    return ids
end

local function block_has_external_connect(lines, start_line, end_line, ids_in_block)
    for i = start_line, end_line do
        for _, id in lines[i]:gmatch("connect%s*=%s*(['\"])(.-)%1") do
            if id and id ~= "" and not ids_in_block[tostring(id)] then
                return true, id, i
            end
        end
    end
    return false, nil, nil
end

local function collect_connect_ids_in_block(lines, start_line, end_line)
    local ids = {}
    for i = start_line, end_line do
        for _, id in lines[i]:gmatch("connect%s*=%s*(['\"])(.-)%1") do
            if id and id ~= "" then
                ids[#ids + 1] = tostring(id)
            end
        end
    end
    return ids
end

local function build_copy_bundle(lines, source_node, source_graph, nodes_by_id)
    local roots = {}
    local root_by_id = {}
    local included_ids = {}
    local queue = { source_node }
    local queue_index = 1

    while queue_index <= #queue do
        local node = queue[queue_index]
        queue_index = queue_index + 1

        if not root_by_id[tostring(node.id)] then
            if node.graph ~= source_graph then
                return nil, "dependency " .. tostring(node.id) .. " is not in the same graph"
            end
            if node ~= source_node and node.parent_node then
                return nil, "dependency " .. tostring(node.id) .. " is nested inside another node"
            end
            if not node["end"] then
                return nil, "dependency " .. tostring(node.id) .. " has an incomplete XML block"
            end

            root_by_id[tostring(node.id)] = true
            roots[#roots + 1] = node

            local block_ids = collect_ids_in_block(lines, node.start, node["end"])
            for id, _ in pairs(block_ids) do
                included_ids[tostring(id)] = true
            end

            local connect_ids = collect_connect_ids_in_block(lines, node.start, node["end"])
            for _, connect_id in ipairs(connect_ids) do
                if not included_ids[tostring(connect_id)] and not root_by_id[tostring(connect_id)] then
                    local dep = nodes_by_id[tostring(connect_id)]
                    if not dep then
                        return nil, "connects to missing node " .. tostring(connect_id)
                    end
                    if dep.graph ~= source_graph then
                        return nil, "connects outside source graph to " .. tostring(connect_id)
                    end
                    queue[#queue + 1] = dep
                end
            end
        end
    end

    -- Recompute now that every dependency root has been visited.
    included_ids = {}
    for _, node in ipairs(roots) do
        local block_ids = collect_ids_in_block(lines, node.start, node["end"])
        for id, _ in pairs(block_ids) do
            included_ids[tostring(id)] = true
        end
    end

    for _, node in ipairs(roots) do
        local connect_ids = collect_connect_ids_in_block(lines, node.start, node["end"])
        for _, connect_id in ipairs(connect_ids) do
            if not included_ids[tostring(connect_id)] then
                return nil, "connects outside copied bundle to " .. tostring(connect_id)
            end
        end
    end

    return {
        roots = roots,
        ids = included_ids,
    }
end

local function remap_node_block(lines, source_node, id_map, new_top_name, x, y)
    local out = {}
    for i = source_node.start, source_node["end"] do
        local line = lines[i]
        line = line:gsub("(<node%s+[^>]-id%s*=%s*['\"])(.-)(['\"])", function(prefix, id, suffix)
            return prefix .. tostring(id_map[tostring(id)] or id) .. suffix
        end)
        line = line:gsub("(connect%s*=%s*['\"])(.-)(['\"])", function(prefix, id, suffix)
            return prefix .. tostring(id_map[tostring(id)] or id) .. suffix
        end)
        if new_top_name and i == source_node.start then
            line = replace_or_add_attr(line, "name", new_top_name)
            line = replace_or_add_attr(line, "position", string.format("%.1f %.1f", x, y))
        end
        out[#out + 1] = line
    end
    return out
end

local function short_label(candidate)
    local owner = candidate.owner
    local source = candidate.source_node
    local graph_name = candidate.graph.name or ""
    local owner_name = owner and owner.name or ""
    local source_name = source and source.name or ""

    local base = owner_name
    if base == "" or base == "Diffuse material" or base == "Glossy material" then
        base = source_name
    end
    if base == "" or base == "Texture emission" then
        base = "Emission " .. tostring(source and source.id or "")
    end
    if graph_name ~= "" then
        return graph_name .. " / " .. base
    end
    return base
end

local function path_label(candidate)
    local names = {}
    local graph = candidate.graph
    while graph do
        if graph.name and graph.name ~= "" and graph.name ~= "Scene" then
            table.insert(names, 1, graph.name)
        end
        graph = graph.parent
    end
    local owner = candidate.owner
    local source = candidate.source_node
    local owner_name = owner and owner.name or ""
    local source_name = source and source.name or ""
    local label = owner_name
    if label == "" or label == "Diffuse material" or label == "Glossy material" then
        label = source_name
    end
    if label == "" or label == "Texture emission" then
        label = "Emission " .. tostring(source and source.id or "")
    end
    if #names == 0 then
        return label
    end
    return table.concat(names, " / ") .. " / " .. label
end

local function clean_exposure_name(candidate)
    local source = candidate.source_node
    local source_name = source and source.name or ""
    local owner = candidate.owner
    local owner_name = owner and owner.name or ""
    if source_name:lower():match("^wp") or owner_name:lower():match("^wp") then
        return "wP Parallax Planes Power"
    end
    local base = source_name
    if base == "" or base == "Texture emission" then
        base = owner_name
    end
    if base == "" or base == "Diffuse material" or base == "Glossy material" then
        base = "Emission " .. tostring(source and source.id or "")
    end
    if not base:lower():match("power") then
        base = base .. " Power"
    end
    return base
end

local function float_value_from_node(node)
    if not node then
        return nil, "missing float node"
    end
    if tostring(node.type or "") ~= tostring(FLOAT_VALUE_NODE_TYPE) then
        return nil, "power source node is type " .. tostring(node.type) .. ", not Float value"
    end
    local attr = node.attrs and node.attrs.value
    if not attr or attr.value == nil or attr.value == "" then
        return nil, "Float value node has no value attr"
    end
    local attr_type = attr.type ~= "" and attr.type or "9"
    return {
        value = normalize_float_attr_value(attr.value, attr_type),
        raw_value = attr.value,
        attr_type = attr_type,
    }, nil
end

local function pin_value_from_float_input_linker(linker_node, candidate, nodes_by_id)
    if not linker_node then
        return nil, "missing input linker"
    end

    local input_pin = linker_node.pins and linker_node.pins.input
    if not input_pin then
        local attr = linker_node.attrs and (linker_node.attrs.value or linker_node.attrs.defaultValue)
        local attr_type = attr and attr.type ~= "" and attr.type or "9"
        local raw_value = attr and attr.value ~= "" and attr.value or "1"
        return {
            value = normalize_float_attr_value(raw_value, attr_type),
            raw_value = raw_value,
            attr_type = attr_type,
            assumed = attr == nil,
        }, nil, {
            existing_linker = linker_node,
            missing_input_pin = true,
        }
    end

    if input_pin.connect and input_pin.connect ~= "" then
        local connected = nodes_by_id[tostring(input_pin.connect)]
        if not connected then
            return nil, "input linker connects to missing node " .. tostring(input_pin.connect)
        end
        if connected.graph == candidate.parent_graph then
            local power, err = float_value_from_node(connected)
            if not power then
                return nil, "parent input linker source is not a usable Float value: " .. tostring(err)
            end
            return power, nil, {
                existing_linker = linker_node,
                input_pin = input_pin,
                parent_connected = true,
            }
        end
        local power, err = float_value_from_node(connected)
        if not power then
            return nil, "input linker source is not a usable Float value: " .. tostring(err)
        end
        return power, nil, {
            existing_linker = linker_node,
            input_pin = input_pin,
        }
    end

    if input_pin.inline_node_ids and #input_pin.inline_node_ids > 0 then
        local inline_node = nodes_by_id[tostring(input_pin.inline_node_ids[1])]
        local power, err = float_value_from_node(inline_node)
        if not power then
            return nil, "input linker inline source is not a usable Float value: " .. tostring(err)
        end
        return power, nil, {
            existing_linker = linker_node,
            input_pin = input_pin,
        }
    end

    return nil, "input linker input pin is empty"
end

local function power_value_for_candidate(candidate, nodes_by_id)
    local source = candidate.source_node
    local power_pin = source and source.pins and source.pins.power
    if not power_pin then
        return nil, "emission has no power pin"
    end
    if power_pin.connect and power_pin.connect ~= "" then
        local connected = nodes_by_id[tostring(power_pin.connect)]
        if connected and tostring(connected.type or ""):match("^200%d+$") then
            return pin_value_from_float_input_linker(connected, candidate, nodes_by_id)
        end
        return float_value_from_node(connected)
    end
    if power_pin.inline_node_ids and #power_pin.inline_node_ids > 0 then
        return float_value_from_node(nodes_by_id[tostring(power_pin.inline_node_ids[1])])
    end
    return nil, "power pin is empty"
end

local function efficiency_source_for_candidate(candidate)
    local source = candidate.source_node
    local pin = source and source.pins and source.pins["efficiency or texture"]
    if not pin then
        return nil, "emission has no efficiency or texture pin"
    end
    if pin.connect and pin.connect ~= "" then
        return {
            pin = pin,
            connect_id = tostring(pin.connect),
        }, nil
    end
    return nil, "efficiency or texture is not connected to a standalone node"
end

local function add_exposure_nodes(
    lines,
    operations,
    candidate,
    exposed_name,
    value,
    attr_type,
    linker_type,
    ids,
    layout,
    description
)
    local float_id = ids.float_id
    local linker_id = ids.linker_id
    local float_x = layout.float_x
    local float_y = layout.float_y
    local linker_x = layout.linker_x
    local linker_y = layout.linker_y

    local parent_graph_indent = tag_indent(lines[candidate.parent_graph["end"]])
    local parent_node_indent = parent_graph_indent .. " "
    local float_lines = {
        parent_node_indent .. "<node id=\"" .. tostring(float_id) .. "\" type=\"" .. tostring(FLOAT_VALUE_NODE_TYPE) .. "\" name=\"" .. xml_escape(exposed_name) .. "\" position=\"" .. string.format("%.1f %.1f", float_x, float_y) .. "\">",
        parent_node_indent .. " <attr name=\"value\" type=\"" .. xml_escape(attr_type or "9") .. "\">" .. xml_escape(value) .. "</attr>",
        parent_node_indent .. "</node>",
    }
    operations[#operations + 1] = {
        kind = "insert",
        index = candidate.parent_graph["end"],
        lines = float_lines,
    }

    local graph_indent = tag_indent(lines[candidate.graph["end"]])
    local linker_indent = graph_indent .. " "
    local linker_lines = {
        linker_indent .. "<node id=\"" .. tostring(linker_id) .. "\" type=\"" .. tostring(linker_type) .. "\" name=\"" .. xml_escape(exposed_name) .. "\" position=\"" .. string.format("%.1f %.1f", linker_x, linker_y) .. "\">",
        linker_indent .. " <attr name=\"group\" type=\"10\">Exposed Lights</attr>",
        linker_indent .. " <attr name=\"description\" type=\"10\">" .. xml_escape(description or "Emission exposed by expose_nested_emissions.lua") .. "</attr>",
        linker_indent .. " <pin name=\"input\" connect=\"" .. tostring(float_id) .. "\" />",
        linker_indent .. "</node>",
    }
    operations[#operations + 1] = {
        kind = "insert",
        index = candidate.graph["end"],
        lines = linker_lines,
    }
end

local function parent_float_key(parent_graph, exposed_name)
    return tostring(parent_graph and parent_graph.id or "") .. "\n" .. tostring(exposed_name or "")
end

local function is_grouped_exposure_name(exposed_name)
    return tostring(exposed_name or "") == "wP Parallax Planes Power"
        or tostring(exposed_name or "") == "wP Parallax Planes Intensity"
end

local function get_parent_float(
    lines,
    operations,
    candidate,
    exposed_name,
    value,
    attr_type,
    state
)
    local key = parent_float_key(candidate.parent_graph, exposed_name)
    local existing = state.parent_float_by_name[key]
    if existing then
        return existing.id, true
    end

    state.max_id = state.max_id + 1
    local float_id = state.max_id

    local parent_key = tostring(candidate.parent_graph.id)
    state.parent_counts[parent_key] = (state.parent_counts[parent_key] or 0) + 1
    local parent_count = state.parent_counts[parent_key]
    local float_x = 120 + ((parent_count - 1) % 6) * 260
    local float_y = -300 - math.floor((parent_count - 1) / 6) * 180

    local parent_graph_indent = tag_indent(lines[candidate.parent_graph["end"]])
    local parent_node_indent = parent_graph_indent .. " "
    local float_lines = {
        parent_node_indent .. "<node id=\"" .. tostring(float_id) .. "\" type=\"" .. tostring(FLOAT_VALUE_NODE_TYPE) .. "\" name=\"" .. xml_escape(exposed_name) .. "\" position=\"" .. string.format("%.1f %.1f", float_x, float_y) .. "\">",
        parent_node_indent .. " <attr name=\"value\" type=\"" .. xml_escape(attr_type or "9") .. "\">" .. xml_escape(value) .. "</attr>",
        parent_node_indent .. "</node>",
    }
    operations[#operations + 1] = {
        kind = "insert",
        index = candidate.parent_graph["end"],
        lines = float_lines,
    }

    state.parent_float_by_name[key] = {
        id = float_id,
        name = exposed_name,
    }
    return float_id, false
end

local function next_nested_layout(candidate, state)
    local graph_key = tostring(candidate.graph.id)
    state.graph_counts[graph_key] = (state.graph_counts[graph_key] or 0) + 1
    local graph_count = state.graph_counts[graph_key]
    return {
        linker_x = 100 + ((graph_count - 1) % 6) * 220,
        linker_y = -100 - math.floor((graph_count - 1) / 6) * 140,
    }
end

local function nested_linker_key(candidate, exposed_name, mode)
    return tostring(candidate.graph and candidate.graph.id or "")
        .. "\n" .. tostring(exposed_name or "")
        .. "\n" .. tostring(mode or "")
end

local function get_nested_float_linker(
    lines,
    operations,
    candidate,
    exposed_name,
    float_id,
    linker_type,
    state,
    mode,
    description
)
    local key = nested_linker_key(candidate, exposed_name, mode)
    local can_share = is_grouped_exposure_name(exposed_name)
    if can_share and state.nested_linker_by_name[key] then
        return state.nested_linker_by_name[key].id, true
    end

    state.max_id = state.max_id + 1
    local linker_id = state.max_id
    local nested_layout = next_nested_layout(candidate, state)
    local linker_x = nested_layout.linker_x
    local linker_y = nested_layout.linker_y
    local graph_indent = tag_indent(lines[candidate.graph["end"]])
    local linker_indent = graph_indent .. " "
    local linker_lines = {
        linker_indent .. "<node id=\"" .. tostring(linker_id) .. "\" type=\"" .. tostring(linker_type) .. "\" name=\"" .. xml_escape(exposed_name) .. "\" position=\"" .. string.format("%.1f %.1f", linker_x, linker_y) .. "\">",
        linker_indent .. " <attr name=\"group\" type=\"10\">Exposed Lights</attr>",
        linker_indent .. " <attr name=\"description\" type=\"10\">" .. xml_escape(description or "Emission exposed by expose_nested_emissions.lua") .. "</attr>",
        linker_indent .. " <pin name=\"input\" connect=\"" .. tostring(float_id) .. "\" />",
        linker_indent .. "</node>",
    }
    operations[#operations + 1] = {
        kind = "insert",
        index = candidate.graph["end"],
        lines = linker_lines,
    }

    if can_share then
        state.nested_linker_by_name[key] = {
            id = linker_id,
            name = exposed_name,
        }
    end

    return linker_id, false, { linker_x = linker_x, linker_y = linker_y }
end

local function apply_operations(lines, operations)
    table.sort(operations, function(a, b)
        local ap = a.start or a.index
        local bp = b.start or b.index
        if ap == bp then
            return (a.kind or "") < (b.kind or "")
        end
        return ap > bp
    end)

    for _, op in ipairs(operations) do
        if op.kind == "replace" then
            for _ = op.start, op["end"] do
                table.remove(lines, op.start)
            end
            for i = #op.lines, 1, -1 do
                table.insert(lines, op.start, op.lines[i])
            end
        elseif op.kind == "insert" then
            for i = #op.lines, 1, -1 do
                table.insert(lines, op.index, op.lines[i])
            end
        end
    end
end

local function try_reload(path)
    if not RELOAD_AFTER_WRITE then
        return
    end
    if octane and octane.project and type(octane.project.load) == "function" then
        local ok, err = pcall(octane.project.load, path)
        if ok then
            print("Reloaded scene: " .. path)
        else
            print("Scene written, but reload failed: " .. tostring(err))
        end
    end
end

local function run()
    print("=== expose_nested_emissions.lua " .. SCRIPT_VERSION .. " ===")

    if octane and octane.project and type(octane.project.save) == "function" then
        local ok, err = pcall(octane.project.save)
        if ok then
            print("Auto-saved current scene before scan.")
        else
            print("Warning: auto-save failed; scanning last saved scene.")
            print("  " .. tostring(err))
        end
    end

    local scene_path, path_source = detect_current_scene_path()
    if not scene_path then
        print("Could not find scene path: " .. tostring(path_source))
        return
    end

    local linker_type, linker_source = float_input_linker_type()
    if not linker_type then
        print("Could not determine Float input linker node type: " .. tostring(linker_source))
        print("Dry-run scan can continue, but writing is disabled until FLOAT_PIN_TYPE_OVERRIDE is set.")
        print_pin_type_constants()
    else
        print("Float input linker node type: " .. tostring(linker_type) .. " (" .. tostring(linker_source) .. ")")
    end

    local raw, read_err = read_all(scene_path)
    if not raw then
        print("Could not read scene: " .. tostring(read_err))
        return
    end
    if raw == "" then
        print("Scene file is empty. If this is a cloud placeholder, download/sync it locally first: " .. tostring(scene_path))
        return
    end

    local lines = split_lines(raw)
    local parsed = parse_scene(lines)
    local operations = {}
    local max_id = parsed.max_id
    local planned = 0
    local skipped = 0
    local used_source = {}
    local power_linker_counts = {}
    local parent_counts = {}
    local graph_counts = {}
    local state = {
        max_id = max_id,
        parent_counts = parent_counts,
        graph_counts = graph_counts,
        parent_float_by_name = {},
        nested_linker_by_name = {},
    }

    print("Scene: " .. scene_path)
    print("Emission candidates found: " .. tostring(#parsed.candidates))
    if (parsed.forward_resolved_candidates or 0) > 0 then
        print("Forward-resolved emission candidates: " .. tostring(parsed.forward_resolved_candidates))
    end

    for _, candidate in ipairs(parsed.candidates) do
        local source = candidate.source_node
        local power_pin = source and source.pins and source.pins.power
        if power_pin and power_pin.connect and power_pin.connect ~= "" then
            local connected = parsed.nodes_by_id[tostring(power_pin.connect)]
            if connected and tostring(connected.type or ""):match("^200%d+$") then
                local key = tostring(candidate.graph.id) .. ":" .. tostring(connected.id)
                power_linker_counts[key] = (power_linker_counts[key] or 0) + 1
            end
        end
    end

    for _, candidate in ipairs(parsed.candidates) do
        local source = candidate.source_node
        local source_key = tostring(candidate.graph.id) .. ":" .. tostring(source.id)
        local label = path_label(candidate)

        if used_source[source_key] then
            skipped = skipped + 1
            print("SKIP duplicate source: " .. label .. " (node " .. tostring(source.id) .. ")")
        elseif not linker_type then
            skipped = skipped + 1
            print("SKIP no linker type: " .. label .. " (node " .. tostring(source.id) .. ")")
        elseif not source["end"] then
            skipped = skipped + 1
            print("SKIP incomplete source block: " .. label .. " (node " .. tostring(source.id) .. ")")
        else
            local wants_diag = candidate_matches_diagnostic(candidate, label)
            if wants_diag then
                print_candidate_diagnostic(candidate, label, "target candidate")
            end
            local power, power_err, reuse = power_value_for_candidate(candidate, parsed.nodes_by_id)
            if not power then
                local can_try_efficiency = tostring(power_err):find("no power pin", 1, true) ~= nil
                local efficiency, efficiency_err = nil, nil
                if can_try_efficiency then
                    efficiency, efficiency_err = efficiency_source_for_candidate(candidate)
                end

                if efficiency then
                    used_source[source_key] = true
                    planned = planned + 1

                    local exposed_name = clean_exposure_name(candidate):gsub("%s+[Pp]ower$", " Intensity")
                    local float_id, reused_parent_float = get_parent_float(
                        lines,
                        operations,
                        candidate,
                        exposed_name,
                        normalize_float_attr_value("1", "9"),
                        "9",
                        state
                    )

                    local linker_id, reused_nested_linker, nested_layout = get_nested_float_linker(
                        lines,
                        operations,
                        candidate,
                        exposed_name,
                        float_id,
                        linker_type,
                        state,
                        "efficiency",
                        "Emission efficiency multiplier exposed by expose_nested_emissions.lua"
                    )
                    state.max_id = state.max_id + 1
                    local multiply_id = state.max_id
                    local linker_x = nested_layout and nested_layout.linker_x or 100
                    local linker_y = nested_layout and nested_layout.linker_y or -100

                    local graph_indent = tag_indent(lines[candidate.graph["end"]])
                    local node_indent = graph_indent .. " "
                    local multiply_lines = {
                        node_indent .. "<node id=\"" .. tostring(multiply_id) .. "\" type=\"" .. tostring(MULTIPLY_TEXTURE_NODE_TYPE) .. "\" name=\"" .. xml_escape(exposed_name .. " Multiply") .. "\" position=\"" .. string.format("%.1f %.1f", linker_x + 220, linker_y) .. "\">",
                        node_indent .. " <pin name=\"texture1\" connect=\"" .. tostring(efficiency.connect_id) .. "\" />",
                        node_indent .. " <pin name=\"texture2\" connect=\"" .. tostring(linker_id) .. "\" />",
                        node_indent .. "</node>",
                    }
                    operations[#operations + 1] = {
                        kind = "insert",
                        index = candidate.graph["end"],
                        lines = multiply_lines,
                    }

                    local efficiency_pin = efficiency.pin
                    local pin_indent = tag_indent(lines[efficiency_pin.start])
                    operations[#operations + 1] = {
                        kind = "replace",
                        start = efficiency_pin.start,
                        ["end"] = efficiency_pin["end"],
                        lines = { pin_indent .. "<pin name=\"efficiency or texture\" connect=\"" .. tostring(multiply_id) .. "\" />" },
                    }

                    print("PLAN expose efficiency: " .. label)
                    print("  source emission node " .. tostring(source.id) .. " has no power pin")
                    print("  parent float " .. tostring(float_id) .. " -> nested Float in " .. tostring(linker_id) .. " -> Multiply texture " .. tostring(multiply_id))
                    if reused_parent_float then
                        print("  reused parent float with matching name")
                    end
                    if reused_nested_linker then
                        print("  reused nested Float input with matching name in this subgraph")
                    end
                    print("  original efficiency texture " .. tostring(efficiency.connect_id) .. " is multiplied by exposed intensity")
                else
                    skipped = skipped + 1
                    print("SKIP power expose: " .. label .. " (node " .. tostring(source.id) .. ": " .. tostring(power_err) .. ")")
                    if efficiency_err then
                        print("  efficiency fallback unavailable: " .. tostring(efficiency_err))
                    end
                    if wants_diag or can_try_efficiency then
                        print_candidate_diagnostic(candidate, label, "skipped power candidate")
                    end
                end
            else
                used_source[source_key] = true

                local existing_linker_key = nil
                local existing_linker_is_shared = false
                local reuse_existing_linker = false
                if reuse and reuse.existing_linker then
                    existing_linker_key = tostring(candidate.graph.id) .. ":" .. tostring(reuse.existing_linker.id)
                    existing_linker_is_shared = (power_linker_counts[existing_linker_key] or 0) > 1
                    reuse_existing_linker = (not reuse.parent_connected) and (not reuse.missing_input_pin) and (not existing_linker_is_shared)
                end

                planned = planned + 1

                local exposed_name = clean_exposure_name(candidate)
                local float_id, reused_parent_float = get_parent_float(
                    lines,
                    operations,
                    candidate,
                    exposed_name,
                    power.value,
                    power.attr_type or "9",
                    state
                )

                local linker_id = nil
                local reused_nested_linker = false
                if reuse_existing_linker then
                    linker_id = tonumber(reuse.existing_linker.id)
                end

                if reuse_existing_linker and reuse.input_pin then
                    local input_pin = reuse.input_pin
                    local input_indent = tag_indent(lines[input_pin.start])
                    operations[#operations + 1] = {
                        kind = "replace",
                        start = input_pin.start,
                        ["end"] = input_pin["end"],
                        lines = { input_indent .. "<pin name=\"input\" connect=\"" .. tostring(float_id) .. "\" />" },
                    }
                else
                    linker_id, reused_nested_linker = get_nested_float_linker(
                        lines,
                        operations,
                        candidate,
                        exposed_name,
                        float_id,
                        linker_type,
                        state,
                        "power",
                        "Emission power exposed by expose_nested_emissions.lua"
                    )

                    local power_pin = source.pins.power
                    local pin_indent = tag_indent(lines[power_pin.start])
                    local new_pin_line = pin_indent .. "<pin name=\"power\" connect=\"" .. tostring(linker_id) .. "\" />"

                    operations[#operations + 1] = {
                        kind = "replace",
                        start = power_pin.start,
                        ["end"] = power_pin["end"],
                        lines = { new_pin_line },
                    }
                end

                print("PLAN expose power: " .. label)
                print("  source emission node " .. tostring(source.id) .. " power value " .. tostring(power.value))
                if power.raw_value and tostring(power.raw_value) ~= tostring(power.value) then
                    print("  normalized raw power value " .. tostring(power.raw_value) .. " -> " .. tostring(power.value))
                end
                if reused_parent_float then
                    print("  reused parent float with matching name")
                end
                if reused_nested_linker then
                    print("  reused nested Float input with matching name in this subgraph")
                end
                if reuse_existing_linker then
                    print("  parent float " .. tostring(float_id) .. " -> existing nested Float in " .. tostring(linker_id))
                    if power.assumed then
                        print("  note: input linker had no saved default; using 1 0 0")
                    end
                elseif reuse and reuse.existing_linker then
                    print("  parent float " .. tostring(float_id) .. " -> new nested Float in " .. tostring(linker_id))
                    if reuse.parent_connected then
                        print("  replaced already-parent-connected nested Float " .. tostring(reuse.existing_linker.id) .. " for this emission")
                    elseif reuse.missing_input_pin then
                        print("  replaced incomplete existing nested Float " .. tostring(reuse.existing_linker.id))
                    elseif existing_linker_is_shared then
                        print("  replaced shared existing nested Float " .. tostring(reuse.existing_linker.id) .. " for this emission only")
                    end
                    if power.assumed then
                        print("  note: input linker had no saved default; using 1 0 0")
                    end
                else
                    print("  parent float " .. tostring(float_id) .. " -> nested Float in " .. tostring(linker_id))
                end
            end
        end
    end

    print("")
    print("Planned exposed emission power controls: " .. tostring(planned))
    print("Skipped: " .. tostring(skipped))

    if planned == 0 then
        print("No scene changes needed.")
        return
    end

    if not WRITE_IN_PLACE then
        print("Dry run only. Remove --dry-run or set WRITE_IN_PLACE=true to apply changes.")
        return
    end

    local backup_path = scene_path .. BACKUP_EXT
    local ok_backup, backup_err = write_all(backup_path, raw)
    if not ok_backup then
        print("Could not write backup: " .. tostring(backup_err))
        return
    end

    apply_operations(lines, operations)

    local ok_write, write_err = write_all(scene_path, join_lines(lines))
    if not ok_write then
        print("Could not write scene: " .. tostring(write_err))
        return
    end

    print("Backup written: " .. backup_path)
    print("Scene changes written.")
    try_reload(scene_path)
end

run()
