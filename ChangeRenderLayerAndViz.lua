--change the Render Layer of selected Object Layer nodes
local selection = octane.project.getSelection()
local RenderLayer2 = 2
local GeneralVis = 1
local CamVis = true
local ShadowVis = true


for k in pairs(selection) do
    if (selection[k] ~= nil) and selection[k].type == octane.NT_OBJECTLAYER then
        print("Camera Visibility is False")
		selection[k]:setPinValue(octane.P_GENERAL_VISIBILITY, GeneralVis, true)
		selection[k]:setPinValue(octane.P_CAMERA_VISIBILITY, CamVis, true)
		selection[k]:setPinValue(octane.P_SHADOW_VISIBILITY, ShadowVis, true)
		
		--print(selection[k])
        --selection[k]:setPinValue(octane.P_LAYER_ID, RenderLayer2, true)

    else print("Camera Visibility is True")
end
end