-- Change the Power of selected Emissive nodes that match a search term
-- @author      Alex Pearce
-- @shortcut    
-- @version     0.1

-- 🔧 Configurable search term to filter nodes by name
local searchTerm = ""  -- Change this to any term to filter node names

-- Desired power value for emissive nodes
local Power = 0

-- Get the currently selected nodes in the project
local selection = octane.project.getSelection()

for k in pairs(selection) do
    local node = selection[k]
    
    if node ~= nil and (node.type == octane.NT_EMIS_BLACKBODY or node.type == octane.NT_EMIS_TEXTURE) then
        local nodeName = string.lower(node.name)  -- Case-insensitive search

        -- Check if the node's name contains the search term
        if string.find(nodeName, string.lower(searchTerm)) then
            print("Updating power for node: " .. tostring(node.name))
            node:setPinValue(octane.P_POWER, Power, true)
        else
            print("Node '" .. node.name .. "' does not match the search term '" .. searchTerm .. "'")
        end
    else
        print("Please select only Emission nodes.")
    end
end