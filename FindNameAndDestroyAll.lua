-- Search term to match node names
local searchTerm = "glass"  -- 🔍 Change this term as needed

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

-- Collect all nodes to delete first
local nodesToDelete = {}
local selection = octane.project.getSelection()

for _, node in pairs(selection) do
    if node and isMaterialNode(node.type) then
        local nodeName = string.lower(node.name)  -- Case-insensitive search
        if string.find(nodeName, string.lower(searchTerm)) then  -- Check if any part of the name contains the search term
            print("Found node to delete with '" .. searchTerm .. "': " .. tostring(node.name))
            table.insert(nodesToDelete, node)  -- Add node to deletion list
        end
    end
end

-- Now safely delete the collected nodes
for _, node in pairs(nodesToDelete) do
    if node then  -- Double-check the node is valid
        print("Deleting node: " .. tostring(node.name))
        octane.node.destroy(node)
    end
end
