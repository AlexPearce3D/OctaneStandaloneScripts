-- Transform Value Offset Tool
-- Offsets selected NT_TRANSFORM_VALUE nodes along X, Y, or Z axis
-- Supports flip (reverse order), start position, and spacing control
-- Must be run from a Script Node inside a node graph (not from Scripting tab)
-- @author      Alex Pearce
-- @version     0.1

-- === CONFIGURABLE OPTIONS ===
local spacing = 41.79         -- Distance between nodes
local flip = false         -- true = reverse order
local axis = "z"           -- "x", "y", or "z"
local startX = 0           -- Starting X position
local startY = 0           -- Starting Y position
local startZ = 0           -- Starting Z position
-- ============================

local selection = octane.project.getSelection()
local nodes = {}

-- Collect valid Transform Value nodes with current translation
for _, node in pairs(selection) do
    if node and node.type == octane.NT_TRANSFORM_VALUE then
        local t = node:getAttribute(octane.A_TRANSLATION) or {0, 0, 0}
        table.insert(nodes, { node = node, x = t[1], y = t[2], z = t[3] })
    else
        print("Skipping non-Transform Value node")
    end
end

-- Sort by selected axis position
table.sort(nodes, function(a, b)
    if axis == "x" then return a.x < b.x
    elseif axis == "y" then return a.y < b.y
    elseif axis == "z" then return a.z < b.z
    end
end)

-- Apply offsets
local total = #nodes
for i, item in ipairs(nodes) do
    local index = flip and (total - i) or (i - 1)
    local newX = (axis == "x") and (startX + index * spacing) or item.x
    local newY = (axis == "y") and (startY + index * spacing) or item.y
    local newZ = (axis == "z") and (startZ + index * spacing) or item.z

    item.node:setAttribute(octane.A_TRANSLATION, { newX, newY, newZ })
end

print("Offset " .. total .. " Transform Value nodes along '" .. axis .. "' axis with flip = " .. tostring(flip))