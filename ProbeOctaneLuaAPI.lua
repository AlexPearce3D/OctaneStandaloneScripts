-- ProbeOctaneLuaAPI.lua
-- Prints available Octane Lua APIs for script launching and GUI creation.

local function dump_module(name)
    local ok, funcs = pcall(function()
        return octane.help.functions(name)
    end)
    if not ok then
        print("MODULE " .. name .. ": <error>")
        return
    end
    if type(funcs) ~= "table" then
        print("MODULE " .. name .. ": <none>")
        return
    end
    table.sort(funcs)
    print("MODULE " .. name .. ":")
    for _, f in ipairs(funcs) do
        print("  " .. tostring(f))
    end
end

local function dump_table_keys(label, t)
    if type(t) ~= "table" then
        print(label .. ": <not table>")
        return
    end
    local keys = {}
    for k, _ in pairs(t) do
        keys[#keys + 1] = tostring(k)
    end
    table.sort(keys)
    print(label .. ":")
    for _, k in ipairs(keys) do
        print("  " .. k)
    end
end

print("=== OCTANE LUA API PROBE ===")

if not octane then
    print("octane global: missing")
    return
end

if octane.help then
    dump_module("script")
    dump_module("gui")
    dump_module("project")
else
    print("octane.help: missing")
end

if octane.gui then
    dump_table_keys("octane.gui keys", octane.gui)
    dump_table_keys("octane.gui.componentType keys", octane.gui.componentType)
    dump_table_keys("octane.gui.COMPONENT_TYPE keys", octane.gui.COMPONENT_TYPE)
else
    print("octane.gui: missing")
end

if octane.script then
    dump_table_keys("octane.script keys", octane.script)
else
    print("octane.script: missing")
end

print("=== END PROBE ===")
