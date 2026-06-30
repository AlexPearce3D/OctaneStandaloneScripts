--change the Light ID of selected Emissive nodes
local selection = octane.project.getSelection()
local LightID = 5

for k in pairs(selection) do
    if (selection[k] ~= nil) and selection[k].type == octane.NT_EMIS_BLACKBODY or selection[k].type == octane.NT_EMIS_TEXTURE then
        print(selection[k])
        selection[k]:setPinValue(octane.P_LIGHT_PASS_ID, LightID, true)

    else print("Please select only Emission nodes")
end
end