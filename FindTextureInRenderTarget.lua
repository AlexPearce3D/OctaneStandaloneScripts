--Select a Render Target and find all the texture assets

    local function walk(node, list)
        -- recursive walk
        for i = 1,node:getPinCount() do
            local src = node:getInputNodeIx(i)
            if src ~= nil then walk(src, list) end
        end

        -- see if this node has a filename attribute
        local ok, value = pcall(node.getAttribute, node, "filename")
        if ok then
            table.insert(list, value)
        end
    end

    local list = {}
    walk(octane.project.getSelection()[1], list)
    for k, v in ipairs(list) do
        print(v)
    end