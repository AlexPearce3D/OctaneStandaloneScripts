-- Read-only Light AOV audit for the currently open Octane project.
--
-- It prints:
-- 1) Light IDs used by scene lights (lightPassId > 0)
-- 2) Light AOV IDs currently enabled
-- 3) Enabled AOV IDs that are unused by any light (should disable)
-- 4) Used Light IDs that are currently not enabled in AOVs (should enable)
--
-- No scene edits. No save/reload.

local SUBTYPE_OFFSET = 1 -- mapping: Light AOV subType = lightPassId + SUBTYPE_OFFSET
local AUTO_SAVE_BEFORE_SCAN = false

local function read_all(path)
    local f, err = io.open(path, "rb")
    if not f then
        return nil, err
    end
    local s = f:read("*a")
    f:close()
    return s
end

local function file_exists(path)
    local f = io.open(path, "rb")
    if f then
        f:close()
        return true
    end
    return false
end

local function split_lines(s)
    local lines = {}
    if s == "" then
        return lines
    end
    s = s:gsub("\r\n", "\n")
    if s:sub(-1) ~= "\n" then
        s = s .. "\n"
    end
    for line in s:gmatch("(.-)\n") do
        lines[#lines + 1] = line
    end
    return lines
end

local function parse_attrs(tag_text)
    local attrs = {}
    for k, _, v in tag_text:gmatch("([%w_:%-]+)%s*=%s*(['\"])(.-)%2") do
        attrs[k] = v
    end
    return attrs
end

local function first_int(value_text)
    if not value_text then
        return nil
    end
    local first = value_text:match("^%s*([%+%-]?[%d%.]+)")
    if not first then
        return nil
    end
    local n = tonumber(first)
    if not n then
        return nil
    end
    return math.floor(n + 0.0000001)
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

local function find_pin_owner_emission(pin_stack)
    for i = #pin_stack, 1, -1 do
        local p = pin_stack[i]
        if p and p.name == "emission" then
            return p.owner
        end
    end
    return nil
end

local function find_nearest_named_node(node_stack)
    for i = #node_stack, 1, -1 do
        local n = node_stack[i]
        if n and n.name and n.name ~= "" then
            return n
        end
    end
    return nil
end

local function find_nearest_aov_node(node_stack)
    for i = #node_stack, 1, -1 do
        local n = node_stack[i]
        if n and n.type == "205" and n.name == "Light AOV" then
            return n
        end
    end
    return nil
end

local function analyze(lines)
    local node_stack = {}
    local pin_stack = {}

    local used_ids = {}
    local lights_by_id = {}
    local enabled_aov_ids = {}
    local special_pass_enabled = {
        sunlight = false,      -- Light AOV subType 0
        ambient_light = false, -- Light AOV subType 1
    }
    local light_entry_by_node = {}

    local function get_or_create_light_entry(owner)
        local light_name = (owner and owner.name ~= "") and owner.name or "<unnamed light>"
        local light_node_id = (owner and tonumber(owner.id)) or -1
        local key = tostring(light_node_id)
        if not light_entry_by_node[key] then
            light_entry_by_node[key] = {
                name = light_name,
                node_id = light_node_id,
                power = nil,
                _id_links = {},
            }
        end
        return light_entry_by_node[key]
    end

    for _, line in ipairs(lines) do
        local trimmed = line:match("^%s*(.-)%s*$")

        if trimmed:match("^</node>") then
            pop(node_stack)
        elseif trimmed:match("^<node[%s>]") then
            local attrs = parse_attrs(trimmed)
            push(node_stack, {
                id = attrs.id or "-1",
                name = attrs.name or "",
                type = attrs.type or "",
            })
        elseif trimmed:match("^</pin>") then
            pop(pin_stack)
        elseif trimmed:match("^<pin[%s>]") then
            local attrs = parse_attrs(trimmed)
            local pin_name = attrs.name or ""
            local owner = nil
            if pin_name == "emission" then
                owner = top(node_stack)
            end
            push(pin_stack, { name = pin_name, owner = owner })
        else
            local attr_name = trimmed:match("^<attr%s+[^>]-name%s*=%s*['\"](.-)['\"][^>]*>")
            if attr_name == "value" then
                local value_text = trimmed:match(">([^<]*)</attr>")
                local int_value = first_int(value_text)
                local pin_top = top(pin_stack)
                local pin_name = pin_top and pin_top.name or ""
                local light_owner = find_pin_owner_emission(pin_stack)
                if not light_owner then
                    light_owner = find_nearest_named_node(node_stack)
                end

                if pin_name == "lightPassId" and int_value and int_value > 0 then
                    used_ids[int_value] = true
                    local light_entry = get_or_create_light_entry(light_owner)
                    lights_by_id[int_value] = lights_by_id[int_value] or {}
                    if not light_entry._id_links[int_value] then
                        table.insert(lights_by_id[int_value], light_entry)
                        light_entry._id_links[int_value] = true
                    end
                elseif pin_name == "power" and light_owner then
                    local light_entry = get_or_create_light_entry(light_owner)
                    light_entry.power = value_text
                end

                local aov_node = find_nearest_aov_node(node_stack)
                if aov_node and aov_node.type == "205" and aov_node.name == "Light AOV" and int_value ~= nil then
                    if pin_name == "subType" then
                        aov_node._subType = int_value
                    elseif pin_name == "enabled" then
                        aov_node._enabled = int_value
                    end
                    if aov_node._subType and aov_node._enabled ~= nil then
                        if aov_node._subType == 0 then
                            special_pass_enabled.sunlight = (aov_node._enabled == 1)
                        elseif aov_node._subType == 1 then
                            special_pass_enabled.ambient_light = (aov_node._enabled == 1)
                        elseif aov_node._enabled == 1 then
                            local pass_id = aov_node._subType - SUBTYPE_OFFSET
                            if pass_id > 0 then
                                enabled_aov_ids[pass_id] = true
                            end
                        end
                    end
                end
            end
        end
    end

    return {
        used_ids = used_ids,
        lights_by_id = lights_by_id,
        enabled_aov_ids = enabled_aov_ids,
        special_pass_enabled = special_pass_enabled,
    }
end

local function sorted_keys(set_like)
    local keys = {}
    for k, v in pairs(set_like) do
        if v then
            keys[#keys + 1] = k
        end
    end
    table.sort(keys)
    return keys
end

local function dedupe_and_sort_lights(rows)
    local has_known = false
    for _, r in ipairs(rows or {}) do
        if r.node_id and r.node_id >= 0 and r.name and r.name ~= "<unnamed light>" then
            has_known = true
            break
        end
    end

    local seen = {}
    local out = {}
    for _, r in ipairs(rows or {}) do
        if has_known and (not r.node_id or r.node_id < 0 or not r.name or r.name == "<unnamed light>") then
            goto continue
        end
        local key = tostring(r.node_id)
        if not seen[key] then
            seen[key] = true
            out[#out + 1] = r
        end
        ::continue::
    end
    table.sort(out, function(a, b)
        if a.name == b.name then
            return a.node_id < b.node_id
        end
        return a.name < b.name
    end)
    return out
end

local function format_id_list(ids)
    if #ids == 0 then
        return "[]"
    end
    return "[" .. table.concat(ids, ", ") .. "]"
end

local function format_name_list(names)
    if #names == 0 then
        return "[]"
    end
    return "[" .. table.concat(names, ", ") .. "]"
end

local function format_power_value(raw_power)
    if not raw_power or raw_power == "" then
        return "unknown"
    end
    local first = tostring(raw_power):match("^%s*([%+%-]?%d+%.?%d*)")
    if first and first ~= "" then
        return first
    end
    return tostring(raw_power)
end

local function detect_daylight_environment(raw_text)
    local low = string.lower(raw_text or "")
    if low:find("daylight environment", 1, true) then
        return true
    end
    -- Fallback heuristics for exported .ocs variants.
    if low:find("daylight", 1, true)
        or low:find("northoffset", 1, true)
        or low:find("turbidity", 1, true)
        or low:find("latitude", 1, true)
        or low:find("longitude", 1, true) then
        return true
    end
    return false
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
        return nil, "Octane API modules missing (octane.help or octane.project)"
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

local function diff_sets(a, b)
    local out = {}
    for k, v in pairs(a) do
        if v and not b[k] then
            out[k] = true
        end
    end
    return out
end

local function union_sets(a, b)
    local out = {}
    for k, v in pairs(a) do
        if v then
            out[k] = true
        end
    end
    for k, v in pairs(b) do
        if v then
            out[k] = true
        end
    end
    return out
end

local function run()
    if AUTO_SAVE_BEFORE_SCAN and octane and octane.project and type(octane.project.save) == "function" then
        local ok_save, save_err = pcall(octane.project.save)
        if ok_save then
            print("Auto-saved current scene before scan.")
        else
            print("Warning: auto-save failed, scan may reflect last saved state only.")
            print("  " .. tostring(save_err))
        end
    end

    local scene_path, path_fn = detect_current_scene_path()
    if not scene_path then
        print("Could not detect current .ocs path.")
        print("Reason: " .. tostring(path_fn))
        return
    end

    if not file_exists(scene_path) then
        print("Current scene path is not readable:")
        print("  " .. tostring(scene_path))
        return
    end

    print("Using current scene path from octane.project." .. tostring(path_fn) .. "():")
    print("  " .. scene_path)

    local raw, err = read_all(scene_path)
    if not raw then
        print("Error reading scene: " .. tostring(err))
        return
    end

    local data = analyze(split_lines(raw))
    local has_daylight_environment = detect_daylight_environment(raw)
    local used_ids = sorted_keys(data.used_ids)
    local enabled_ids = sorted_keys(data.enabled_aov_ids)

    local should_disable = sorted_keys(diff_sets(data.enabled_aov_ids, data.used_ids))
    local should_enable = sorted_keys(diff_sets(data.used_ids, data.enabled_aov_ids))
    local should_enable_special = {}
    if has_daylight_environment then
        if not data.special_pass_enabled.sunlight then
            table.insert(should_enable_special, "Sunlight")
        end
        if not data.special_pass_enabled.ambient_light then
            table.insert(should_enable_special, "Ambient light")
        end
    end

    print("Used lightPassId values: " .. format_id_list(used_ids))
    print("Enabled Light AOV IDs: " .. format_id_list(enabled_ids))
    print("Daylight environment detected: " .. (has_daylight_environment and "yes" or "no"))
    print("Sunlight pass enabled: " .. (data.special_pass_enabled.sunlight and "yes" or "no"))
    print("Ambient light pass enabled: " .. (data.special_pass_enabled.ambient_light and "yes" or "no"))
    print("")
    print("Per-ID audit:")
    local all_ids = sorted_keys(union_sets(data.used_ids, data.enabled_aov_ids))
    if #all_ids == 0 then
        print("  (no Light IDs or enabled Light AOV IDs found)")
    else
        for _, id in ipairs(all_ids) do
            local used = data.used_ids[id] and "yes" or "no"
            local enabled = data.enabled_aov_ids[id] and "yes" or "no"
            local action = "ok"
            if data.used_ids[id] and not data.enabled_aov_ids[id] then
                action = "enable"
            elseif data.enabled_aov_ids[id] and not data.used_ids[id] then
                action = "disable"
            end
            print(string.format("  id %2d | used: %s | aov enabled: %s | action: %s", id, used, enabled, action))
        end
    end

    print("")
    print("Enabled AOV IDs with no matching lights (should disable):")
    if #should_disable == 0 then
        print("  (none)")
    else
        for _, id in ipairs(should_disable) do
            print(string.format("  id %2d", id))
        end
    end

    print("")
    print("Used Light IDs missing enabled AOV (should enable):")
    if #should_enable == 0 then
        print("  (none)")
    else
        for _, id in ipairs(should_enable) do
            local rows = dedupe_and_sort_lights(data.lights_by_id[id] or {})
            if #rows == 0 then
                print(string.format("  id %2d | <unknown light>", id))
            else
                for _, r in ipairs(rows) do
                    local power = format_power_value(r.power)
                    print(string.format("  id %2d | %s (node %d) | power: %s", id, r.name, r.node_id, power))
                end
            end
        end
    end

    print("")
    print("Lights by used ID:")
    if #used_ids == 0 then
        print("  (none)")
    else
        for _, id in ipairs(used_ids) do
            local rows = dedupe_and_sort_lights(data.lights_by_id[id] or {})
            if #rows == 0 then
                print(string.format("  id %2d | <unknown light>", id))
            else
                for _, r in ipairs(rows) do
                    local power = format_power_value(r.power)
                    print(string.format("  id %2d | %s (node %d) | power: %s", id, r.name, r.node_id, power))
                end
            end
        end
    end

    print("")
    print("========================================")
    print("MANUAL ACTIONS")
    print("========================================")
    print("ENABLE : " .. format_id_list(should_enable))
    print("ENABLE SPECIAL: " .. format_name_list(should_enable_special))
    print("DISABLE: " .. format_id_list(should_disable))
    print("========================================")
end

run()
