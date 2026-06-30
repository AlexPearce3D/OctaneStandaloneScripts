-- ScriptLauncher.lua
-- Stable launcher: fixed dialog type (no file-save dialog) + clear sandbox guidance.

local DROPBOX_SCRIPT_DIR = "/Users/alex/Sim-Plates Dropbox/Sim-Plates Team Folder/00_SIM-PLATES/04_PIPELINE/03_OCTANE/OctaneStandaloneScripts"
local CONTAINER_SCRIPT_DIR = "/Users/alex/Library/Containers/com.otoy.rndrviewer/Data/OctaneStandaloneScripts"

local TARGET_SCRIPT = "ScanLightAOVs.lua"

local function join_path(dir, file)
    if dir:sub(-1) == "/" then return dir .. file end
    return dir .. "/" .. file
end

local function try_run(path)
    local ok, err = pcall(dofile, path)
    return ok, err
end

local function run_target_script()
    -- 1) Current working dir
    local ok_rel, err_rel = try_run(TARGET_SCRIPT)
    if ok_rel then
        print("[Launcher] done: " .. TARGET_SCRIPT .. " (relative)")
        return true
    end

    -- 2) Dropbox scripts dir
    local dropbox_path = join_path(DROPBOX_SCRIPT_DIR, TARGET_SCRIPT)
    local ok_drop, err_drop = try_run(dropbox_path)
    if ok_drop then
        print("[Launcher] done: " .. dropbox_path)
        return true
    end

    -- 3) Octane container dir
    local container_path = join_path(CONTAINER_SCRIPT_DIR, TARGET_SCRIPT)
    local ok_cont, err_cont = try_run(container_path)
    if ok_cont then
        print("[Launcher] done: " .. container_path)
        return true
    end

    print("[Launcher] Could not run script.")
    print("[Launcher] relative failed: " .. tostring(err_rel))
    print("[Launcher] dropbox failed : " .. tostring(err_drop))
    print("[Launcher] container failed: " .. tostring(err_cont))
    print("[Launcher] Tip: this Octane build is sandboxed; put scripts in:")
    print("[Launcher]   " .. CONTAINER_SCRIPT_DIR)
    print("[Launcher] then rerun launcher.")

    if octane and octane.gui and octane.gui.showError then
        pcall(octane.gui.showError,
            "Cannot run script from current location.\n\n"
            .. "Try placing scripts in:\n" .. CONTAINER_SCRIPT_DIR)
    end

    return false
end

local function show_confirm_dialog()
    if not (octane and octane.gui and octane.gui.showDialog) then
        print("[Launcher] showDialog unavailable")
        return nil
    end

    local dt = octane.gui.dialogType or {}
    local di = octane.gui.dialogIcon or {}

    -- IMPORTANT: fixed type to avoid file-save dialog.
    local payload = {
        type = dt.OK_CANCEL or dt.OK or 1,
        icon = di.INFO or 0,
        title = "Script Launcher",
        text = "Run " .. TARGET_SCRIPT .. "?\n\nOK runs it. Cancel closes.",
    }

    local ok, result = pcall(octane.gui.showDialog, payload)
    if not ok then
        print("[Launcher] showDialog failed: " .. tostring(result))
        return nil
    end

    print("[Launcher] showDialog result=" .. tostring(result))
    if type(result) == "table" then
        for k, v in pairs(result) do
            print("[Launcher] result." .. tostring(k) .. "=" .. tostring(v))
        end
    end

    return result
end

local function is_affirmative(result)
    if type(result) == "boolean" then return result end
    if type(result) == "number" then return result == 0 or result == 1 end
    if type(result) == "string" then
        local s = result:lower()
        return s == "ok" or s == "yes" or s == "true" or s == "1"
    end
    if type(result) == "table" then
        -- Your build returns tables; use explicit result code when available.
        if type(result.result) == "number" then
            return result.result == 1 or result.result == 0
        end
        -- Otherwise default affirmative unless explicit cancel flags are present.
        if result.cancel == true or result.canceled == true or result.cancelled == true then
            return false
        end
        return true
    end
    return false
end

local function run()
    local choice = show_confirm_dialog()
    if choice == nil then
        return
    end

    if is_affirmative(choice) then
        run_target_script()
    else
        print("[Launcher] Closed.")
    end
end

run()
