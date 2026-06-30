-- Add a unique number to the end of selected node names in Octane Render
-- Prevents renaming nodes that already have a numeric suffix and avoids duplicates
-- @version 0.1

-- Get the selected nodes
local selection = octane.project.getSelection()

-- Check if any nodes are selected
if #selection == 0 then
    print("No nodes selected. Please select nodes to rename.")
else
    -- Collect all existing numeric suffixes in the selection
    local existingNumbers = {}

    for _, node in ipairs(selection) do
        -- Find existing numeric suffix (_0001, _2345, etc.)
        local suffix = string.match(node.name, "_(%d%d%d%d)$")
        if suffix then
            existingNumbers[tonumber(suffix)] = true  -- Mark this number as taken
        end
    end

    -- Function to find the next available number
    local function getNextAvailableNumber()
        local number = 1
        while existingNumbers[number] do
            number = number + 1
        end
        existingNumbers[number] = true  -- Reserve this number
        return number
    end

    -- Sort the selection for consistent numbering
    table.sort(selection, function(a, b) return a.name < b.name end)

    -- Iterate through the selected nodes and rename them
    for _, node in ipairs(selection) do
        -- Skip nodes that already have a numeric suffix
        if not string.match(node.name, "_%d%d%d%d$") then
            -- Get the next available number
            local uniqueNumber = string.format("%04d", getNextAvailableNumber())

            -- Generate the new name
            local newName = node.name .. "_" .. uniqueNumber

            -- Rename the node
            node.name = newName

            print("Renamed node to: " .. newName)
        else
            print("Skipped node (already numbered): " .. node.name)
        end
    end

    print("All eligible selected nodes have been renamed without duplicates.")
end
