--change the Power of selected Emissive nodes
local selection = octane.project.getSelection()
local Power = .1

for k in pairs(selection) do
    if (selection[k] ~= nil) and selection[k].type == octane.NT_EMIS_BLACKBODY or selection[k].type == octane.NT_EMIS_TEXTURE then
        print(selection[k])
        selection[k]:setPinValue(octane.P_POWER, Power, true)

    else print("Please select only Emission nodes")
end
end