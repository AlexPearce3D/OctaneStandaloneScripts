--change the Render Layer of selected Object Layer nodes to 2
-- @author      Alex Pearce
-- @shortcut    ctrl + 2
-- @version     0.1


local selection = octane.project.getSelection()
local RenderLayer2 = 2

for k in pairs(selection) do
    if (selection[k] ~= nil) and selection[k].type == octane.NT_OBJECTLAYER then
        print(selection[k])
        selection[k]:setPinValue(octane.P_LAYER_ID, RenderLayer2, true)

    else print("Please select only Object Layer nodes")
end
end