-- Search term to match node names
local searchTerm = "mi_"  -- 🔍 Change this term as needed

-- List of all material node types to check
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
            print("Deleting selected material node with '" .. searchTerm .. "': " .. tostring(node.name))

            -- Proper deletion of the node
            octane.node.destroy(node)
            print("Deleted node: " .. tostring(node.name))
        end
    end
end
