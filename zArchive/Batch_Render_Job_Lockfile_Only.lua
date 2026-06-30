----------------------------------------------------------------------------------------------------
-- Batch render job script
--
-- @description Batch renders all the linked render targets
-- @author      Octane Dev Team
-- @version     0.15
-- @script-id   OctaneRender batch render job script

-- Common code for the render scripts. The script is shipped with Octane.
require "octane_render_utils_lua"

local batchRenderJobScript = {}

-- default name for this script
batchRenderJobScript._name = "Batch render job"

local FRAME_MARGIN                   = 0.1
local MAX_RENDER_TARGET_COUNT        = 200
local PRIORITY_FRAME                 = 1
local PRIORITY_RENDET_TARGET         = 2
local ANIM_SETTINGS_LINKERS_START_IX = 2
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


local function renderTargetLinkerInfo(i)
    return {label = "Render target " .. i, type = octane.PT_RENDERTARGET, group = "Render targets"}
end


-- Calculates animation frames of the project
local function calcSceneFrameInterval(rootGraph, fps)
    local interval = rootGraph:getAnimationTimeSpan()
    interval[1] = math.ceil(interval[1] * fps - FRAME_MARGIN);
    interval[2] = math.ceil(interval[2] * fps - FRAME_MARGIN);
    return interval
end


-- Returns true if two frame intervals are equal
local function frameIntervalsEqual(intervalA, intervalB)
    return math.abs(intervalA[1] - intervalB[1]) < 0.001 and math.abs(intervalA[2] - intervalB[2]) < 0.001
end


-- Return true if frame interval is animated (end frame is greater than start frame)
local function frameIntervalAnimated(interval)
    return interval[2] - interval[1] > 0.001
end


-- Returns true if animation frame inputs (lastFrame, firstFrame and subFrame) were added
function batchRenderJobScript:hasAnimationFrameInputs()
    return self.staticInputs["lastFrame"] ~= nil and 
           self.staticInputs["firstFrame"] ~= nil and 
           self.staticInputs["subFrame"] ~= nil
end


-- Clamps the first/last frame input values into the current animation begin/end range
function batchRenderJobScript:clampAnimationFrameInputs()
    if not self:hasAnimationFrameInputs() then
        return
    end

    local firstFrame = self:getInputValue(self.staticInputs["firstFrame"])
    local lastFrame  = self:getInputValue(self.staticInputs["lastFrame"])
    firstFrame = math.min(math.max(firstFrame, self.sceneFrameInterval[1]), self.sceneFrameInterval[2])
    lastFrame = math.min(math.max(lastFrame, self.sceneFrameInterval[1]), self.sceneFrameInterval[2])
    self:setInputValue(self.staticInputs["firstFrame"], firstFrame)
    self:setInputValue(self.staticInputs["lastFrame"], lastFrame)
end


-- returns the active render target count
function batchRenderJobScript:activeRenderTargetCount()

    local activeRenderTargetCount = 0
    for  _, item in ipairs(self.renderTargetsLinkerNodes) do
        if item:getInputNode(octane.P_INPUT) then 
            activeRenderTargetCount = activeRenderTargetCount + 1
        end 
    end
    return activeRenderTargetCount
    
end


-- Calculates total number of frames in this job
function batchRenderJobScript:calcTotalResultFrames()

    local framesDiff = 1
    local subFrame   = 1
    if self:hasAnimationFrameInputs() then
        local firstFrame = self:getInputValue(self.staticInputs["firstFrame"])
        local lastFrame  = self:getInputValue(self.staticInputs["lastFrame"])
    
        framesDiff = (lastFrame - firstFrame) + 1
        subFrame   = self:getInputValue(self.staticInputs["subFrame"])
    end
    
    return framesDiff * self:activeRenderTargetCount() * subFrame
    
end


-- Function to update the initial data to nodes
function batchRenderJobScript:updateInitialDataToNodes()

    self:clampAnimationFrameInputs()
    
    if self:hasAnimationFrameInputs() then
        -- Set the last frame to max value if it's the same as the first frame (which is the default).
        -- So that the script is set to render the whole animation range after it's initialized.
        if math.abs(self:getInputValue(self.staticInputs["lastFrame"]) - self.sceneFrameInterval[1]) < 0.001 then
            self:setInputValue(self.staticInputs["lastFrame"], self.sceneFrameInterval[2])
        end
    end
end


-- Gets render target linker node by index
function batchRenderJobScript:renderTargetLinkerByIx(Ix)

    local count = 0;
    for  _, item in ipairs(self.renderTargetsLinkerNodes) do
        if item:getInputNode(octane.P_INPUT) then
            if count == Ix then  
                return item
            end
            count = count  + 1
        end
    end
    
    return nil
    
end


-- function to get the output directory
function batchRenderJobScript:getOutputDirectory(graph)

    -- checking and using if output folder is overridden from the render job dialog or use the folder from our input linker 
    local outputDirectory = octaneRenderUtils.ternaryOperator(graph:getAttribute(octane.A_OUTPUT_DIRECTORY_OVERRIDE) ~= "",
                                                              graph:getAttribute(octane.A_OUTPUT_DIRECTORY_OVERRIDE),
                                                              self:getInputValue(self.staticInputs["outputDir"]))
    return outputDirectory
end


function batchRenderJobScript:modifyAnimationInputLinkers(graph)

    local inputInfos = createAnimationLinkerInfos(self.sceneFrameInterval)

    assert(ANIM_SETTINGS_COUNT == #inputInfos, "ANIM_SETTINGS_COUNT should be the size of animation inputInfos")
    
    local startRange =  ANIM_SETTINGS_LINKERS_START_IX + 1
    local endRange   =  ANIM_SETTINGS_LINKERS_START_IX + #inputInfos
    range            = {startRange, endRange} 
        
    local inputLinkers = graph:setInputLinkers(inputInfos, range)
    self.staticInputs["firstFrame"] = inputLinkers[1]
    self.staticInputs["lastFrame"]  = inputLinkers[2]
    self.staticInputs["subFrame"]   = inputLinkers[3]

    self.isAnimationSettingsInitialised = true
end


function batchRenderJobScript:insertAnimationInputLinkers(graph)

    self.isAnimationSettingsInitialised = true
    
    local inputInfos = createAnimationLinkerInfos(self.sceneFrameInterval)
    
    assert(ANIM_SETTINGS_COUNT == #inputInfos, "ANIM_SETTINGS_COUNT should be the size of animation inputInfos")
    
    local inputLinkers = graph:insertInputLinkers(inputInfos, ANIM_SETTINGS_LINKERS_START_IX + 1)
    self.staticInputs["firstFrame"] = inputLinkers[1]
    self.staticInputs["lastFrame"]  = inputLinkers[2]
    self.staticInputs["subFrame"]   = inputLinkers[3]
    
    self.staticInputCount = self.staticInputCount + ANIM_SETTINGS_COUNT
    self:updateInitialDataToNodes()
    
end


function batchRenderJobScript:removeAnimationSettingsInputLinkers(graph)

    self.isAnimationSettingsInitialised = false
    
    local startRange =  ANIM_SETTINGS_LINKERS_START_IX + 1
    local endRange   =  ANIM_SETTINGS_LINKERS_START_IX + ANIM_SETTINGS_COUNT
    range            = {startRange, endRange} 
    
    graph:removeInputLinkers(range);
    
    self.staticInputs["firstFrame"] = nil
    self.staticInputs["lastFrame"]  = nil
    
    self.staticInputCount = self.staticInputCount - 2
    self.sceneFrameInterval = {0, 0}
    
end


-- Create static input linkers
function batchRenderJobScript:createInputLinkers(graph)

    local fps = octane.project.getProjectSettings():getAttribute(octane.A_FRAMES_PER_SECOND)
    self.sceneFrameInterval = calcSceneFrameInterval(graph.rootGraph, fps);
    
    -- this can be true when this renderjob is loaded from a ocs or orbx package
    local hasAnimLinkers = #graph:findItemsByName("First frame", false) > 0
    
    local inputInfos =
    {
        { type = octane.PT_INT, label = "Render target count", defaultNodeType = octane.NT_INT,
                defaultValue = 3, bounds = { 0, MAX_RENDER_TARGET_COUNT } },

        { type = octane.PT_ENUM, label = "Render priority", defaultNodeType = octane.NT_ENUM,
                defaultValue = 1, enum ={ "Per frame", "Per render target",}, group = "Animation" }, 

        { type = octane.PT_BOOL, label = "Override samples", defaultNodeType = octane.NT_BOOL,
                defaultValue = false, group = "Overrides" },

        { type = octane.PT_INT, label = "Samples/px", defaultNodeType = octane.NT_INT,
                defaultValue = 100, bounds = { 0, 256000 }, group = "Overrides" },

        { type = octane.PT_BOOL,label = "Override resolution", defaultNodeType = octane.NT_BOOL,
                defaultValue = false, group = "Overrides" },

        { type = octane.PT_INT, label = "Resolution", defaultNodeType = octane.NT_IMAGE_RESOLUTION,
                defaultValue = {1024, 512}, group = "Overrides" },

        { type = octane.PT_ENUM, label = "Image format", defaultNodeType = octane.NT_ENUM,
                defaultValue = 1, enum = octaneRenderUtils.IMAGE_SAVE_FORMAT_NAMES, group = "Save" },

        { type = octane.PT_OCIO_COLOR_SPACE, label = "Color space", defaultNodeType = octane.NT_OCIO_COLOR_SPACE,
                group = "Save", description = "Color space for output. Select a built-in color space or an OCIO color space." },

        { type = octane.PT_OCIO_LOOK, label = "OCIO look", defaultNodeType = octane.NT_OCIO_LOOK,
                group = "Save", description = "OCIO look to apply to output, if using an OCIO color space." },

        { type = octane.PT_BOOL, label = "Force tone mapping", defaultNodeType = octane.NT_BOOL,
                group = "Save", description = "Whether to apply Octane's built-in tone mapping"..
                " (before applying any OCIO look(s)) when saving in a color space other than"..
                " sRGB. This may produce undesirable results due to an intermediate reduction to"..
                " the sRGB color space." },

        { type = octane.PT_STRING, label = "Output directory", defaultNodeType = octane.NT_DIRECTORY,
                defaultValue = "", group = "Save" },

        { type = octane.PT_STRING, label = "Filename template", defaultNodeType = octane.NT_STRING,
                defaultValue = "%n_%p_%f.%e", group = "Save",
                description = [[Template parameters:%i render target index
                                %n render target node name
                                %e file extension
                                %t timestamp
                                %f frame number (always prefixed with 0s)
                                %s sub frame number
                                %p render pass name]] },      

        { type = octane.PT_BOOL, label = "Skip existing file", defaultNodeType = octane.NT_BOOL,
                defaultValue = false, group = "Save" },
          
        { type = octane.PT_BOOL, label = "Save all enabled passes", defaultNodeType = octane.NT_BOOL,
                defaultValue = true, group = "Save" },  

        { type = octane.PT_BOOL, label = "Save denoised main pass if available", defaultNodeType = octane.NT_BOOL,
                defaultValue = true, group = "Save", description="Save denoised main pass, but only valid if denoiser is enabled and \"save all enabled passes\" is false." },

        { type = octane.PT_BOOL, label = "Save layered EXR", defaultNodeType = octane.NT_BOOL,
                defaultValue = false, group = "Save" },

        { type = octane.PT_BOOL, label = "Premultiplied alpha (EXR and TIFF)", defaultNodeType = octane.NT_BOOL,
                defaultValue = true, group = "Save" },
          
        { type = octane.PT_ENUM, label = "EXR compression", defaultNodeType = octane.NT_ENUM,
                defaultValue = 4, enum = octaneRenderUtils.COMPRESSION_NAMES_EXR, group = "Save" },

        { type = octane.PT_FLOAT, label = "EXR compression level", defaultNodeType = octane.NT_FLOAT,
                defaultValue = 45, bounds = {0, 2000}, logarithmic = true, step = 1,
                group = "Save", description = "Compression level for EXR DWA compression. 45 is the default, 1 is high quality, higher values mean higher compression."},

        { type = octane.PT_BOOL, label = "Deep image", defaultNodeType = octane.NT_BOOL,
                defaultValue = false, group = "Save" },

        { type = octane.PT_ENUM, label = "TIFF compression", defaultNodeType = octane.NT_ENUM,
                defaultValue = 2, enum = octaneRenderUtils.COMPRESSION_NAMES_TIFF, group = "Save" },

        { type = octane.PT_FLOAT, label = "JPEG quality", defaultNodeType = octane.NT_FLOAT,
                defaultValue = 75, bounds = {1, 100}, logarithmic = false, step = 1,
                group = "Save", description = "JPEG quality, higher values mean higher quality and size. 75 is the default."},
    }
    
    
    local hasAnimation = frameIntervalAnimated(self.sceneFrameInterval)
    if hasAnimation then
        local animationLinkerInfos = createAnimationLinkerInfos(self.sceneFrameInterval)
        for i, animLinkerInfo in ipairs(animationLinkerInfos) do
            table.insert(inputInfos, ANIM_SETTINGS_LINKERS_START_IX + i, animLinkerInfo)
        end 
        self.isAnimationSettingsInitialised = true
    else
        self.isAnimationSettingsInitialised = false
    end

    -- Tell the graph to actually create the linker nodes (and pins).
    self.staticInputCount = #inputInfos
    local staticRange = {1, #inputInfos} 
    if hasAnimLinkers == false and hasAnimation then
        staticRange[2] = #inputInfos - ANIM_SETTINGS_COUNT
    elseif hasAnimLinkers == true and not hasAnimation then
        staticRange[2] = #inputInfos + ANIM_SETTINGS_COUNT
    end
    local inputLinkers = graph:setInputLinkers(inputInfos, staticRange)

    local inputIndex = 1

    -- Making it accessable via inputs dictionary
    self.staticInputs["renderTargetCount"]    = inputLinkers[inputIndex]
    inputIndex = inputIndex + 1
    self.staticInputs["renderPriority"]       = inputLinkers[inputIndex]
    inputIndex = inputIndex + 1
    if hasAnimation then
        self.staticInputs["firstFrame"]       = inputLinkers[inputIndex]
        inputIndex = inputIndex + 1
        self.staticInputs["lastFrame"]        = inputLinkers[inputIndex]
        inputIndex = inputIndex + 1
        self.staticInputs["subFrame"]         = inputLinkers[inputIndex]
        inputIndex = inputIndex + 1
    end
    self.staticInputs["overrideSamples"]      = inputLinkers[inputIndex]
    inputIndex = inputIndex + 1
    self.staticInputs["maxSamples"]           = inputLinkers[inputIndex]
    inputIndex = inputIndex + 1
    self.staticInputs["overrideResolution"]   = inputLinkers[inputIndex]
    inputIndex = inputIndex + 1
    self.staticInputs["resolution"]           = inputLinkers[inputIndex]
    inputIndex = inputIndex + 1
    self.staticInputs["imageSaveFormat"]      = inputLinkers[inputIndex]
    inputIndex = inputIndex + 1
    self.staticInputs["colorSpace"]           = inputLinkers[inputIndex]
    inputIndex = inputIndex + 1
    self.staticInputs["ocioLook"]             = inputLinkers[inputIndex]
    inputIndex = inputIndex + 1
    self.staticInputs["forceToneMapping"]     = inputLinkers[inputIndex]
    inputIndex = inputIndex + 1
    self.staticInputs["outputDir"]            = inputLinkers[inputIndex]
    inputIndex = inputIndex + 1
    self.staticInputs["filenameTemplate"]     = inputLinkers[inputIndex]
    inputIndex = inputIndex + 1
    self.staticInputs["skipExistingFile"]     = inputLinkers[inputIndex]
    inputIndex = inputIndex + 1
    self.staticInputs["saveAllEnabledPasses"] = inputLinkers[inputIndex]
    inputIndex = inputIndex + 1
    self.staticInputs["saveDeBeautyAsMain"]   = inputLinkers[inputIndex]
    inputIndex = inputIndex + 1
    self.staticInputs["saveLayeredExr"]       = inputLinkers[inputIndex]
    inputIndex = inputIndex + 1
    self.staticInputs["premultipliedAlpha"]   = inputLinkers[inputIndex]
    inputIndex = inputIndex + 1
    self.staticInputs["exrCompressionType"]   = inputLinkers[inputIndex]
    inputIndex = inputIndex + 1
    self.staticInputs["exrCompressionLevel"]  = inputLinkers[inputIndex]
    inputIndex = inputIndex + 1
    self.staticInputs["saveDeepImage"]        = inputLinkers[inputIndex]
    inputIndex = inputIndex + 1
    self.staticInputs["tiffCompressionType"]  = inputLinkers[inputIndex]
    inputIndex = inputIndex + 1
    self.staticInputs["jpegQuality"]          = inputLinkers[inputIndex]

    -- Make sure all the input pins are connected to a node.
    for name, node in ipairs(self.staticInputs) do
        node:configureEmptyPins()
    end

end

-- function to create output linkers
function batchRenderJobScript:createOutputLinkers(graph)
    local outputInfos =
    {
        { type = octane.PT_RENDER_JOB, label = "Render job" }
    }

   -- Tell the graph to actually create the linker nodes (and pins).
   graph:setOutputLinkers(outputInfos)

end


-- This function will update all necessary data like 
-- when user changes the input
function batchRenderJobScript:update(graph)

    local prevFrameInterval = self.sceneFrameInterval
    local fps = octane.project.getProjectSettings():getAttribute(octane.A_FRAMES_PER_SECOND)
    self.sceneFrameInterval = calcSceneFrameInterval(graph.rootGraph, fps);
    local hasAnimation = frameIntervalAnimated(self.sceneFrameInterval)
    
    if not frameIntervalsEqual(prevFrameInterval, self.sceneFrameInterval) then 
        
        if self.isAnimationSettingsInitialised == true then
            if hasAnimation then
                self:modifyAnimationInputLinkers(graph)
            else
                self:removeAnimationSettingsInputLinkers(graph)
            end
        else 
            if hasAnimation then
                self:insertAnimationInputLinkers(graph)
            end
        end
    end

    if self:hasAnimationFrameInputs() then
        --  make sure first and last frame will not cross over
        local firstFrameValue = self:getInputValue(self.staticInputs["firstFrame"])
        local lastFrameValue = self:getInputValue(self.staticInputs["lastFrame"])
        
        if firstFrameValue > lastFrameValue then 
            self:setInputValue(self.staticInputs["firstFrame"], lastFrameValue, true)
        end
    end
    
    graph:setAttribute(octane.A_TOTAL_FRAMES, self:calcTotalResultFrames())
    
    self.renderPriority = self:getInputValue(self.staticInputs["renderPriority"])
    
end


-- Calculating the render target index and frame for the result value
function batchRenderJobScript:getRenderTargetIndexAndFrameNumber(resultIx)

    local firstFrame = 0
    local lastFrame  = 0
    local subFrame   = 1

    if self.staticInputs["firstFrame"] then
        firstFrame = self:getInputValue(self.staticInputs["firstFrame"])
    end 
    
    if self.staticInputs["lastFrame"] then
        lastFrame = self:getInputValue(self.staticInputs["lastFrame"])
    end 
    
    if self.staticInputs["subFrame"] then
        subFrame = self:getInputValue(self.staticInputs["subFrame"])
    end 
    
    local rtIx    = 0
    local frameIx = 0
    local subFrameIx   = (resultIx % subFrame) + 1
    local mainResultIx = math.floor(resultIx / subFrame)

        
    if self.renderPriority == PRIORITY_FRAME then     
        rtIx    = mainResultIx % self:activeRenderTargetCount()
        frameIx = math.floor(mainResultIx / self:activeRenderTargetCount()) + firstFrame
    else
        framesDiff = (lastFrame - firstFrame) + 1
        
        rtIx    = math.floor(mainResultIx / framesDiff)  
        frameIx = (mainResultIx % framesDiff) + firstFrame
    end
    
    return rtIx, frameIx, subFrameIx
    
end


-- This function will increase or decrease the render target linker pins
-- depending upon the render target count input pin 
function batchRenderJobScript:checkForRenderTargetCountUpdate(graph)
    
    local currentRenderTargetCount = #self.renderTargetsLinkerNodes;
    
    -- grabing the pin value 
    local newCount  = self:getInputValue(self.staticInputs["renderTargetCount"])
    
    -- safety check
    if newCount < 0 then
        return;
    end 
  
    if newCount ~= currentRenderTargetCount then
        -- creating input infos
        local infos = {}
        for i = 1, newCount do
            local info = renderTargetLinkerInfo(i)
            infos[i] = info
        end
        
        -- replace dynamic input pins. The range parameter makes sure we don't touch the
        -- static pins
        -- list starts from 1
        local startRange = self.staticInputCount + 1 
        local endRange   = startRange + MAX_RENDER_TARGET_COUNT
        
        -- creating new render targets
        self.renderTargetsLinkerNodes = graph:setInputLinkers(infos, {startRange, endRange})
    end

end


function batchRenderJobScript:buildImageExportSettings(imageSaveFormat)
    local allSettings = {
        exrCompressionType = self:getInputValue(self.staticInputs["exrCompressionType"]),
        exrCompressionLevel = self:getInputValue(self.staticInputs["exrCompressionLevel"]),
        tiffCompressionType = self:getInputValue(self.staticInputs["tiffCompressionType"]),
        jpegQuality = self:getInputValue(self.staticInputs["jpegQuality"]),
    }

    return octaneRenderUtils.composeImageExportSettings(imageSaveFormat, allSettings)
end


function batchRenderJobScript:buildColorSpaceInfo()
    local imageSaveFormat      = IMAGE_SAVE_FORMATS[self:getInputValue(self.staticInputs["imageSaveFormat"])]
    local colorSpaceInputNode  = self.staticInputs["colorSpace"]:getInputNodeIx(1, true)
    local ocioLookInputNode    = self.staticInputs["ocioLook"]:getInputNodeIx(1, true)
    local colorSpace           = colorSpaceInputNode:getAttribute(octane.A_COLOR_SPACE)
    local forceToneMapping     = self:getInputValue(self.staticInputs["forceToneMapping"])
    local ocioColorSpaceName   = colorSpaceInputNode:getAttribute(octane.A_OCIO_COLOR_SPACE_NAME)
    local ocioLookName         = ocioLookInputNode:getAttribute(octane.A_OCIO_LOOK_NAME)
    return octaneRenderUtils.buildColorSpaceInfo(imageSaveFormat, colorSpace, ocioColorSpaceName, ocioLookName, forceToneMapping)
end

-- This function will save all the render passes are saved in one EXR file
-- Rendering should be completed before calling this function
function batchRenderJobScript:saveMultilayeredEXR(graph, renderTargetNode, renderTargetIx , frameIx, subFrameIx)

    -- save options
    local outputDirectory      = self:getOutputDirectory(graph)
    local imageSaveFormat      = IMAGE_SAVE_FORMATS[self:getInputValue(self.staticInputs["imageSaveFormat"])]
    local colorSpaceInfo       = self:buildColorSpaceInfo()
    local premultipliedAlpha   = self:getInputValue(self.staticInputs["premultipliedAlpha"])
    local fileNameTemplate     = self:getInputValue(self.staticInputs["filenameTemplate"])

     -- create an output path for the image
    local filename = octaneRenderUtils.createFilename(
        fileNameTemplate, renderTargetIx, frameIx, subFrameIx, renderTargetNode.name, imageSaveFormat, "all")

    local fullPath = octane.file.join(outputDirectory, filename)

    -- save
    return octane.render.saveRenderPassesMultiExr3(fullPath, nil,
        imageSaveFormat == octane.imageSaveFormat.EXR_16, colorSpaceInfo, premultipliedAlpha,
        self:buildImageExportSettings(imageSaveFormat), nil, false)

end


-- This function will save all the render passes in separate files
-- Rendering should be completed before calling this function
function batchRenderJobScript:saveDiscreteFiles(graph, renderTargetNode, renderTargetIx , frameIx, subFrameIx)

    -- save options
    local outputDirectory      = self:getOutputDirectory(graph)
    local imageSaveFormat      = IMAGE_SAVE_FORMATS[self:getInputValue(self.staticInputs["imageSaveFormat"])]
    local colorSpaceInfo       = self:buildColorSpaceInfo()
    local premultipliedAlphaType
    if octaneRenderUtils.supportsPremultipliedAlpha(imageSaveFormat) and self:getInputValue(self.staticInputs["premultipliedAlpha"]) then
        premultipliedAlphaType = octane.premultipliedAlphaType.LINEARIZED
    else
        premultipliedAlphaType = octane.premultipliedAlphaType.NONE
    end
    local fileNameTemplate     = self:getInputValue(self.staticInputs["filenameTemplate"])

    -- renderPassExportObjs will contain list of render passes which needed to be exported and their filenames to use 
    local renderPassExportObjs = octaneRenderUtils.createDiscreteRenderPassExports(
        renderTargetNode, outputDirectory, fileNameTemplate, renderTargetIx, frameIx, subFrameIx, imageSaveFormat)

    -- save
    return octane.render.saveRenderPasses3(outputDirectory, renderPassExportObjs, imageSaveFormat,
        colorSpaceInfo, premultipliedAlphaType, self:buildImageExportSettings(imageSaveFormat), false, nil)

end


-- This function will save main render pass image
-- Rendering should be completed before calling this function
function batchRenderJobScript:saveOnlyBeautyPass(graph, renderTargetNode, renderTargetIx , frameIx, subFrameIx)

    -- save options
    local outputDirectory      = self:getOutputDirectory(graph)
    local imageSaveFormat      = IMAGE_SAVE_FORMATS[self:getInputValue(self.staticInputs["imageSaveFormat"])]
    local colorSpaceInfo       = self:buildColorSpaceInfo()
    local premultipliedAlphaType
    if octaneRenderUtils.supportsPremultipliedAlpha(imageSaveFormat) and self:getInputValue(self.staticInputs["premultipliedAlpha"]) then
        premultipliedAlphaType = octane.premultipliedAlphaType.LINEARIZED
    else
        premultipliedAlphaType = octane.premultipliedAlphaType.NONE
    end
    local fileNameTemplate     = self:getInputValue(self.staticInputs["filenameTemplate"])
    local saveDeBeautyAsMain   = self:getInputValue(self.staticInputs["saveDeBeautyAsMain"])

    -- figure out whether we need to save the denoiser output or the main pass.    
    local renderPassId = octane.renderPassId.BEAUTY
    if saveDeBeautyAsMain and octaneRenderUtils.isDenoiserEnabled(renderTargetNode) then
        renderPassId = octane.renderPassId.BEAUTY_DENOISER_OUTPUT
    end

    -- create an output path for the image
    local filename = octaneRenderUtils.createFilename(
        fileNameTemplate,
        renderTargetIx,
        frameIx,
        subFrameIx,
        renderTargetNode.name,
        imageSaveFormat,
        octaneRenderUtils.getRenderPassName(renderPassId))

    local fullPath = octane.file.join(outputDirectory, filename)

   -- save
    return octane.render.saveRenderPass3(renderPassId, fullPath, imageSaveFormat, colorSpaceInfo,
        premultipliedAlphaType, self:buildImageExportSettings(imageSaveFormat), false)

end


-- This function will save deep EXR image
-- Rendering should be completed before calling this function
function batchRenderJobScript:saveDeepImage(graph, renderTargetNode, renderTargetIx, frameIx, subFrameIx)

    -- save options
    local outputDirectory  = self:getOutputDirectory(graph);
    local fileNameTemplate = self:getInputValue(self.staticInputs["filenameTemplate"])
    local saveAllEnabledPasses = self:getInputValue(self.staticInputs["saveAllEnabledPasses"])

    if octane.render.canSaveDeepImage() then
        local deepFilename = octaneRenderUtils.createFilename(fileNameTemplate, renderTargetIx,
                frameIx, subFrameIx, renderTargetNode.name, octane.imageSaveFormat.EXR_32, "deep")
        local deepPath = octane.file.join(outputDirectory, "deep_"..deepFilename)
        if saveAllEnabledPasses and octane.render.deepPassesEnabled() then
            return octane.render.saveRenderPassesDeepExr2(deepPath, nil)
        else
            return octane.render.saveDeepImage2(deepPath)
        end
    end

    return true
end


-- This function will save the render target using specified options 
function batchRenderJobScript:save(graph, renderTargetNode, renderTargetIx, frameIx, subFrameIx)

    -- safety check
    assert(renderTargetNode and renderTargetNode.type == octane.NT_RENDERTARGET)
    if (renderTargetNode == nil or renderTargetNode.type ~= octane.NT_RENDERTARGET) then
        return false
    end

    -- output directory  
    local outputDirectory = self:getOutputDirectory(graph);
    -- if empty,then we should be in preview mode
    if outputDirectory == "" then
        return true
    end 

    -- save options
    local imageSaveFormat      = IMAGE_SAVE_FORMATS[self:getInputValue(self.staticInputs["imageSaveFormat"])]
    local saveAllEnabledPasses = self:getInputValue(self.staticInputs["saveAllEnabledPasses"])
    local saveLayeredExr       = self:getInputValue(self.staticInputs["saveLayeredExr"])
    local saveDeepImage        = self:getInputValue(self.staticInputs["saveDeepImage"])

    local retValue
    if saveAllEnabledPasses and octaneRenderUtils.hasRenderPasses(renderTargetNode) == true then
        if octaneRenderUtils.isExrImageSaveFormat(imageSaveFormat) and saveLayeredExr then
            retValue = self:saveMultilayeredEXR(graph, renderTargetNode, renderTargetIx, frameIx, subFrameIx)
        else 
            retValue = self:saveDiscreteFiles(graph, renderTargetNode, renderTargetIx, frameIx, subFrameIx)
        end
    else
        retValue = self:saveOnlyBeautyPass(graph, renderTargetNode, renderTargetIx, frameIx, subFrameIx)
    end
    if saveDeepImage then
        if not self:saveDeepImage(graph, renderTargetNode, renderTargetIx, frameIx, subFrameIx) then
            error("failed to save deep image")
        end
    end
    return retValue;
    
end


-- Checks whether all output files already exist on disk (unless there are no files to output in
-- which case it returns false).
function batchRenderJobScript:isFileExists(graph, renderTargetNode, renderTargetIx, frameIx, subFrameIx)

    -- safety check
    assert(renderTargetNode and renderTargetNode.type == octane.NT_RENDERTARGET)
    -- get output directory
    local outputDirectory = self:getOutputDirectory(graph)
    -- early return
    if (renderTargetNode == nil or renderTargetNode.type ~= octane.NT_RENDERTARGET or outputDirectory == "") then
        return false
    end   
    
    -- save options
    local imageSaveFormat      = IMAGE_SAVE_FORMATS[self:getInputValue(self.staticInputs["imageSaveFormat"])]
    local saveAllEnabledPasses = self:getInputValue(self.staticInputs["saveAllEnabledPasses"])
    local saveLayeredExr       = self:getInputValue(self.staticInputs["saveLayeredExr"])
    local fileNameTemplate     = self:getInputValue(self.staticInputs["filenameTemplate"])

    local filesToCheck = {}

    if saveAllEnabledPasses and octaneRenderUtils.hasRenderPasses(renderTargetNode) == true then
        if octaneRenderUtils.isExrImageSaveFormat(imageSaveFormat) and saveLayeredExr then
            local filename = octaneRenderUtils.createFilename(
                fileNameTemplate, renderTargetIx, frameIx, subFrameIx, renderTargetNode.name, imageSaveFormat, "all")
            local fullPath = octane.file.join(outputDirectory, filename)
            table.insert(filesToCheck, fullPath)
        else 
            local renderPassExportObjs = octaneRenderUtils.createDiscreteRenderPassExports(
                renderTargetNode, outputDirectory, fileNameTemplate, renderTargetIx, frameIx, subFrameIx, imageSaveFormat)
            for _, exportObj in ipairs(renderPassExportObjs) do
                if exportObj and exportObj.exportName then
                    local fullPath = octane.file.join(outputDirectory, exportObj.exportName)
                    table.insert(filesToCheck, fullPath)
                end
            end 
        end
    else
        local filename = octaneRenderUtils.createFilename(
            fileNameTemplate, renderTargetIx, frameIx, subFrameIx, renderTargetNode.name, imageSaveFormat, "beauty")
        local fullPath = octane.file.join(outputDirectory, filename)
        table.insert(filesToCheck, fullPath)
    end
    
    if #filesToCheck == 0 then 
        return false
    end
    
    for _, file in ipairs(filesToCheck) do
        if octane.file.exists(file) == false then
            return false
        end
    end
    
    return true
    
end


-- On init function
function batchRenderJobScript.onInit(self, graph)
   
    -- Creating the linkers
    self:createInputLinkers(graph) 
    self:createOutputLinkers(graph) 
    
    self:updateInitialDataToNodes()
    
end


-- On evaluate script
-- This function is called when there is a change in any of our input values
function batchRenderJobScript.onEvaluate(self, graph)
    
    self:checkForRenderTargetCountUpdate(graph);
    self:update(graph);

end


-- On Iterate script
--
-- @return
--  * Render target node which needs to be rendered
--  * true if we need to skip the rendering for this iteration
function batchRenderJobScript.onIterate(self, graph, resultIx)
    
   local totalResultFrames = self:calcTotalResultFrames();
    
    -- validating in case we get wrong input
    local validatedResultIx = octaneRenderUtils.ternaryOperator(resultIx > totalResultFrames, 
                                                                totalResultFrames,
                                                                resultIx)
                                           
    self.lastRenderedResultIx = validatedResultIx
    
    -- finding the render target index and frame for the iterator value
    local renderTargetIx, frameIx, subFrameIx = self:getRenderTargetIndexAndFrameNumber(validatedResultIx)
    
    -- getting renderTarget node from copy
    -- list starts at 1
    renderTargetNode = self.renderTargetsCopy[renderTargetIx + 1]

    -- Lock file logic to prevent duplicate renders across machines
    local outputDirectory = self:getOutputDirectory(graph)
    local frameLockFilename = string.format("frame_%04d.lock", frameIx)
    local lockFilePath = octane.file.join(outputDirectory, frameLockFilename)

    -- If lock file exists, skip this frame
    if octane.file.exists(lockFilePath) then
        return nil, true
    end

    -- Otherwise, create the lock file
    local lockFile = io.open(lockFilePath, "w")
    if lockFile then
        lockFile:write("Frame claimed by another render node")
        lockFile:close()
    end

    
    -- skipping if the file exists
    local skipExistingFile = self:getInputValue(self.staticInputs["skipExistingFile"])

    if skipExistingFile then
        if self:isFileExists(graph, renderTargetNode, renderTargetIx, frameIx, subFrameIx) then
            return nil, true
        end
    end
    
    if renderTargetNode then
        -- update the frame time
        local fps = octane.project.getProjectSettings():getAttribute(octane.A_FRAMES_PER_SECOND)
        self.copyItemsRootGraph:updateTime(octaneRenderUtils.frameToTime(frameIx, fps))
        
        -- updating the subframe
        if self.staticInputs["subFrame"] then
            local subFrameCount = self:getInputValue(self.staticInputs["subFrame"])
            if subFrameCount > 1 then
                octaneRenderUtils.setSubFrameInterval(renderTargetNode, subFrameIx, subFrameCount)
            end
        end

        -- max samples overrides 
        local overrideSample = self:getInputValue(self.staticInputs["overrideSamples"])
        if overrideSample then
            local maxSamples = self:getInputValue(self.staticInputs["maxSamples"])
            renderTargetNode:getInputNode(octane.P_KERNEL):setPinValue(octane.P_MAX_SAMPLES, maxSamples)
        end
        
        -- resolution override
        local overrideResolution = self:getInputValue(self.staticInputs["overrideResolution"])
        if overrideResolution then
            local resolution = self:getInputValue(self.staticInputs["resolution"])
            renderTargetNode:getInputNode(octane.P_FILM_SETTINGS):setPinValue(octane.P_RESOLUTION, resolution)
        end
    end
    
    return renderTargetNode, false
    
end


-- On save rendered frame script
-- 
-- @return 
--  Returns true, if the image was saved successfully 
function batchRenderJobScript.onSaveRenderedFrame(self, graph)

    -- finding the render target index and frame for the result index value
    local renderTargetIx, frameIx, subFrameIx = self:getRenderTargetIndexAndFrameNumber(self.lastRenderedResultIx)
    
    renderTargetNode = self.renderTargetsCopy[renderTargetIx + 1]

    -- Lock file logic to prevent duplicate renders across machines
    local outputDirectory = self:getOutputDirectory(graph)
    local frameLockFilename = string.format("frame_%04d.lock", frameIx)
    local lockFilePath = octane.file.join(outputDirectory, frameLockFilename)

    -- If lock file exists, skip this frame
    if octane.file.exists(lockFilePath) then
        return nil, true
    end

    -- Otherwise, create the lock file
    local lockFile = io.open(lockFilePath, "w")
    if lockFile then
        lockFile:write("Frame claimed by another render node")
        lockFile:close()
    end

    return self:save(graph, renderTargetNode, renderTargetIx, frameIx, subFrameIx)
    
end


-- On start Iteration script
-- This function is called once at the start of the render job
function batchRenderJobScript.onStartIteration(self, graph)
 
    -- Interactive render region should not be active when running batch render job.
    local renderRegion = { active = false }
    octane.render.setRenderRegion(renderRegion)
    
    -- making copies of render targets so that our overrides does not affect actual project
    
    -- creating a graph to copy items into
    self.copyItemsRootGraph = octane.nodegraph.createRootGraph("copyItemsRootGraph")

    local hasRenderPasses = false;
    
    -- preparing render targets to copy
    -- making list of render target nodes from our linker node list
    local renderTargetNodes = {}
    local count             = 1
    for  _, item in ipairs(self.renderTargetsLinkerNodes) do
        if item:getInputNode(octane.P_INPUT) then 
            renderTargetNodes[count] = item:getInputNode(octane.P_INPUT)
            if hasRenderPasses == false then 
                hasRenderPasses = octaneRenderUtils.hasRenderPasses(renderTargetNodes[count])
            end
            count = count + 1
        end 
    end
    
    -- make copy
    self.renderTargetsCopy = self.copyItemsRootGraph:copyFromGraph(graph.rootGraph, renderTargetNodes)
    
    -- saftey check before we start rendering.
    local template             = self:getInputValue(self.staticInputs["filenameTemplate"])
    local saveAllEnabledPasses = self:getInputValue(self.staticInputs["saveAllEnabledPasses"])
    local saveLayeredExr       = self:getInputValue(self.staticInputs["saveLayeredExr"])
    local imageSaveFormat      = IMAGE_SAVE_FORMATS[self:getInputValue(self.staticInputs["imageSaveFormat"])]
    local firstFrame           = 0
    local lastFrame            = 0
    local subFrames            = 1
    if self.isAnimationSettingsInitialised then
        firstFrame = self:getInputValue(self.staticInputs["firstFrame"])
        lastFrame  = self:getInputValue(self.staticInputs["lastFrame"])
        subFrames  = self:getInputValue(self.staticInputs["subFrame"])
    end
    local errorMsg = octaneRenderUtils.verifyFilenameTemplate(
        template,
        count > 1,
        firstFrame ~= lastFrame,
        subFrames > 1,
        hasRenderPasses and saveAllEnabledPasses and (octaneRenderUtils.isExrImageSaveFormat(imageSaveFormat) == false or saveLayeredExr == false))
    if errorMsg ~= "" then
        print(errorMsg)
    end
    
end


-- On finish iteration script
-- This function is called once at the end of the render job
function batchRenderJobScript.onFinishIteration(self, graph)
    
    -- clear the render target copy from render viewport
    octane.render.clear()
    
    -- delete the copies we don't require it anymore
    octane.nodegraph.destroy(self.copyItemsRootGraph)
    self.renderTargetsCopy = {}

end

return batchRenderJobScript
