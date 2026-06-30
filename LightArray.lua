-- Creates an Analytic Sphere Light and 10 Placement nodes spaced along X-axis
-- Works in Scripting tab without relying on getCurrentGraph()
-- @author      Alex Pearce
-- @shortcut    
-- @version     0.1

-- Use the currently visible node graph (this works in Scripting tab)
local graph = octane.nodegraph

-- Safety check
if not graph then
    error("No active node graph found. Please open a node graph before running this script.")
end

-- Create the base Analytic Sphere Light
local light = graph:insertNode(octane.NT_LIGHT_SPHERE)
light:setName("Analytic Sphere Light")
light:setPinValue("emissionMode", octane.EMISSION_MODE_SURFACE)
light:setPinValue("power", 10)

-- Create 10 Placement nodes and instance them
for i = 0, 9 do
    local placement = graph:insertNode(octane.NT_PLACEMENT)
    placement:setName("Placement_" .. tostring(i + 1))
    placement:setPinValue("translation", {i * 20, 0, 0})

    local geoGroup = graph:insertNode(octane.NT_GEO_GROUP)
    geoGroup:setName("Light_Instance_" .. tostring(i + 1))
    geoGroup:connectPin("placement", placement)
    geoGroup:connectPin("objects", light)
end