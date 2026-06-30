-- Set opacity to 0 for any selected material node with the specified search term in its name

local searchTerm = "glass"  -- 🔍 Change this value to search for a different term
local OpacityValue = 1     -- Opacity value to set

-- Corrected list of all material node types to check
local materialTypes = {
    octane.NT_MAT_DIFFUSE,
    octane.NT_MAT_GLOSSY,
    octane.NT_MAT_SPECULAR,
    octane.NT_MAT_MIX,
    octane.NT_MAT_PORTAL,
    octane.NT_MAT_UNIVERSAL,
    octane.NT_MAT_METAL,
    octane.NT_MAT_TOON,
    octane.NT_MAT_COMPOSITE
}

-- Helper function to check if a node type is a material
local function isMaterialNode(nodeType)
    for _, materialType in ipairs(materialTypes) do
        if nodeType == materialType then
            return true
        end
    end
    return false
end

-- Get the currently selected nodes in the project
local selection = octane.project.getSelection()

for _, node in pairs(selection) do
    if node and isMaterialNode(node.type) then
        local nodeName = string.lower(node.name)  -- Case-insensitive search
        if string.find(nodeName, string.lower(searchTerm)) then  -- Check if any part of the name contains the search term
            print("Found selected material node with '" .. searchTerm .. "': " .. tostring(node.name))

            -- Set opacity to 0
            node:setPinValue(octane.P_OPACITY, OpacityValue, true)
            print("Opacity set to 0 for node: " .. tostring(node.name))
        end
    end
end
