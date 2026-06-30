-- Change the Render Layer of selected Object Layer nodes if the camera visibility is off
local selection = octane.project.getSelection()
local RenderLayer3 = 3  -- Set Render Layer to 3
local GeneralVis = 1
local CamVis = true
local ShadowVis = true
local DirtVis = true        -- New: Dirt Visibility
local CurvatureVis = true   -- New: Curvature Visibility

for _, node in pairs(selection) do
    if node and node.type == octane.NT_OBJECTLAYER then
        local camVisibility = node:getPinValue(octane.P_CAMERA_VISIBILITY)
        if not camVisibility then
            print("Camera Visibility is False for node: " .. tostring(node.name))
            
            -- Set visibility pins
            node:setPinValue(octane.P_GENERAL_VISIBILITY, GeneralVis, true)
            node:setPinValue(octane.P_CAMERA_VISIBILITY, CamVis, true)
            node:setPinValue(octane.P_SHADOW_VISIBILITY, ShadowVis, true)
            node:setPinValue(octane.P_LAYER_ID, RenderLayer3, true)
            
            -- New: Set Dirt and Curvature Visibility
            node:setPinValue(octane.P_DIRT_VISIBILITY, DirtVis, true)
            node:setPinValue(octane.P_CURVATURE_VISIBILITY, CurvatureVis, true)

            print("Render Layer set to 3 with Dirt and Curvature Visibility enabled")
        else
            print("Camera Visibility is True for node: " .. tostring(node.name))
        end
    end
end
