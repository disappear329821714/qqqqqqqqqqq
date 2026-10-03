-- Black Flash: animation timing, camera backup, full-screen red GUI confirmation.
-- Requires your client Lua runtime to provide mouse1press and mouse1release.
-- No server remotes or animation modifications. Close AHK before using.
local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local Run = game:GetService("RunService")
local player = assert(Players.LocalPlayer, "Run on the client")
local env = type(getgenv) == "function" and getgenv() or _G
if env.BlackFlashMacro then env.BlackFlashMacro.Stop() end
if env.BlackFlashDiagnostics then env.BlackFlashDiagnostics.Stop() end
local press, release = mouse1press, mouse1release
assert(type(press)=="function" and type(release)=="function",
    "This runtime must provide mouse1press and mouse1release; no input was sent.")

local config = {
    Phase2 = 0.440, Phase1 = 0.283, Phase4 = 1.100,
    ReadySeconds = 15, MaxLate = 0.020,
    CameraFallback = true, CameraCueAge = 0.100,
    KeyDelay1 = 0.465, KeyDelay4 = 1.700, -- provisional camera-backed fallbacks
    AirCameraTiming = true, AirCameraPhase2 = 0.440, AirCameraTimeout = 1.200,
    AirDelay2 = 0.600, -- provisional key-to-click fallback for unmatched airborne 2
}
local animationMoves = {
    ["77102803675218"] = 2,
    ["137127919224043"] = 1,
    ["86485944206392"] = 4, -- actual follow-up, not 4's startup track
}
local connections, characterConnections, overlays = {}, {}, {}
local enabled, stopped, down, focused = true, false, false, true
local attempt, readyUntil, downAt, serial = nil, 0, 0, 0
local function log(message) print("[BF-LUA] "..message) end
local function connect(signal, callback)
    local connection = signal:Connect(callback)
    table.insert(connections,connection)
    return connection
end
local function mouseUp()
    if down then pcall(release); down = false end
end
local function reset()
    serial = serial+1
    attempt,readyUntil = nil,0
    mouseUp()
end
local function matchesOverlay(object)
    -- Coverage and opacity checks below reject small red HUD elements.
    return object:IsA("Frame")
end
local function cameraSample()
    local ok, value = pcall(function()
        local camera=workspace.CurrentCamera
        local character=player.Character
        local root=character and character:FindFirstChild("HumanoidRootPart")
        if not camera or not root then return nil end
        return {camera=camera, fov=camera.FieldOfView,
            distance=(camera.CFrame.Position-root.Position).Magnitude}
    end)
    return ok and value or nil
end
local function updateCamera(current,now)
    local sample=cameraSample()
    local base=current.cameraBase
    if not sample then return end
    if not base or sample.camera~=base.camera then
        current.cameraBase=sample;current.cameraIn=false;current.cameraOut=nil;return
    end
    -- Relative distance avoids interpreting ordinary character translation as a pan.
    local zoom=base.fov-sample.fov
    local distance=base.distance-sample.distance
    if zoom>=3 or distance>=1.2 then current.cameraIn=true end
    -- FOV onset is independent of jumping changing the root-to-camera distance.
    if not current.zoomStarted and zoom>=.5 then
        current.zoomStarted=now
        log(string.format("%d: zoom started %.4fs after key",current.move,now-current.started))
    end
    if current.cameraIn and not current.cameraOut and zoom<=1 and distance<=.4 then
        current.cameraOut=now
        log(tostring(current.move)..": camera returned; backup cue observed")
    end
end
local function redVisible(object)
    if not object.Parent or not matchesOverlay(object) then return false end
    local camera = workspace.CurrentCamera
    if not camera then return false end
    local viewport = camera.ViewportSize
    if viewport.X<=0 or viewport.Y<=0 then return false end
    local size,position = object.AbsoluteSize,object.AbsolutePosition
    local width = math.max(0,math.min(viewport.X,position.X+size.X)-math.max(0,position.X))
    local height = math.max(0,math.min(viewport.Y,position.Y+size.Y)-math.max(0,position.Y))
    if width < viewport.X*.75 or height < viewport.Y*.6 then return false end
    local alpha = 1-object.BackgroundTransparency
    local ancestor = object
    while ancestor and ancestor ~= player.PlayerGui do
        if ancestor:IsA("GuiObject") and not ancestor.Visible then return false end
        if ancestor:IsA("ScreenGui") and not ancestor.Enabled then return false end
        if ancestor:IsA("CanvasGroup") then alpha=alpha*(1-ancestor.GroupTransparency) end
        ancestor=ancestor.Parent
    end
    local color=object.BackgroundColor3
    return alpha>=.35 and color.R>=.25 and color.G<=.10 and color.B<=.10
end
local function observe(object)
    if matchesOverlay(object) then overlays[object]=true end
end
local gui=player:WaitForChild("PlayerGui")
for _,object in ipairs(gui:GetDescendants()) do observe(object) end
connect(gui.DescendantAdded,observe)
connect(gui.DescendantRemoving,function(object) overlays[object]=nil end)

local function airborne()
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not humanoid then return false end
    local ok, result = pcall(function()
        return humanoid.FloorMaterial == Enum.Material.Air
            or humanoid:GetState() == Enum.HumanoidStateType.Jumping
            or humanoid:GetState() == Enum.HumanoidStateType.Freefall
    end)
    return ok and result
end

local function startMove(move)
    if not enabled or stopped or not focused or UIS:GetFocusedTextBox() then return end
    local now=os.clock()
    if attempt then
        -- Repeated keys refresh only the pre-animation input association.
        -- Once matched, keep the original track, phase target and air deadline.
        if attempt.move==move and not attempt.track and not attempt.clicked then
            attempt.lastPressed=now
        end
        return
    end
    if move~=2 and now>=readyUntil then log(tostring(move).." blocked: land 2 first"); return end
    -- Never overlap a tracked injected hold with a new attempt.
    if down then log("Release M1 before starting another move"); return end
    if UIS:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
        log("Release M1 before using the macro"); return
    end
    serial=serial+1
    local baseline={}
    if move==2 then
        readyUntil=0
        for object in pairs(overlays) do baseline[object]=redVisible(object) end
    else
        readyUntil=0 -- one shared use: 1 OR 4, never both from one success
    end
    attempt={move=move,started=now,lastPressed=now,serial=serial,baseline=baseline,clicked=false,track=nil,air=airborne(),airLogs=0,cameraBase=cameraSample()}
    log(tostring(move)..": waiting for its animation"..(attempt.air and " (airborne)" or ""))
end
local function attachTrack(track)
    if not attempt or attempt.clicked or attempt.track then return end
    local animation=track.Animation
    local id=animation and animation.AnimationId:match("%d+")
    if animationMoves[id]~=attempt.move then
        if attempt.move==2 and attempt.air and attempt.airLogs<5 then
            attempt.airLogs=attempt.airLogs+1
            log("Air 2 observed animation "..tostring(id))
        end
        return
    end
    local age=os.clock()-(attempt.lastPressed or attempt.started)
    if age > (attempt.move==4 and 1.4 or .8) then return end
    attempt.track=track
    attempt.matchedAt=os.clock()
    log(tostring(attempt.move)..": animation "..id.." matched")
end
local function bindCharacter(character)
    reset()
    for _,connection in ipairs(characterConnections) do connection:Disconnect() end
    characterConnections={}
    task.spawn(function()
        local humanoid=character:WaitForChild("Humanoid",10)
        if not humanoid or stopped or player.Character~=character then return end
        local animator=humanoid:WaitForChild("Animator",10)
        if not animator or stopped or player.Character~=character then return end
        table.insert(characterConnections,connect(animator.AnimationPlayed,attachTrack))
        table.insert(characterConnections,connect(humanoid.Died,reset))
        log("Character ready")
    end)
end
connect(player.CharacterAdded,bindCharacter)
if player.Character then bindCharacter(player.Character) end
connect(UIS.WindowFocusReleased,function() focused=false;reset() end)
connect(UIS.WindowFocused,function() focused=true end)
local function click(current)
    if current~=attempt or current.clicked or not enabled or not focused then return end
    if UIS:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
        log("M1 held: automatic click skipped");attempt=nil;return
    end
    current.clicked=true
    current.clickedAt=os.clock()
    local ok,err=pcall(function() down=true;downAt=os.clock();press() end)
    if not ok then mouseUp();attempt=nil;log("Input failed: "..tostring(err));return end
    task.delay(.025,mouseUp)
    if current.track and current.track.IsPlaying then
        log(string.format("%d: M1 at animation phase %.4f (target %.4f)",current.move,
            current.track.TimePosition,config["Phase"..current.move]))
    elseif current.source=="camera" then
        log(string.format("%d: camera-backed fallback M1 at %.4fs; provisional timing",current.move,os.clock()-current.started))
    else
        log(string.format("Air %d: fallback M1 at %.4fs from timing anchor (target %.4fs)",
            current.move,os.clock()-(current.airAnchor or current.started),current.airTarget or config.AirDelay2))
    end
    if current.move~=2 then attempt=nil end
end
connect(UIS.InputBegan,function(input)
    if stopped or UIS:GetFocusedTextBox() then return end
    local key=input.KeyCode
    if key==Enum.KeyCode.F2 then
        enabled=not enabled;reset();log(enabled and "ON" or "OFF");return
    elseif key==Enum.KeyCode.F3 then reset();pcall(release);log("Reset");return
    elseif key==Enum.KeyCode.F10 then env.BlackFlashMacro.Stop();return end
    if input.UserInputType==Enum.UserInputType.MouseButton1 and not down and attempt and not attempt.clicked then
        if attempt.move==2 then
            -- A manual click may still legitimately produce the success cue.
            attempt.clicked=true;attempt.clickedAt=os.clock()
        else attempt=nil end
        log("Manual M1 replaced automatic click");return
    end
    if key==Enum.KeyCode.One then startMove(1)
    elseif key==Enum.KeyCode.Two then startMove(2)
    elseif key==Enum.KeyCode.Four then startMove(4) end
end)
local function step()
    if stopped then return end
    local now=os.clock()
    if down and now-downAt>.15 then mouseUp() end
    local current=attempt
    if not current then return end
    if not enabled or not focused then reset();return end
    local character=player.Character
    local humanoid=character and character:FindFirstChildOfClass("Humanoid")
    if humanoid and humanoid.Health and humanoid.Health<=0 then reset();return end
    updateCamera(current,now)
    local expiryStart=current.clickedAt or current.matchedAt or current.lastPressed or current.started
    if now-expiryStart>3.2 then attempt=nil;log("Attempt expired");return end
    if current.move==2 and current.clicked then
        if now-current.clickedAt>1.5 then attempt=nil;log("2: no success flash; 1/4 remain blocked");return end
        if now-current.clickedAt>=.15 then
            for object in pairs(overlays) do
                if not current.baseline[object] and redVisible(object) then
                    readyUntil=now+config.ReadySeconds;attempt=nil
                    log("2 CONFIRMED by red GUI: one use of 1 OR 4 armed");return
                end
            end
        end
        return
    end
    -- A matched playing track uses the original animation timing.
    -- Unmatched/stopped airborne 2 uses FOV-onset timing; legacy delay is opt-in.
    local track=current.track
    if current.move==2 and not track then current.air=current.air or airborne() end
    if current.move==2 and current.air and (not track or not track.IsPlaying) then
        local anchor=current.started
        local target=config.AirDelay2
        if config.AirCameraTiming then
            if not current.zoomStarted then
                if now-current.started>config.AirCameraTimeout then
                    attempt=nil;log("Air 2: no FOV zoom onset; skipped instead of guessing")
                end
                return
            end
            anchor=current.zoomStarted
            target=config.AirCameraPhase2
        end
        current.airAnchor=anchor;current.airTarget=target
        local elapsed=now-anchor
        if elapsed>=target then
            if elapsed-target>config.MaxLate then
                attempt=nil;log("Air 2: fallback deadline missed; skipped")
            else click(current) end
        end
        return
    end
    if not track then
        if config.CameraFallback and current.move~=2 then
            local elapsed=now-current.started
            local target=config["KeyDelay"..current.move]
            if elapsed>=target then
                if elapsed-target<=config.MaxLate and current.cameraOut
                    and now-current.cameraOut<=config.CameraCueAge then
                    current.source="camera";click(current)
                else
                    attempt=nil;log(tostring(current.move)..": no timely camera/animation cue; skipped")
                end
            end
        end
        return
    end
    if not track.IsPlaying then attempt=nil;log("Animation stopped before timing");return end
    local phase=track.TimePosition
    local target=config["Phase"..current.move]
    if phase>=target then
        if phase-target>config.MaxLate then attempt=nil;log("Timing passed: skipped late click")
        else click(current) end
    end
end
-- Check animation phase before rendering, plus Heartbeat for cleanup and success cues.
-- The clicked flag prevents duplicate input when both signals run in one frame.
if Run.PreRender then connect(Run.PreRender,step) end
connect(Run.Heartbeat,step)
env.BlackFlashMacro={
    Config=config,
    Stop=function()
        if stopped then return end
        stopped=true;reset()
        for _,connection in ipairs(connections) do connection:Disconnect() end
        env.BlackFlashMacro=nil
        log("Stopped")
    end,
}
log("Ready. F2 toggle, F3 reset, F10 stop. Press 2, then 1 OR 4 after confirmation.")
