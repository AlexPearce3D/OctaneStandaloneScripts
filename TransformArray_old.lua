-- Offsets selected Transform Value nodes by +20 units along X (0, 20, 40, ...)
-- Uses A_TRANSLATION attribute directly (not pin) as per API docs
-- @author      Alex Pearce
-- @version     0.1

local selection = octane.project.getSelection()
local spacing = 20
local index = 0

for _, node in pairs(selection) do
    if node and node.type == octane.NT_TRANSFORM_VALUE then
        -- Only modify A_TRANSLATION attribute
        local newTranslation = { index * spacing, 0, 0 }
        node:setAttribute(octane.A_TRANSLATION, newTranslation)
        index = index + 1
    else
        print("Skipping non-Transform Value node")
    end
end

print("Moved " .. index .. " Transform Value nodes.")