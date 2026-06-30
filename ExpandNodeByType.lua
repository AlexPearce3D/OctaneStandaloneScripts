-- Define the node type to expand (Change this as needed)
local NODE_TYPE_TO_EXPAND = octane.NT_MAT_LAYER  -- Example: octane.NT_EMISSION, octane.NT_MAT_DIFFUSE

-- Get the current selection
local selection = octane.project.getSelection()

for k, node in pairs(selection) do
    if (node ~= nil) and node.type == NODE_TYPE_TO_EXPAND then
        print("Expanding Node: " .. node.name)
        octane.node.expand(node)  -- Expand the selected node
    else
        print("Please select only nodes of type: " .. tostring(NODE_TYPE_TO_EXPAND))
    end
end
