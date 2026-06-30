----------------------------------------------------------------------------------------------------
-- Batch render job script (Final Version with Frame Order)
-- @description Batch renders all the linked render targets with frame order options
-- @author      Alex Pearce & Octane Dev Team
-- @version     0.15
-- @script-id   OctaneRender batch render job script
----------------------------------------------------------------------------------------------------

-- Common code for the render scripts. The script is shipped with Octane.
require "octane_render_utils_lua"

local batchRenderJobScript = {}

-- default name for this script
batchRenderJobScript._name = "Batch render job"

local FRAME_MARGIN                   = 0.1
local MAX_RENDER_TARGET_COUNT        = 200
local PRIORITY_FRAME                 = 1
local PRIORITY_RENDET_TARGET         = 2
local ANIM_SETTINGS_LINKERS_START_IX = 3
local ANIM_SETTINGS_COUNT            = 3

local IMAGE_SAVE_FORMATS = octaneRenderUtils.IMAGE_SAVE_FORMATS

batchRenderJobScript.renderTargetsLinkerNodes        = {}
batchRenderJobScript.renderTargetsCopy               = {}
batchRenderJobScript.copyItemsRootGraph              = nil
batchRenderJobScript.staticInputs                    = {}
batchRenderJobScript.output                          = nil
batchRenderJobScript.sceneFrameInterval              = {0, 0}
batchRenderJobScript.staticInputCount                = 0
batchRenderJobScript.lastRenderedResultIx            = 0
batchRenderJobScript.isAnimationSettingsInitialised  = false
batchRenderJobScript.renderPriority                  = 0

-- Utility functions --

local function createAnimationLinkerInfos(sceneFrameInterval)
    local default = sceneFrameInterval[1]
    local infos =
    {
        { type = octane.PT_INT, label = "First frame", defaultNodeType = octane.NT_INT,  
                defaultValue = default, bounds = { sceneFrameInterval[1], sceneFrameInterval[2] }, group = "Animation" },
        { type = octane.PT_INT, label = "Last frame", defaultNodeType = octane.NT_INT,
                defaultValue = default, bounds = { sceneFrameInterval[1], sceneFrameInterval[2] }, group = "Animation" },
        { type = octane.PT_INT, label = "Sub frame", defaultNodeType = octane.NT_INT,
                defaultValue = 1, bounds = { 1, 10 }, group = "Animation" },
    }
    return infos
end

local function calcSceneFrameInterval(rootGraph, fps)
    local interval = rootGraph:getAnimationTimeSpan()
    interval[1] = math.ceil(interval[1] * fps - FRAME_MARGIN)
    interval[2] = math.ceil(interval[2] * fps - FRAME_MARGIN)

    if interval[1] == interval[2] then
        interval[1] = 0
        interval[2] = 1441 -- Default range
    end

    return interval
end

local function frameIntervalAnimated(interval)
    return interval[2] - interval[1] > 0.001
end

-- Create input linkers --

function batchRenderJobScript:createInputLinkers(graph)

    local fps = octane.project.getProjectSettings():getAttribute(octane.A_FRAMES_PER_SECOND)
    self.sceneFrameInterval = calcSceneFrameInterval(graph.rootGraph, fps)

    if self.sceneFrameInterval[1] == self.sceneFrameInterval[2] then
        self.sceneFrameInterval[1] = 0
        self.sceneFrameInterval[2] = 1441
    end

    local inputInfos = {
        { type = octane.PT_INT, label = "Render target count", defaultNodeType = octane.NT_INT,
                defaultValue = 3, bounds = { 0, MAX_RENDER_TARGET_COUNT } },
        { type = octane.PT_ENUM, label = "Render priority", defaultNodeType = octane.NT_ENUM,
                defaultValue = 1, enum ={ "Per frame", "Per render target" }, group = "Animation" },
        { type = octane.PT_ENUM, label = "Frame order", defaultNodeType = octane.NT_ENUM,
                defaultValue = 1,
                enum ={ "Forwards", "Backwards", "Every other (Forwards)", "Every other (Backwards)" },
                group = "Animation" },
        { type = octane.PT_BOOL, label = "Override samples", defaultNodeType = octane.NT_BOOL,
                defaultValue = false, group = "Overrides" },
        { type = octane.PT_INT, label = "Samples/px", defaultNodeType = octane.NT_INT,
                defaultValue = 100, bounds = { 0, 256000 }, group = "Overrides" },
        { type = octane.PT_BOOL, label = "Override resolution", defaultNodeType = octane.NT_BOOL,
                defaultValue = false, group = "Overrides" },
        { type = octane.PT_INT, label = "Resolution", defaultNodeType = octane.NT_IMAGE_RESOLUTION,
                defaultValue = {1024, 512}, group = "Overrides" },
        { type = octane.PT_ENUM, label = "Image format", defaultNodeType = octane.NT_ENUM,
                defaultValue = 1, enum = octaneRenderUtils.IMAGE_SAVE_FORMAT_NAMES, group = "Save" },
        { type = octane.PT_OCIO_COLOR_SPACE, label = "Color space", defaultNodeType = octane.NT_OCIO_COLOR_SPACE,
                group = "Save" },
        { type = octane.PT_OCIO_LOOK, label = "OCIO look", defaultNodeType = octane.NT_OCIO_LOOK,
                group = "Save" },
        { type = octane.PT_BOOL, label = "Force tone mapping", defaultNodeType = octane.NT_BOOL,
                group = "Save" },
        { type = octane.PT_STRING, label = "Output directory", defaultNodeType = octane.NT_DIRECTORY,
                defaultValue = "", group = "Save" },
        { type = octane.PT_STRING, label = "Filename template", defaultNodeType = octane.NT_STRING,
                defaultValue = "%n_%p_%f.%e", group = "Save" },
        { type = octane.PT_BOOL, label = "Skip existing file", defaultNodeType = octane.NT_BOOL,
                defaultValue = false, group = "Save" }
    }

    local hasAnimation = frameIntervalAnimated(self.sceneFrameInterval)
    if hasAnimation then
        local animationLinkerInfos = createAnimationLinkerInfos(self.sceneFrameInterval)
        for _, animLinkerInfo in ipairs(animationLinkerInfos) do
            table.insert(inputInfos, animLinkerInfo)
        end
        self.isAnimationSettingsInitialised = true
    else
        self.isAnimationSettingsInitialised = false
    end

    self.staticInputCount = #inputInfos
    local inputLinkers = graph:setInputLinkers(inputInfos, {1, #inputInfos})

    -- Map static inputs
    local index = 1
    local keys = {
        "renderTargetCount", "renderPriority", "frameOrder", "overrideSamples", "maxSamples",
        "overrideResolution", "resolution", "imageSaveFormat", "colorSpace", "ocioLook",
        "forceToneMapping", "outputDir", "filenameTemplate", "skipExistingFile"
    }

    for _, key in ipairs(keys) do
        self.staticInputs[key] = inputLinkers[index]; index = index + 1
    end

    if hasAnimation then
        self.staticInputs["firstFrame"] = inputLinkers[index]; index = index + 1
        self.staticInputs["lastFrame"] = inputLinkers[index]; index = index + 1
        self.staticInputs["subFrame"] = inputLinkers[index]; index = index + 1
    end

    -- Configure pins
    for _, node in pairs(self.staticInputs) do
        node:configureEmptyPins()
    end
end

-- Output linker --

function batchRenderJobScript:createOutputLinkers(graph)
    graph:setOutputLinkers({
        { type = octane.PT_RENDER_JOB, label = "Render job" }
    })
end

-- Core frame calculation --

function batchRenderJobScript:getRenderTargetIndexAndFrameNumber(mainResultIx)
    local renderPriority = self:getInputValue(self.staticInputs["renderPriority"])
    local frameOrder = self:getInputValue(self.staticInputs["frameOrder"])

    local renderTargetCount = self:getInputValue(self.staticInputs["renderTargetCount"])
    local firstFrame = self:getInputValue(self.staticInputs["firstFrame"]) or 0
    local lastFrame = self:getInputValue(self.staticInputs["lastFrame"]) or 0
    local subFrameIx = self:getInputValue(self.staticInputs["subFrame"]) or 1

    local rtIx, frameIx

    if renderPriority == PRIORITY_FRAME then
        frameIx = firstFrame + math.floor(mainResultIx / renderTargetCount)
        rtIx = mainResultIx % renderTargetCount
    else -- PRIORITY_RENDET_TARGET
        local framesDiff = (lastFrame - firstFrame) + 1
        rtIx = math.floor(mainResultIx / framesDiff)

        if frameOrder == 1 then
            frameIx = (mainResultIx % framesDiff) + firstFrame
        elseif frameOrder == 2 then
            frameIx = lastFrame - (mainResultIx % framesDiff)
        elseif frameOrder == 3 then
            frameIx = firstFrame + (mainResultIx % framesDiff) * 2
        elseif frameOrder == 4 then
            frameIx = lastFrame - (mainResultIx % framesDiff) * 2
        else
            frameIx = firstFrame
        end
    end

    frameIx = math.max(firstFrame, math.min(frameIx, lastFrame))
    return rtIx, frameIx, subFrameIx
end

-- Evaluate --

function batchRenderJobScript:onEvaluate(graph)
    self:checkForRenderTargetCountUpdate(graph)
    self:update(graph)
end

-- Iterate --

function batchRenderJobScript:onIterate(graph, resultIx)
    local totalResultFrames = self:calcTotalResultFrames()
    local validatedResultIx = math.min(resultIx, totalResultFrames)
    self.lastRenderedResultIx = validatedResultIx

    local rtIx, frameIx, subFrameIx = self:getRenderTargetIndexAndFrameNumber(validatedResultIx)
    local renderTargetNode = self.renderTargetsCopy[rtIx + 1]

    if self:getInputValue(self.staticInputs["skipExistingFile"]) then
        if self:isFileExists(graph, renderTargetNode, rtIx, frameIx, subFrameIx) then
            return nil, true
        end
    end

    if renderTargetNode then
        local fps = octane.project.getProjectSettings():getAttribute(octane.A_FRAMES_PER_SECOND)
        self.copyItemsRootGraph:updateTime(octaneRenderUtils.frameToTime(frameIx, fps))
    end

    return renderTargetNode, false
end

-- Save frame --

function batchRenderJobScript:onSaveRenderedFrame(graph)
    local rtIx, frameIx, subFrameIx = self:getRenderTargetIndexAndFrameNumber(self.lastRenderedResultIx)
    local renderTargetNode = self.renderTargetsCopy[rtIx + 1]
    return self:save(graph, renderTargetNode, rtIx, frameIx, subFrameIx)
end

-- Start iteration --

function batchRenderJobScript:onStartIteration(graph)
    octane.render.setRenderRegion({ active = false })
    self.copyItemsRootGraph = octane.nodegraph.createRootGraph("copyItemsRootGraph")
    local renderTargetNodes = {}
    for _, linker in ipairs(self.renderTargetsLinkerNodes) do
        local inputNode = linker:getInputNode(octane.P_INPUT)
        if inputNode then
            table.insert(renderTargetNodes, inputNode)
        end
    end
    self.renderTargetsCopy = self.copyItemsRootGraph:copyFromGraph(graph.rootGraph, renderTargetNodes)
end

-- Finish iteration --

function batchRenderJobScript:onFinishIteration(graph)
    octane.render.clear()
    octane.nodegraph.destroy(self.copyItemsRootGraph)
    self.renderTargetsCopy = {}
end

return batchRenderJobScript