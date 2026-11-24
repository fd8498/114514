--[[
    SBG Follow + Invis v2.1  —  The Strongest Battlegrounds
    Luau / Lua 客户端脚本
    F = 跟随启停   G = 隐身启停

    用法：
      Roblox Studio  -> StarterPlayer/StarterPlayerScripts 下建 LocalScript，粘贴运行
      客户端执行器    -> 直接 Execute
]]

--=====================================================================
-- 1. 服务
--=====================================================================
local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService     = game:GetService("TweenService")

local LP = Players.LocalPlayer
if not LP then
    Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
    LP = Players.LocalPlayer
end

local function myParts()
    local c = LP and LP.Character
    if not c then return nil, nil, nil end
    return c, c:FindFirstChild("HumanoidRootPart"), c:FindFirstChildOfClass("Humanoid")
end

local function clamp(v, a, b) return math.max(a, math.min(b, v)) end

--=====================================================================
-- 2. 配置
--=====================================================================
local C = {
    -- 跟随几何
    dist = 4.5, height = 0.0, sideAngle = 0.0, aimY = 1.2,

    -- 响应
    rigidness = 100, maxStep = 0, mode = "rigid",

    -- 行为
    lockTarget = nil, autoRotate = false, follow = false,
    keyFollow = Enum.KeyCode.H,

    -- 隐身
    invisOn         = false,
    invisMode       = "network",   -- "network" | "local" | "silent"
    invisAlpha      = 0,           -- 0 = 完全消失
    invisOutline    = true,        -- 本地幽灵轮廓
    invisMute       = true,        -- 静音脚步/工具音
    invisGuard      = true,        -- 每帧维持，抗服务端还原
    invisWithFollow = false,       -- 跟随时自动隐身
    keyInvis        = Enum.KeyCode.U,
    keyCam          = Enum.KeyCode.V,
    keyToggle       = Enum.KeyCode.RightAlt,     -- 显示 / 隐藏界面
    keyRhythm       = Enum.KeyCode.RightControl, -- 节奏自动玩
}

local S = {
    conns = {}, esp = {}, target = nil,
    ap = nil, ao = nil, att = nil,
    espChar = nil, alive = true,
}

-- 视角表前向声明（供 4 节的跟随逻辑引用）
local Cam

-- GUI 容器：执行器 → CoreGui → PlayerGui（客户端专属容器，实例不复制到服务端）
local function safeUiRoot()
    if gethui then
        local ok, h = pcall(gethui)
        if ok and h then return h end
    end
    local okCg, cg = pcall(function() return game:GetService("CoreGui") end)
    if okCg and cg then
        local can = pcall(function()
            local probe = Instance.new("Folder")
            probe.Name = "DSHProbe"
            probe.Parent = cg
            probe:Destroy()
        end)
        if can then return cg end
    end
    return LP:WaitForChild("PlayerGui")
end

local function put(name, conn)
    if S.conns[name] then pcall(function() S.conns[name]:Disconnect() end) end
    S.conns[name] = conn
    return conn
end

local function drop(name)
    if S.conns[name] then
        pcall(function() S.conns[name]:Disconnect() end)
        S.conns[name] = nil
    end
end

--=====================================================================
-- 3. 隐身引擎
--=====================================================================
local Invis = {
    origTr   = {},   -- [BasePart] = 原 Transparency
    origDec  = {},   -- [Decal/Texture] = 原 Transparency
    origSnd  = {},   -- [Sound] = 原 Volume
    origHl   = {},   -- [Highlight] = 原 Enabled
    origPart = {},   -- [BasePart] = 原 LocalTransparencyModifier
    origBB   = {},   -- [BillboardGui] = 原 Enabled
    origFx   = {},   -- [特效] = 原 Enabled
    outline  = nil,
    ghostAlpha = 0.5,
}

local function invisOutlineGui()
    return safeUiRoot()
end

local function buildOutline(char)
    if Invis.outline then pcall(function() Invis.outline:Destroy() end) end
    Invis.outline = nil
    if not C.invisOutline then return end

    local hl = Instance.new("Highlight")
    hl.Name = "InvisGhost"
    hl.Adornee = char
    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    hl.FillTransparency = 1
    hl.OutlineColor = Color3.fromRGB(90, 200, 255)
    hl.OutlineTransparency = 0.3
    hl.Parent = invisOutlineGui()   -- CoreGui：不复制，别人看不到
    Invis.outline = hl
end

local function clearOutline()
    if Invis.outline then pcall(function() Invis.outline:Destroy() end) end
    Invis.outline = nil
end

local function invisApply(char, first)
    if not char then return end

    for _, d in ipairs(char:GetDescendants()) do
        ---------------------------------------------------------------
        -- 模型本体
        ---------------------------------------------------------------
        if d:IsA("BasePart") then
            if first then
                Invis.origTr[d]   = d.Transparency
                Invis.origPart[d] = d.LocalTransparencyModifier
            end
            if C.invisMode == "local" then
                d.LocalTransparencyModifier = 1
            elseif C.invisMode == "network" then
                d.LocalTransparencyModifier = 0
                d.Transparency = C.invisAlpha
            elseif C.invisMode == "ghost" then
                -- 半透鬼影：跳过根部件、已透明部件、hitbox
                if d.Name ~= "HumanoidRootPart"
                and d.Transparency < 1
                and not d.Name:lower():find("hitbox") then
                    d.LocalTransparencyModifier = Invis.ghostAlpha
                end
            end
            -- silent 模式：Part 完全不动

        ---------------------------------------------------------------
        -- 贴图 / 贴花
        ---------------------------------------------------------------
        elseif d:IsA("Decal") or d:IsA("Texture") then
            if first then Invis.origDec[d] = d.Transparency end
            if C.invisMode ~= "silent" then
                d.Transparency = (C.invisMode == "local") and 0 or 1
            end

        ---------------------------------------------------------------
        -- 名字 / 血条 / 挂件 UI
        ---------------------------------------------------------------
        elseif d:IsA("BillboardGui") then
            if first then Invis.origBB[d] = d.Enabled end
            d.Enabled = false

        ---------------------------------------------------------------
        -- 粒子 / 拖尾 / 光束 / 游戏自带高亮
        ---------------------------------------------------------------
        elseif d:IsA("ParticleEmitter") or d:IsA("Trail")
            or d:IsA("Beam") or d:IsA("Smoke") or d:IsA("Fire")
            or d:IsA("Sparkles") then
            if first then Invis.origFx[d] = d.Enabled end
            d.Enabled = false

        elseif d:IsA("Highlight") then
            if first then Invis.origHl[d] = d.Enabled end
            d.Enabled = false

        ---------------------------------------------------------------
        -- 声音
        ---------------------------------------------------------------
        elseif d:IsA("Sound") then
            if first then Invis.origSnd[d] = d.Volume end
            if C.invisMute then d.Volume = 0 end
        end
    end

    ---------------------------------------------------------------
    -- Humanoid 名字与血条
    ---------------------------------------------------------------
    local hum = char:FindFirstChildOfClass("Humanoid")
    if hum then
        hum.DisplayDistanceType   = Enum.HumanoidDisplayDistanceType.None
        hum.HealthDisplayType     = Enum.HumanoidHealthDisplayType.AlwaysOff
        hum.NameDisplayDistance   = 0
        hum.HealthDisplayDistance = 0
    end

    if C.invisOutline and C.invisMode ~= "silent" then
        buildOutline(char)
    else
        clearOutline()
    end
end

local function invisRestore(char)
    if not char then return end

    for _, d in ipairs(char:GetDescendants()) do
        if d:IsA("BasePart") then
            if Invis.origTr[d] ~= nil then d.Transparency = Invis.origTr[d] end
            if Invis.origPart[d] ~= nil then d.LocalTransparencyModifier = Invis.origPart[d] end
        elseif d:IsA("Decal") or d:IsA("Texture") then
            if Invis.origDec[d] ~= nil then d.Transparency = Invis.origDec[d] end
        elseif d:IsA("BillboardGui") then
            if Invis.origBB[d] ~= nil then
                d.Enabled = Invis.origBB[d]
            end
        elseif d:IsA("ParticleEmitter") or d:IsA("Trail")
            or d:IsA("Beam") or d:IsA("Smoke") or d:IsA("Fire")
            or d:IsA("Sparkles") then
            if Invis.origFx[d] ~= nil then
                d.Enabled = Invis.origFx[d]
            end
        elseif d:IsA("Highlight") then
            if Invis.origHl[d] ~= nil then d.Enabled = Invis.origHl[d] end
        elseif d:IsA("Sound") then
            if Invis.origSnd[d] ~= nil then d.Volume = Invis.origSnd[d] end
        end
    end

    local hum = char:FindFirstChildOfClass("Humanoid")
    if hum then
        hum.DisplayDistanceType   = Enum.HumanoidDisplayDistanceType.Viewer
        hum.HealthDisplayType     = Enum.HumanoidHealthDisplayType.AlwaysOn
        hum.NameDisplayDistance   = 100
        hum.HealthDisplayDistance = 100
    end

    clearOutline()
    Invis.origTr, Invis.origDec, Invis.origSnd = {}, {}, {}
    Invis.origHl, Invis.origPart = {}, {}
    Invis.origBB, Invis.origFx = {}, {}
end

-- ---------------------------------------------------------------
-- 鬼影隐身：逐部件监听 LocalTransparencyModifier（Revenant 原版）
-- ---------------------------------------------------------------
local Ghost = {
    active = false,
    conns  = {},
}

local function ghostPart(p)
    if not p:IsA("BasePart") then return end
    if p.Name == "HumanoidRootPart" then return end
    if p.Transparency == 1 then return end
    if p.Name:lower():find("hitbox") then return end

    p.LocalTransparencyModifier = Invis.ghostAlpha

    local conn = p:GetPropertyChangedSignal("LocalTransparencyModifier"):Connect(function()
        if not Ghost.active then return end
        if p.LocalTransparencyModifier ~= Invis.ghostAlpha then
            p.LocalTransparencyModifier = Invis.ghostAlpha
        end
    end)
    table.insert(Ghost.conns, conn)
end

local function ghostChar(char)
    if not char then return end

    for _, d in ipairs(char:GetDescendants()) do
        ghostPart(d)
    end

    local conn = char.DescendantAdded:Connect(function(d)
        if Ghost.active then ghostPart(d) end
    end)
    table.insert(Ghost.conns, conn)

    pcall(function() char:SetAttribute("NoHeadLerp", true) end)
end

function ghostStop()
    if not Ghost.active then return end
    Ghost.active = false

    for _, c in ipairs(Ghost.conns) do
        pcall(function() c:Disconnect() end)
    end
    Ghost.conns = {}

    local char = LP.Character
    if char then
        for _, d in ipairs(char:GetDescendants()) do
            if d:IsA("BasePart") and d.Name ~= "HumanoidRootPart" then
                d.LocalTransparencyModifier = 0
            end
        end
        pcall(function() char:SetAttribute("NoHeadLerp", false) end)
    end
end

function ghostStart()
    if Ghost.active then
        ghostStop()
        return
    end

    local char = LP.Character
    if not char then return end
    if not char:FindFirstChildOfClass("Humanoid") then return end
    if not char:FindFirstChild("HumanoidRootPart") then return end

    Ghost.active = true
    Ghost.conns = {}
    ghostChar(char)
end

function invisStop()
    C.invisOn = false
    drop("invisGuard")
    ghostStop()
    -- 关闭瞬间先摘掉幽灵轮廓：不留任何过渡特效，硬切还原
    clearOutline()
    invisRestore(LP.Character)
end

function invisStart()
    C.invisOn = true
    drop("invisGuard")

    -- 鬼影：走 Revenant 原版逐部件监听实现
    if C.invisMode == "ghost" then
        invisApply(LP.Character, true)
        ghostStart()
        return
    end

    invisApply(LP.Character, true)

    -- 网络隐身维持守护：抗服务端刷回
    if C.invisGuard and C.invisMode == "network" then
        put("invisGuard", RunService.Heartbeat:Connect(function()
            if not C.invisOn then return end
            local c = LP.Character
            if not c then return end

            for _, d in ipairs(c:GetChildren()) do
                if d:IsA("BasePart") and d.Transparency ~= C.invisAlpha then
                    d.Transparency = C.invisAlpha
                end
                if d:IsA("Accessory") then
                    for _, h in ipairs(d:GetChildren()) do
                        if h:IsA("BasePart") and h.Transparency ~= C.invisAlpha then
                            h.Transparency = C.invisAlpha
                        end
                    end
                end
            end
        end))
    end
end

local function invisRefresh()
    if not C.invisOn then return end
    local char = LP.Character
    if not char then return end
    ghostStop()
    invisRestore(char)
    invisApply(char, true)
    if C.invisMode == "ghost" then
        ghostStart()
    end
end

--=====================================================================
-- 4. 跟随引擎
--=====================================================================
local function resolveTarget()
    if C.lockTarget and C.lockTarget.Parent and C.lockTarget.Character then
        return C.lockTarget
    end
    local _, myRoot = myParts()
    if not myRoot then return nil end

    local best, bestD = nil, math.huge
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LP and p.Character and p.Character:FindFirstChild("HumanoidRootPart") then
            local d = (p.Character.HumanoidRootPart.Position - myRoot.Position).Magnitude
            if d < bestD then best, bestD = p, d end
        end
    end
    return best
end

local function computeSlot(tRoot)
    local back = tRoot.CFrame.LookVector * -1
    if C.sideAngle ~= 0 then
        back = CFrame.Angles(0, math.rad(C.sideAngle), 0) * back
    end
    local pos = tRoot.Position + back.Unit * C.dist + Vector3.new(0, C.height, 0)
    local aim = tRoot.Position + Vector3.new(0, C.aimY, 0)
    return pos, aim
end

local function buildPhysics(root)
    local att = root:FindFirstChild("SBGAtt")
    if not att then
        att = Instance.new("Attachment")
        att.Name = "SBGAtt"
        att.Parent = root
    end
    S.att = att

    if S.ap then pcall(function() S.ap:Destroy() end) end
    if S.ao then pcall(function() S.ao:Destroy() end) end

    local ap = Instance.new("AlignPosition")
    ap.Mode = Enum.PositionAlignmentMode.OneAttachment
    ap.Attachment0 = att
    ap.MaxForce = math.huge
    ap.MaxVelocity = math.huge
    ap.Responsiveness = 200
    ap.Parent = root
    S.ap = ap

    local ao = Instance.new("AlignOrientation")
    ao.Mode = Enum.OrientationAlignmentMode.OneAttachment
    ao.Attachment0 = att
    ao.MaxTorque = math.huge
    ao.MaxAngularVelocity = math.huge
    ao.Responsiveness = 200
    ao.Parent = root
    S.ao = ao
end

local function teardownPhysics()
    if S.ap then pcall(function() S.ap:Destroy() end); S.ap = nil end
    if S.ao then pcall(function() S.ao:Destroy() end); S.ao = nil end
    if S.att then pcall(function() S.att:Destroy() end); S.att = nil end
end

function stopFollow()
    C.follow = false
    drop("follow")
    drop("physLoop")
    pcall(function() RunService:UnbindFromRenderStep("SBG_Follow") end)
    teardownPhysics()
    local _, _, hum = myParts()
    if hum then
        hum.AutoRotate = true
        hum.PlatformStand = false
    end
end

function startFollow()
    stopFollow()
    C.follow = true

    local _, myRoot, hum = myParts()
    if hum then
        hum.AutoRotate = C.autoRotate
        hum.PlatformStand = false
    end
    if C.mode == "physics" and myRoot then
        buildPhysics(myRoot)
    end
    if C.invisWithFollow and not C.invisOn then
        invisStart()
    end
    if Cam.autoWithFollow and not Cam.on then
        camStart()
    end

    -------------------------------------------------------------------
    -- 刚性模式：RenderStepped 每帧直设 CFrame（零延迟）
    -------------------------------------------------------------------
    if C.mode == "rigid" then
        local function step(dt)
            if not C.follow then return end

            local tgt = resolveTarget()
            S.target = tgt
            if not tgt or not tgt.Character then return end

            local _, root, h = myParts()
            if not root or not h or h.Health <= 0 then
                task.defer(stopFollow)
                return
            end

            local tRoot = tgt.Character:FindFirstChild("HumanoidRootPart")
            if not tRoot then return end

            local want, aim = computeSlot(tRoot)
            local alpha = clamp(C.rigidness / 100, 0.01, 1)

            if C.maxStep > 0 and alpha < 1 then
                local delta = want - root.Position
                if delta.Magnitude > C.maxStep then
                    want = root.Position + delta.Unit * C.maxStep
                end
            end

            local pos = (alpha >= 1) and want or root.Position:Lerp(want, alpha)
            root.CFrame = CFrame.lookAt(pos, aim)
            root.AssemblyLinearVelocity = Vector3.zero
        end

        -- 绑到相机优先级之前：本帧先定位角色，相机随后读最新位置
        pcall(function() RunService:UnbindFromRenderStep("SBG_Follow") end)
        RunService:BindToRenderStep("SBG_Follow",
            Enum.RenderPriority.Camera.Value - 1, step)

    -------------------------------------------------------------------
    -- 物理模式：AlignPosition/AlignOrientation（抗回拉）
    -------------------------------------------------------------------
    else
        put("physLoop", RunService.Stepped:Connect(function()
            if not C.follow then return end

            local _, root = myParts()
            if not root then return end
            if S.ap and S.ap.Parent ~= root then buildPhysics(root) end
            if not S.ap then return end

            local tgt = resolveTarget()
            S.target = tgt
            if not tgt or not tgt.Character then return end

            local tRoot = tgt.Character:FindFirstChild("HumanoidRootPart")
            if not tRoot then return end

            local want, aim = computeSlot(tRoot)
            local resp = clamp(C.rigidness / 100, 0.05, 1) * 240

            S.ap.Position = want
            S.ap.Responsiveness = resp
            S.ao.CFrame = CFrame.lookAt(want, aim)
            S.ao.Responsiveness = resp
        end))
    end
end

-- 角色重生
put("charAdded", LP.CharacterAdded:Connect(function(char)
    stopFollow()
    task.wait(0.35)
    if C.follow then startFollow() end
    if C.invisOn then
        task.wait(0.15)
        invisApply(char, true)
        if C.invisMode == "ghost" then
            ghostStart()
        elseif C.invisGuard and C.invisMode == "network" then
            invisStart()
        end
    end
    if Cam and Cam.on then
        task.wait(0.1)
        camStart()
    end
end))

-- 目标消失后自动释放锁定
task.spawn(function()
    while S.alive do
        task.wait(0.4)
        if C.follow and C.lockTarget then
            if not (C.lockTarget.Parent and C.lockTarget.Character) then
                C.lockTarget = nil
            end
        end
    end
end)

-- 目标高亮
local function clearEsp()
    for _, o in pairs(S.esp) do pcall(function() o:Destroy() end) end
    S.esp = {}
end

put("espRefresh", RunService.Heartbeat:Connect(function()
    local tc = S.target and S.target.Character or nil
    if tc == S.espChar then return end
    clearEsp()
    S.espChar = tc
    if tc then
        local hl = Instance.new("Highlight")
        hl.Adornee = tc
        hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        hl.FillColor = Color3.fromRGB(255, 190, 40)
        hl.FillTransparency = 0.78
        hl.OutlineColor = Color3.fromRGB(255, 220, 80)
        hl.Parent = tc
        S.esp[tc] = hl
    end
end))

--=====================================================================
-- 4.5 视角锁定
--=====================================================================
Cam = {
    on       = false,
    mode     = "lock",   -- "lock" 绕玩家 / "orbit" 绕目标
    dist     = 14,
    height   = 2.5,
    aimY     = 1.2,
    pitch    = 12,
    yaw      = 0,
    fov      = 70,
    smooth   = 100,
    mouse    = false,
    sens     = 0.18,
    clip     = true,
    autoWithFollow = false,
    cur      = nil,
    origType = nil,
    origFov  = nil,
    bindName = "SBG_Cam",
}

local function camLoop(dt)
    if not Cam.on then return end
    local cam = workspace.CurrentCamera
    if not cam then return end

    local tgt = S.target or resolveTarget()
    S.target = tgt
    if not (tgt and tgt.Character) then return end

    local tRoot = tgt.Character:FindFirstChild("HumanoidRootPart")
    if not tRoot then return end

    -------------------------------------------------------------------
    -- 瞄准锁定：只改朝向，位置交给 Roblox 默认相机（Revenant 相机模式）
    -------------------------------------------------------------------
    if Cam.mode == "aim" then
        local ch = tgt.Character
        if ch:FindFirstChild("BeingGrabbed")
        or ch:GetAttribute("BeingGrabbed")
        or ch:FindFirstChild("AbsoluteImmortal")
        or ch:FindFirstChildOfClass("ForceField") then
            return
        end
        local torso = ch:FindFirstChild("Torso")
            or ch:FindFirstChild("UpperTorso")
            or tRoot
        pcall(function()
            cam.CFrame = CFrame.new(cam.CFrame.Position, torso.Position)
        end)
        return
    end

    local _, myRoot = myParts()

    local aimPos = tRoot.Position + Vector3.new(0, Cam.aimY, 0)
    local pivot
    if Cam.mode == "orbit" then
        pivot = aimPos
    else
        pivot = (myRoot and myRoot.Position or aimPos) + Vector3.new(0, Cam.height, 0)
    end

    -- 水平基准方向：从目标指向支点
    local horiz
    if Cam.mode == "orbit" then
        local mp = myRoot and myRoot.Position or (aimPos + Vector3.new(0, 0, 8))
        horiz = Vector3.new(mp.X - aimPos.X, 0, mp.Z - aimPos.Z)
    else
        horiz = Vector3.new(pivot.X - aimPos.X, 0, pivot.Z - aimPos.Z)
    end
    if horiz.Magnitude < 0.1 then
        horiz = Vector3.new(0, 0, 1)
    else
        horiz = horiz.Unit
    end

    local yaw = math.rad(Cam.yaw)
    local pitch = math.rad(Cam.pitch)
    local cy, sy = math.cos(yaw), math.sin(yaw)
    local dirH = Vector3.new(
        horiz.X * cy + horiz.Z * sy, 0,
        -horiz.X * sy + horiz.Z * cy)

    local offset = dirH * (Cam.dist * math.cos(pitch))
        + Vector3.new(0, Cam.dist * math.sin(pitch), 0)
    local camPos = pivot + offset

    -- 遮挡收缩：相机与目标之间被挡就贴近遮挡点
    if Cam.clip then
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        local filter = {}
        if LP.Character then filter[#filter + 1] = LP.Character end
        if tgt.Character then filter[#filter + 1] = tgt.Character end
        params.FilterDescendantsInstances = filter
        local hit = workspace:Raycast(aimPos, camPos - aimPos, params)
        if hit then
            local back = aimPos - hit.Position
            if back.Magnitude > 0.6 then
                camPos = hit.Position + back.Unit * 0.6
            end
        end
    end

    local want = CFrame.lookAt(camPos, aimPos)
    local a = clamp(Cam.smooth / 100, 0.02, 1)
    if a >= 1 or not Cam.cur then
        cam.CFrame = want
        Cam.cur = want
    else
        Cam.cur = Cam.cur:Lerp(want, a)
        cam.CFrame = Cam.cur
    end
end

function camStart()
    local cam = workspace.CurrentCamera
    if cam then
        if not Cam.on then
            Cam.origType = cam.CameraType
            Cam.origFov = cam.FieldOfView
        end
        -- aim 模式保留默认相机位置逻辑，只覆盖朝向
        if Cam.mode ~= "aim" then
            cam.CameraType = Enum.CameraType.Scriptable
        end
        cam.FieldOfView = Cam.fov
    end
    Cam.on = true
    Cam.cur = nil
    pcall(function() RunService:UnbindFromRenderStep(Cam.bindName) end)
    RunService:BindToRenderStep(Cam.bindName,
        Enum.RenderPriority.Camera.Value + 1, camLoop)
end

function camStop()
    Cam.on = false
    Cam.cur = nil
    pcall(function() RunService:UnbindFromRenderStep(Cam.bindName) end)
    local cam = workspace.CurrentCamera
    if cam then
        cam.CameraType = Cam.origType or Enum.CameraType.Custom
        cam.FieldOfView = Cam.origFov or 70
    end
end

function camRefresh()
    if not Cam.on then return end
    local cam = workspace.CurrentCamera
    if cam then cam.FieldOfView = Cam.fov end
end

-- 鼠标环绕
UserInputService.InputChanged:Connect(function(i)
    if not (Cam.on and Cam.mouse) then return end
    if i.UserInputType ~= Enum.UserInputType.MouseMovement then return end
    Cam.yaw = Cam.yaw - i.Delta.X * Cam.sens
    Cam.pitch = clamp(Cam.pitch + i.Delta.Y * Cam.sens, -80, 80)
end)

--=====================================================================
-- 4.6 节奏自动玩（周五夜放克）
--=====================================================================
local R = {
    on        = false,
    mode      = "chart",   -- "chart" 谱面驱动 | "visual" 画面驱动
    leadMs    = 0,         -- 提前量（毫秒）
    windowPx  = 46,        -- 视觉模式判定窗口（像素）
    laneKeys  = {
        left  = Enum.KeyCode.D,
        down  = Enum.KeyCode.F,
        up    = Enum.KeyCode.J,
        right = Enum.KeyCode.K,
    },
    clock     = nil,
    notes     = nil,
    cursor    = 1,
    fired     = 0,
    source    = "未扫描",
    held      = {},
    firedUI   = {},
    bindName  = "SBG_Rhythm",
    lastInfo  = 0,
    lastScan  = 0,
}

local LANE_NAMES = { "left", "down", "up", "right" }

-- VirtualInputManager 只在 Studio / 部分执行器环境存在
local VIM
pcall(function()
    VIM = game:GetService("VirtualInputManager")
end)

local function laneFromIndex(i)
    i = tonumber(i)
    if not i then return nil end
    i = math.floor(i) % 4
    return LANE_NAMES[i + 1]
end

-- ---------------------------------------------------------------
-- 时钟：找正在播放的长音轨
-- ---------------------------------------------------------------
local function scanSounds(minLen)
    local cands = {}
    local function scan(root)
        pcall(function()
            for _, d in ipairs(root:GetDescendants()) do
                if d:IsA("Sound") and d.IsPlaying and d.TimeLength > (minLen or 1) then
                    cands[#cands + 1] = d
                end
            end
        end)
    end

    scan(workspace)
    pcall(function() scan(game:GetService("SoundService")) end)
    pcall(function() scan(game:GetService("ReplicatedStorage")) end)
    pcall(function()
        local pg = LP and LP:FindFirstChild("PlayerGui")
        if pg then scan(pg) end
    end)
    pcall(function()
        local cam = workspace.CurrentCamera
        if cam then scan(cam) end
    end)

    return cands
end

local function findClock()
    local cands = scanSounds(1)
    if #cands == 0 then return nil end
    table.sort(cands, function(a, b) return a.TimeLength > b.TimeLength end)
    return cands[1]
end

-- ---------------------------------------------------------------
-- 谱面：扫描 ModuleScript 里的 note 表
-- ---------------------------------------------------------------
local function normalizeNote(raw)
    if type(raw) ~= "table" then return nil end
    local t = raw.strumTime or raw.time or raw.t or raw.songTime
    local d = raw.noteData or raw.direction or raw.lane or raw.note or raw.d
    if type(t) ~= "number" or type(d) ~= "number" then return nil end
    local lane = laneFromIndex(d)
    if not lane then return nil end
    return { time = t, lane = lane }
end

local function collectNotes(tbl, out, depth)
    if depth > 5 or type(tbl) ~= "table" then return end
    local n = normalizeNote(tbl)
    if n then
        out[#out + 1] = n
        return
    end
    for _, v in pairs(tbl) do
        if type(v) == "table" then
            collectNotes(v, out, depth + 1)
        end
    end
end

local function findChart()
    local rs = game:GetService("ReplicatedStorage")
    local best, bestSrc = nil, nil

    local ok = pcall(function()
        for _, d in ipairs(rs:GetDescendants()) do
            if d:IsA("ModuleScript") then
                local nm = d.Name:lower()
                if nm:find("song") or nm:find("chart") or nm:find("note")
                or nm:find("level") or nm:find("music") or nm:find("week")
                or nm:find("track") then
                    local ok2, mod = pcall(require, d)
                    if ok2 and type(mod) == "table" then
                        local out = {}
                        collectNotes(mod, out, 0)
                        if #out > 8 and (not best or #out > #best) then
                            table.sort(out, function(a, b) return a.time < b.time end)
                            best, bestSrc = out, d:GetFullName()
                        end
                    end
                end
            end
        end
    end)

    if not ok and not best then
        return nil, "扫描出错"
    end
    return best, bestSrc
end

-- ---------------------------------------------------------------
-- 按键发射
-- ---------------------------------------------------------------
local function pressKey(code)
    if not code then return end
    pcall(function()
        -- 执行器的 keypress 模拟真实硬件，游戏一定能收到
        if keypress then
            keypress(code.Name)
        elseif VIM then
            VIM:SendKeyEvent(true, code, false, game)
        end
    end)
    R.held[code] = true
    task.delay(0.02, function()
        pcall(function()
            if keyrelease then
                keyrelease(code.Name)
            elseif VIM then
                VIM:SendKeyEvent(false, code, false, game)
            end
        end)
        R.held[code] = nil
    end)
end

local function releaseAll()
    for code in pairs(R.held) do
        pcall(function()
            if keyrelease then
                keyrelease(code.Name)
            elseif VIM then
                VIM:SendKeyEvent(false, code, false, game)
            end
        end)
        R.held[code] = nil
    end
end

-- ---------------------------------------------------------------
-- 视觉模式：按屏幕箭头位置逼近判定线
-- ---------------------------------------------------------------
local function visualTick()
    local pg = LP and LP:FindFirstChild("PlayerGui")
    if not pg then return end

    local strumX, strumY = {}, {}
    local notes = {}

    pcall(function()
        for _, d in ipairs(pg:GetDescendants()) do
            if d:IsA("ImageLabel") and d.Visible and d.Image ~= "" then
                local nm = d.Name:lower()
                if nm:find("strum") then
                    local x = math.floor(d.AbsolutePosition.X / 8)
                    strumX[x] = d.AbsolutePosition
                elseif nm:find("note") or nm:find("arrow") then
                    notes[#notes + 1] = d
                end
            end
        end
    end)

    for _, n in ipairs(notes) do
        if not R.firedUI[n] and n.Parent then
            local p = n.AbsolutePosition
            local col = math.floor(p.X / 8)
            local line = strumX[col]
            if line and math.abs(p.Y - line.Y) <= R.windowPx then
                R.firedUI[n] = true
                local idx = math.clamp(math.floor(p.X / 64) % 4, 0, 3)
                local lane = LANE_NAMES[idx + 1]
                pressKey(R.laneKeys[lane])
                R.fired = R.fired + 1
            end
        end
    end

    -- 清理已销毁的 UI 记录
    R.uiTick = (R.uiTick or 0) + 1
    if R.uiTick % 90 == 0 then
        local clean = {}
        for k, v in pairs(R.firedUI) do
            if k.Parent then clean[k] = v end
        end
        R.firedUI = clean
    end
end

-- ---------------------------------------------------------------
-- 主循环
-- ---------------------------------------------------------------
local function rhythmTick()
    if not R.on then return end

    if not R.clock or not R.clock.Parent or not R.clock.IsPlaying then
        local now = os.clock()
        if now - R.lastScan > 1.2 then
            R.lastScan = now
            R.clock = findClock()
        end
    end

    if R.mode == "visual" then
        visualTick()
        return
    end

    local clock = R.clock
    if not clock or not clock.IsPlaying then return end
    if not R.notes then return end

    local t = clock.TimePosition * 1000 + R.leadMs

    while R.cursor <= #R.notes do
        local n = R.notes[R.cursor]
        if n.time <= t then
            pressKey(R.laneKeys[n.lane])
            R.fired = R.fired + 1
            R.cursor = R.cursor + 1
        else
            break
        end
    end
end

function rhythmStart()
    R.on = true
    R.cursor = 1
    R.fired = 0
    R.firedUI = {}
    R.clock = findClock()

    if R.mode == "chart" and not R.notes then
        local notes, src = findChart()
        R.notes = notes
        R.source = src or "未找到谱面"
    end

    -- 谱面驱动拿不到谱面时自动退回画面驱动，避免整段空转
    if R.mode == "chart" and not R.notes then
        R.mode = "visual"
        R.source = "无谱面 · 自动切画面驱动"
        print("[SBG Rhythm] 未找到谱面模块，已切到画面驱动")
    end

    if not R.clock then
        print("[SBG Rhythm] 未找到播放中的音轨，谱面模式将等待音乐")
    end

    pcall(function() RunService:UnbindFromRenderStep(R.bindName) end)
    RunService:BindToRenderStep(R.bindName,
        Enum.RenderPriority.Camera.Value + 2, rhythmTick)
end

function rhythmStop()
    R.on = false
    pcall(function() RunService:UnbindFromRenderStep(R.bindName) end)
    releaseAll()
end

function rhythmRescan()
    R.notes = nil
    R.cursor = 1
    R.clock = findClock()
    local notes, src = findChart()
    R.notes = notes
    R.source = src or "未找到谱面"
    return notes ~= nil
end

-- ---------------------------------------------------------------
-- 诊断：把关键信息打到控制台
-- ---------------------------------------------------------------
function rhythmDiagnose()
    local out = {}
    local cands = scanSounds(1)

    out[#out + 1] = "音轨候选: " .. #cands
    for i = 1, math.min(#cands, 5) do
        local s = cands[i]
        out[#out + 1] = string.format("  %d) %s  %.1fs  playing=%s  at=%s",
            i, s.Name, s.TimeLength, tostring(s.IsPlaying),
            s.Parent and s.Parent:GetFullName() or "?")
    end

    local notes, src = findChart()
    if notes then
        out[#out + 1] = string.format("谱面: %d 条  @ %s", #notes, src)
        if notes[1] then
            out[#out + 1] = string.format("  首条: t=%.0f lane=%s",
                notes[1].time, notes[1].lane)
        end
    else
        out[#out + 1] = "谱面: 未找到（ReplicatedStorage 内无匹配模块）"
    end

    out[#out + 1] = "按键后端: "
        .. (keypress and "keypress(执行器)" or (VIM and "VirtualInputManager" or "无"))
    out[#out + 1] = string.format("映射: %s / %s / %s / %s",
        R.laneKeys.left.Name, R.laneKeys.down.Name,
        R.laneKeys.up.Name, R.laneKeys.right.Name)

    local txt = table.concat(out, "\n")
    print("[SBG Rhythm] 诊断\n" .. txt)
    return txt
end

-- 发一次测试按键，用来判断游戏是否吃我们发的键
function rhythmTestKey(lane)
    local key = R.laneKeys[lane or "left"]
    pressKey(key)
    print("[SBG Rhythm] 已发送测试按键: " .. tostring(key and key.Name))
    return key and key.Name or "?"
end

--=====================================================================
-- 4.7 战场增强（算法移植自 Revenant_TSB）
--=====================================================================
local Aim = {
    on         = false,
    prediction = 0.1,
    autoPred   = true,
    keepY      = false,
    bindName   = "SBG_Aim",
}

local Mv = {
    on       = false,
    speed    = 120,
    bindName = "SBG_Move",
}

local Fly = {
    on       = false,
    speed    = 55,
    bindName = "SBG_Fly",
}

local AF = {
    on       = false,
    acc      = 0,
    bindName = "SBG_AF",
}

local function pingPrediction()
    local ok, p = pcall(function()
        return game:GetService("Stats").Network.ServerStatsItem["Data Ping"]:GetValue()
    end)
    if ok and type(p) == "number" and p > 0 then
        return clamp(p / 1000, 0.1, 1)
    end
    return nil
end

-- 瞄准锁定：角色朝向「目标位置 + 目标速度 × 预测」
local function aimTick()
    if not Aim.on then return end
    local tgt = resolveTarget()
    if not (tgt and tgt.Character) then return end

    local _, myRoot, hum = myParts()
    if not (myRoot and hum) then return end
    if myRoot:FindFirstChild("Ragdoll") then return end

    local tRoot = tgt.Character:FindFirstChild("HumanoidRootPart")
    local torso = tgt.Character:FindFirstChild("Torso") or tRoot
    if not (tRoot and torso) then return end

    local pred = Aim.prediction
    if Aim.autoPred then
        pred = pingPrediction() or Aim.prediction
    end

    local pos = myRoot.Position
    local aimPos = Vector3.new(
        torso.Position.X,
        Aim.keepY and pos.Y or torso.Position.Y,
        torso.Position.Z
    ) + tRoot.AssemblyLinearVelocity * pred

    hum.AutoRotate = false
    myRoot.CFrame = CFrame.new(pos, aimPos)
end

-- 加速：沿移动方向做 CFrame 推进
local function moveTick()
    if not Mv.on then return end
    local _, root, hum = myParts()
    if not (root and hum) then return end
    if Fly.on then return end
    local dir = hum.MoveDirection
    if dir.Magnitude < 0.05 then return end
    root.CFrame = root.CFrame + dir * (Mv.speed / 10000)
end

-- 飞行：相机方向 + MoveDirection 投影
local function flyTick()
    if not Fly.on then return end
    local _, root, hum = myParts()
    local cam = workspace.CurrentCamera
    if not (root and hum and cam) then return end

    local look = cam.CFrame.LookVector
    local right = cam.CFrame.RightVector
    local md = hum.MoveDirection

    local f = math.floor(md:Dot(look) + 0.5)
    local r = math.floor(md:Dot(right) + 0.5)

    local vel = Vector3.zero
    if f == 1 then vel = vel + look * Fly.speed end
    if f == -1 then vel = vel + look * -Fly.speed end
    if r == -1 then vel = vel + right * -Fly.speed end
    if r == 1 then vel = vel + right * Fly.speed end

    if f == 0 and r == 0 then
        root.Velocity = Vector3.zero
    else
        root.Velocity = vel
    end

    root.RotVelocity = Vector3.zero
    root.CFrame = CFrame.new(root.CFrame.Position, root.CFrame.Position + look)
end

-- 防甩飞：每 0.5 秒给其他玩家角色做 noclip
local function afTick(dt)
    if not AF.on then return end
    AF.acc = AF.acc + dt
    if AF.acc < 0.5 then return end
    AF.acc = 0

    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LP and p.Character then
            for _, d in ipairs(p.Character:GetDescendants()) do
                if d:IsA("BasePart") and d.CanCollide then
                    d.CanCollide = false
                end
            end
        end
    end
end

local function extTick()
    aimTick()
    moveTick()
    flyTick()
end

function extStart()
    pcall(function() RunService:UnbindFromRenderStep("SBG_Ext") end)
    RunService:BindToRenderStep("SBG_Ext",
        Enum.RenderPriority.Camera.Value + 3, extTick)
    pcall(function() RunService:UnbindFromRenderStep("SBG_AF") end)
    RunService:BindToRenderStep("SBG_AF",
        Enum.RenderPriority.Camera.Value + 4,
        function(dt) afTick(dt) end)
end

function extStop()
    pcall(function() RunService:UnbindFromRenderStep("SBG_Ext") end)
    pcall(function() RunService:UnbindFromRenderStep("SBG_AF") end)
    -- 还原被关闭的移动状态
    local _, root, hum = myParts()
    if hum then hum.AutoRotate = true end
    if root then root.Velocity = Vector3.zero end
end

--=====================================================================
-- 4.8 死亡反击标记（Revenant ShowDeathCounter 移植）
--=====================================================================
local DC = {
    on    = false,
    fx    = false,
    acc   = 0,
    marks = {},
    conn  = nil,
}

local function counterAcc(char)
    for _, d in ipairs(char:GetChildren()) do
        if d:IsA("Accessory") and d.Name == "Counter" then
            return d
        end
    end
    return nil
end

local function deathCount(player)
    local ls = player:FindFirstChild("leaderstats")
    if ls then
        local d = ls:FindFirstChild("Deaths") or ls:FindFirstChild("Death")
        if d and type(d.Value) == "number" then return d.Value end
    end
    local c = player.Character
    if c then
        local v = c:GetAttribute("Deaths")
        if type(v) == "number" then return v end
    end
    return nil
end

local function clearMark(player)
    local m = DC.marks[player]
    if not m then return end
    if m.hl then pcall(function() m.hl:Destroy() end) end
    if m.bb then pcall(function() m.bb:Destroy() end) end
    DC.marks[player] = nil
end

local function playMenacing(char)
    local ok, gui = pcall(function()
        local rs = game:GetService("ReplicatedStorage")
        return rs:FindFirstChild("Resources")
            :FindFirstChild("LegacyReplication")
            :FindFirstChild("Menacing")
    end)
    if not ok or not gui then return end
    local root = char:FindFirstChild("HumanoidRootPart")
    if not root then return end
    local clone = gui:Clone()
    clone.Enabled = true
    clone.Parent = root
    task.delay(2.2, function() pcall(function() clone:Destroy() end) end)
end

local function setMark(player, char)
    local root = char:FindFirstChild("HumanoidRootPart")
    if not root then return end
    if DC.marks[player] then return end

    local hl = Instance.new("Highlight")
    hl.Name = "SBG_CounterHL"
    hl.Adornee = char
    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    hl.FillColor = Color3.fromRGB(255, 70, 70)
    hl.FillTransparency = 0.65
    hl.OutlineColor = Color3.fromRGB(255, 90, 90)
    hl.OutlineTransparency = 0
    hl.Parent = char

    local bb = Instance.new("BillboardGui")
    bb.Name = "SBG_CounterBB"
    bb.Adornee = root
    bb.Size = UDim2.fromOffset(170, 34)
    bb.StudsOffset = Vector3.new(0, 3.2, 0)
    bb.AlwaysOnTop = true
    bb.Parent = root

    local lbl = Instance.new("TextLabel")
    lbl.BackgroundTransparency = 1
    lbl.Size = UDim2.fromScale(1, 1)
    lbl.Font = Enum.Font.GothamBold
    lbl.TextSize = 14
    lbl.TextColor3 = Color3.fromRGB(255, 92, 92)
    lbl.TextStrokeTransparency = 0.35
    lbl.Text = "死亡反击"
    lbl.Parent = bb

    DC.marks[player] = { hl = hl, bb = bb, label = lbl, char = char }

    if DC.fx then
        playMenacing(char)
    end
end

local function dcScan()
    -- 清理已离开玩家的残留标记
    local stale = {}
    for p in pairs(DC.marks) do
        if not p.Parent then stale[#stale + 1] = p end
    end
    for _, p in ipairs(stale) do clearMark(p) end

    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LP then
            local char = p.Character
            local m = DC.marks[p]

            -- 角色换了或标记失效，先清掉
            if m and (m.char ~= char or not m.hl or not m.hl.Parent) then
                clearMark(p)
                m = nil
            end

            if char and counterAcc(char) then
                if not m then setMark(p, char) end
                local mm = DC.marks[p]
                if mm and mm.label then
                    local dv = deathCount(p)
                    mm.label.Text = dv
                        and ("死亡反击 · 死亡 " .. tostring(dv))
                        or "死亡反击"
                end
            elseif m then
                clearMark(p)
            end
        end
    end
end

local function dcTick(dt)
    if not DC.on then return end
    DC.acc = DC.acc + dt
    if DC.acc < 0.25 then return end
    DC.acc = 0
    dcScan()
end

function dcStart()
    DC.on = true
    dcScan()
    if DC.conn then pcall(function() DC.conn:Disconnect() end) end
    DC.conn = RunService.Heartbeat:Connect(dcTick)
end

function dcStop()
    DC.on = false
    if DC.conn then
        pcall(function() DC.conn:Disconnect() end)
        DC.conn = nil
    end
    local keys = {}
    for p in pairs(DC.marks) do keys[#keys + 1] = p end
    for _, p in ipairs(keys) do clearMark(p) end
end

--=====================================================================
-- 4.9 瞬移贴背（吸收 Revenant 的 Ragdoll / Grabbed 判定）
--=====================================================================
local TP = {
    on          = false,
    dist        = 3.2,
    height      = 0,
    minGap      = 0.03,
    onlyRagdoll = false,
    skipGrabbed = true,
    acc         = 0,
    bindName    = "SBG_TPBack",
}

local function isRagdoll(char)
    if not char then return false end
    if char:FindFirstChild("Ragdoll") then return true end
    return false
end

local function tpBackTick(dt)
    if not TP.on then return end

    TP.acc = TP.acc + dt
    if TP.acc < TP.minGap then return end
    TP.acc = 0

    local tgt = resolveTarget()
    if not (tgt and tgt.Character) then return end

    local tChar = tgt.Character
    local tRoot = tChar:FindFirstChild("HumanoidRootPart")
    if not tRoot then return end

    local myChar, myRoot, hum = myParts()
    if not (myChar and myRoot and hum) then return end

    -- 自身被 ragdoll 时不动，避免卡死
    if isRagdoll(myChar) then return end

    -- 目标被抓取 / 无敌时不穿
    if TP.skipGrabbed then
        if tChar:FindFirstChild("BeingGrabbed")
        or tChar:GetAttribute("BeingGrabbed")
        or tChar:FindFirstChildOfClass("ForceField") then
            return
        end
    end

    -- 只在目标硬直（ragdoll）时贴背
    if TP.onlyRagdoll and not isRagdoll(tChar) then return end

    local cf   = tRoot.CFrame
    local slot = cf.Position - cf.LookVector * TP.dist + Vector3.new(0, TP.height, 0)
    local look = CFrame.lookAt(slot, tRoot.Position + Vector3.new(0, 1.2, 0))

    hum.AutoRotate = false
    pcall(function() hum.CameraOffset = Vector3.zero end)
    myRoot.AssemblyLinearVelocity = Vector3.zero
    myRoot.CFrame = look
end

function tpBackStart()
    TP.on = true
    TP.acc = 0
    if C.follow then stopFollow() end
    pcall(function() RunService:UnbindFromRenderStep(TP.bindName) end)
    RunService:BindToRenderStep(TP.bindName,
        Enum.RenderPriority.Camera.Value + 5, tpBackTick)
end

function tpBackStop()
    TP.on = false
    pcall(function() RunService:UnbindFromRenderStep(TP.bindName) end)
    local _, _, hum = myParts()
    if hum then hum.AutoRotate = true end
end

--=====================================================================
-- 4.10 平台伪装（设备图标：手机 / 电脑）
--=====================================================================
local PF = {
    on        = false,
    mode      = "mobile",   -- "mobile" | "pc"
    hooked    = false,      -- namecall 钩子已装
    uisHooked = false,
    uid       = "SBG_Platform",
}

local MOBILE_KEYS = {
    IsMobile = true, Mobile = true, IsTouch = true, Touch = true,
    TouchEnabled = true, IsTouchDevice = true, DeviceType = true,
    Platform = true, Device = true, DeviceKind = true, IsPC = true,
    KeyboardEnabled = true, IsDesktop = true, IsPhone = true,
    IsMobileDevice = true, MobileMode = true,
}

local function wantMobile()
    return PF.mode == "mobile"
end

local function rewriteValue(v, key)
    local k = tostring(key)
    if not MOBILE_KEYS[k] then return nil end

    if type(v) == "boolean" then
        if k == "KeyboardEnabled" or k == "IsPC" or k == "IsDesktop" then
            return not wantMobile()
        end
        return wantMobile()
    end

    if type(v) == "string" then
        local low = v:lower()
        if low:find("mobile") or low:find("phone") or low:find("touch")
        or low:find("pc") or low:find("desktop") or low:find("keyboard")
        or low:find("computer") then
            return wantMobile() and "Mobile" or "PC"
        end
    end

    if type(v) == "number" and (k == "DeviceType" or k == "Device") then
        return wantMobile() and 1 or 0
    end

    return nil

end

local function deepRewrite(t, depth)
    if type(t) ~= "table" or depth > 3 then return end
    for k, v in pairs(t) do
        local nv = rewriteValue(v, k)
        if nv ~= nil then
            pcall(function() t[k] = nv end)
        elseif type(v) == "table" then
            deepRewrite(v, depth + 1)
        end
    end
end

local function installPlatformHooks()
    if PF.hooked and PF.uisHooked then return true end

    local uis = game:GetService("UserInputService")

    -- 1. namecall：拦截 FireServer / InvokeServer / IsTouchDevice
    if not PF.hooked then
        local ok = pcall(function()
            local mt = getrawmetatable(game)
            local old = mt.__namecall
            setreadonly(mt, false)
            mt.__namecall = newcclosure(function(self, ...)
                local method = getnamecallmethod()

                if PF.on then
                    if rawequal(self, uis) then
                        if method == "IsTouchDevice" then
                            return wantMobile()
                        end
                        if method == "IsTenFootInterface" then
                            return false
                        end
                    end

                    if method == "FireServer" or method == "InvokeServer" then
                        local args = { ... }
                        local touched = false
                        for i = 1, #args do
                            if type(args[i]) == "table" then
                                deepRewrite(args[i], 0)
                                touched = true
                            end
                        end
                        if touched then
                            return old(self, table.unpack(args))
                        end
                    end
                end

                return old(self, ...)
            end)
            setreadonly(mt, true)
        end)
        PF.hooked = ok
    end

    -- 2. __index：拦截 UserInputService 的平台属性
    if not PF.uisHooked then
        local ok = pcall(function()
            local oldIndex = hookmetamethod(game, "__index", function(self, key)
                if PF.on and rawequal(self, uis) then
                    if key == "TouchEnabled" then return wantMobile() end
                    if key == "AccelerometerEnabled" then return wantMobile() end
                    if key == "GyroEnabled" then return wantMobile() end
                    if key == "KeyboardEnabled" then return not wantMobile() end
                    if key == "MouseEnabled" then return not wantMobile() end
                    if key == "GamepadEnabled" then return false end
                end
                return oldIndex(self, key)
            end)
            return oldIndex ~= nil
        end)
        PF.uisHooked = ok
    end

    return PF.hooked
end

function platformStart()
    local ok = installPlatformHooks()
    PF.on = true
    return ok
end

function platformStop()
    PF.on = false
end

--=====================================================================
-- 5. 界面
--=====================================================================

-- ---------------------------------------------------------------
-- 5.1 主题
-- ---------------------------------------------------------------
local T = {
    bg     = Color3.fromRGB(18, 20, 30),
    panel  = Color3.fromRGB(30, 33, 48),
    card   = Color3.fromRGB(42, 46, 66),
    sub    = Color3.fromRGB(56, 61, 86),
    track  = Color3.fromRGB(74, 80, 112),
    line   = Color3.fromRGB(255, 255, 255),
    text   = Color3.fromRGB(242, 244, 255),
    dim    = Color3.fromRGB(168, 174, 205),
    accent = Color3.fromRGB(124, 172, 255),
    green  = Color3.fromRGB(112, 232, 176),
    red    = Color3.fromRGB(255, 118, 138),
    amber  = Color3.fromRGB(255, 204, 118),
    violet = Color3.fromRGB(186, 148, 255),
    glass  = Color3.fromRGB(120, 140, 190),
}

local F_B = Enum.Font.GothamBold
local F_S = Enum.Font.GothamSemibold
local F_R = Enum.Font.Gotham

local ord = 0
local function nxt() ord = ord + 1; return ord end

-- 前向声明：卡片构建时就引用，必须提前声明为 local
local refreshBinds, refreshStatus
local actFollow, actInvis, actCam, actRhythm
local capture, bindRows = nil, {}

-- ---------------------------------------------------------------
-- 5.2 构件
-- ---------------------------------------------------------------
local function mk(cls, props, parent)
    local o = Instance.new(cls)
    for k, v in pairs(props or {}) do o[k] = v end
    if parent then o.Parent = parent end
    return o
end

local function corner(o, r)
    return mk("UICorner", { CornerRadius = UDim.new(0, r) }, o)
end

local function stroke(o, c, th, tr)
    return mk("UIStroke", {
        Color = c,
        Thickness = th or 1,
        Transparency = tr or 0,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    }, o)
end

local function pad(o, l, r, t, b)
    return mk("UIPadding", {
        PaddingLeft = UDim.new(0, l or 0),
        PaddingRight = UDim.new(0, r or 0),
        PaddingTop = UDim.new(0, t or 0),
        PaddingBottom = UDim.new(0, b or 0),
    }, o)
end

local function paint(o, c)
    o:SetAttribute("Base", c)
    o.BackgroundColor3 = c
end

local function hoverable(o)
    o.MouseEnter:Connect(function()
        local b = o:GetAttribute("Base")
        if b then
            TweenService:Create(o, TweenInfo.new(0.12),
                { BackgroundColor3 = b:Lerp(Color3.new(1, 1, 1), 0.10) }):Play()
        end
    end)
    o.MouseLeave:Connect(function()
        local b = o:GetAttribute("Base")
        if b then
            TweenService:Create(o, TweenInfo.new(0.15),
                { BackgroundColor3 = b }):Play()
        end
    end)
end

-- 液态玻璃：半透明底 + 白描边 + 竖向高光渐变
local function glass(o, baseColor, alpha, radius)
    o.BackgroundColor3 = baseColor
    o.BackgroundTransparency = alpha or 0.72
    corner(o, radius or 12)
    local st = mk("UIStroke", {
        Color = Color3.fromRGB(255, 255, 255),
        Thickness = 1,
        Transparency = 0.78,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    }, o)
    mk("UIGradient", {
        Rotation = 90,
        Color = ColorSequence.new{
            ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
            ColorSequenceKeypoint.new(0.55, Color3.fromRGB(200, 215, 255)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(160, 185, 240)),
        },
        Transparency = NumberSequence.new{
            NumberSequenceKeypoint.new(0, 0.52),
            NumberSequenceKeypoint.new(0.55, 0.80),
            NumberSequenceKeypoint.new(1, 0.90),
        },
    }, o)
    return st
end

-- 顶部高光条：模拟玻璃反光
local function gloss(o, h)
    local bar = mk("Frame", {
        Size = UDim2.new(1, -2, 0, h or 22),
        Position = UDim2.fromOffset(1, 1),
        BackgroundColor3 = Color3.fromRGB(255, 255, 255),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ZIndex = 0,
    }, o)
    corner(bar, (h or 22) / 2)
    mk("UIGradient", {
        Rotation = 90,
        Transparency = NumberSequence.new{
            NumberSequenceKeypoint.new(0, 0.86),
            NumberSequenceKeypoint.new(1, 1),
        },
    }, bar)
    return bar
end

-- 按下回弹
local function pressFx(b)
    local s = mk("UIScale", { Scale = 1 }, b)
    b.MouseButton1Down:Connect(function()
        TweenService:Create(s, TweenInfo.new(0.08, Enum.EasingStyle.Quad),
            { Scale = 0.955 }):Play()
    end)
    b.MouseButton1Up:Connect(function()
        TweenService:Create(s,
            TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
            { Scale = 1 }):Play()
    end)
    return s
end

-- ---------------------------------------------------------------
-- 5.3 根容器
-- ---------------------------------------------------------------
local guiRoot = safeUiRoot()
pcall(function()
    local a = guiRoot:FindFirstChild("SBGFollow")
    if a then a:Destroy() end
    local b = guiRoot:FindFirstChild("SBGHint")
    if b then b:Destroy() end
end)

local gui = mk("ScreenGui", {
    Name = "SBGFollow",
    ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    IgnoreGuiInset = true,
}, guiRoot)

-- 独立提示条：面板隐藏时依然可见
local hintGui = mk("ScreenGui", {
    Name = "SBGHint",
    ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    IgnoreGuiInset = true,
}, guiRoot)

local hint = mk("TextLabel", {
    Text = "",
    Font = F_S,
    TextSize = 12,
    TextColor3 = T.text,
    BackgroundColor3 = T.panel,
    BackgroundTransparency = 0.1,
    Size = UDim2.fromOffset(280, 32),
    Position = UDim2.new(0.5, -140, 1, -76),
    Visible = false,
    Active = false,
}, hintGui)
corner(hint, 8)
stroke(hint, T.line, 1, 0.2)

local hintToken = 0
local function showHint(text, dur)
    hintToken = hintToken + 1
    local my = hintToken

    hint.Text = text
    hint.TextTransparency = 0
    hint.BackgroundTransparency = 0.1
    hint.Visible = true

    -- 从下方滑入
    hint.Position = UDim2.new(0.5, -140, 1, -48)
    TweenService:Create(hint,
        TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
        { Position = UDim2.new(0.5, -140, 1, -76) }):Play()

    task.delay(dur or 2.4, function()
        if hintToken ~= my then return end
        TweenService:Create(hint,
            TweenInfo.new(0.22, Enum.EasingStyle.Quart, Enum.EasingDirection.In),
            { Position = UDim2.new(0.5, -140, 1, -60) }):Play()

        local tw = TweenService:Create(hint, TweenInfo.new(0.42), {
            TextTransparency = 1,
            BackgroundTransparency = 1,
        })
        tw:Play()
        tw.Completed:Connect(function()
            if hintToken == my then
                hint.Visible = false
                hint.TextTransparency = 0
                hint.BackgroundTransparency = 0.1
                hint.Position = UDim2.new(0.5, -140, 1, -76)
            end
        end)
    end)
end

local winScale, panelOpen, panelAnim = nil, true, false
local mobileGui, mobileBall, mobileBarSet   -- 前向声明：操作卡片按钮引用
local setPanel   -- 前向声明：minBtn / closeBtn / 快捷键都引用它

-- ---------------------------------------------------------------
-- 5.4 窗口骨架
-- ---------------------------------------------------------------
local W, H = 352, 560

-- 外发光：玻璃在背景上的一层晕
local glowFrame = mk("Frame", {
    Size = UDim2.fromOffset(W + 14, H + 14),
    Position = UDim2.new(0.5, -(W + 14) / 2, 0.5, -(H + 14) / 2),
    BackgroundColor3 = Color3.fromRGB(130, 160, 255),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ZIndex = 0,
}, gui)
corner(glowFrame, 22)
mk("UIGradient", {
    Rotation = 90,
    Transparency = NumberSequence.new{
        NumberSequenceKeypoint.new(0, 0.94),
        NumberSequenceKeypoint.new(1, 1),
    },
}, glowFrame)

local win = mk("Frame", {
    Size = UDim2.fromOffset(W, H),
    Position = UDim2.new(0.5, -W / 2, 0.5, -H / 2),
    BackgroundColor3 = T.bg,
    BackgroundTransparency = 0.28,
    BorderSizePixel = 0,
    ClipsDescendants = true,
}, gui)
corner(win, 18)
stroke(win, Color3.fromRGB(255, 255, 255), 1, 0.72)

winScale = mk("UIScale", { Scale = 1 }, win)
-- 玻璃内渐变
mk("UIGradient", {
    Rotation = 90,
    Color = ColorSequence.new{
        ColorSequenceKeypoint.new(0, Color3.fromRGB(52, 58, 84)),
        ColorSequenceKeypoint.new(0.5, Color3.fromRGB(26, 29, 44)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(16, 18, 28)),
    },
    Transparency = NumberSequence.new{
        NumberSequenceKeypoint.new(0, 0.30),
        NumberSequenceKeypoint.new(0.55, 0.55),
        NumberSequenceKeypoint.new(1, 0.72),
    },
}, win)

-- 漂移光斑
local function orb(startPos, endPos, color, size, dur)
    local o = mk("Frame", {
        Size = UDim2.fromOffset(size, size),
        Position = startPos,
        BackgroundColor3 = color,
        BackgroundTransparency = 0.86,
        BorderSizePixel = 0,
        ZIndex = 0,
    }, win)
    corner(o, size / 2)
    mk("UIGradient", {
        Transparency = NumberSequence.new{
            NumberSequenceKeypoint.new(0, 0.6),
            NumberSequenceKeypoint.new(1, 1),
        },
    }, o)

    task.spawn(function()
        while o.Parent and S.alive do
            local a = TweenService:Create(o,
                TweenInfo.new(dur, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
                { Position = endPos })
            a:Play()
            a.Completed:Wait()
            if not (o.Parent and S.alive) then break end
            local b = TweenService:Create(o,
                TweenInfo.new(dur, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
                { Position = startPos })
            b:Play()
            b.Completed:Wait()
        end
    end)
    return o
end

orb(UDim2.fromOffset(-90, -60), UDim2.fromOffset(40, 260),
    T.violet, 210, 9)
orb(UDim2.fromOffset(230, 220), UDim2.fromOffset(120, 40),
    T.accent, 240, 11)

-- 顶部栏
local top = mk("Frame", {
    Size = UDim2.new(1, 0, 0, 44),
    BackgroundColor3 = Color3.fromRGB(255, 255, 255),
    BackgroundTransparency = 0.94,
    BorderSizePixel = 0,
}, win)
mk("UIGradient", {
    Rotation = 90,
    Transparency = NumberSequence.new{
        NumberSequenceKeypoint.new(0, 0.88),
        NumberSequenceKeypoint.new(1, 1),
    },
}, top)
gloss(win, 26).ZIndex = 0

-- 收起后的悬浮圆点（独立 ScreenGui，面板隐藏时仍在）
local miniGui = mk("ScreenGui", {
    Name = "SBGMini",
    ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    IgnoreGuiInset = true,
}, guiRoot)

local mini = mk("TextButton", {
    Text = "◈",
    Font = F_B,
    TextSize = 17,
    TextColor3 = T.text,
    BackgroundColor3 = T.panel,
    BackgroundTransparency = 0.08,
    Size = UDim2.fromOffset(44, 44),
    Position = UDim2.new(1, -60, 0, 20),
    AutoButtonColor = false,
    Visible = false,
}, miniGui)
corner(mini, 22)
stroke(mini, Color3.fromRGB(255, 255, 255), 1, 0.55)
mk("UIGradient", {
    Rotation = 90,
    Color = ColorSequence.new{
        ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(160, 185, 240)),
    },
    Transparency = NumberSequence.new{
        NumberSequenceKeypoint.new(0, 0.55),
        NumberSequenceKeypoint.new(1, 0.88),
    },
}, mini)

mini.MouseButton1Click:Connect(function()
    if setPanel then setPanel(true) end
end)

local brand = mk("Frame", {
    Size = UDim2.fromOffset(7, 22),
    Position = UDim2.fromOffset(12, 11),
    BackgroundColor3 = T.accent,
    BorderSizePixel = 0,
}, top)
corner(brand, 3)

-- 品牌条呼吸
task.spawn(function()
    local function pulse(c, h, c2, h2)
        TweenService:Create(brand,
            TweenInfo.new(1.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
            { BackgroundColor3 = c2, Size = UDim2.fromOffset(h2, 26) }):Play()
    end
    task.wait(0.2)
    while brand.Parent and S.alive do
        pulse(T.accent, 7, T.violet, 9)
        task.wait(1.8)
        if not brand.Parent then break end
        TweenService:Create(brand,
            TweenInfo.new(1.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
            { BackgroundColor3 = T.accent, Size = UDim2.fromOffset(7, 22) }):Play()
        task.wait(1.8)
    end
end)

mk("TextLabel", {
    Text = "SBG TOOLKIT",
    Font = F_B,
    TextSize = 13,
    TextColor3 = T.text,
    TextXAlignment = Enum.TextXAlignment.Left,
    BackgroundTransparency = 1,
    Position = UDim2.fromOffset(26, 0),
    Size = UDim2.new(1, -100, 1, 0),
}, top)

mk("TextLabel", {
    Text = "v2.4",
    Font = F_S,
    TextSize = 10,
    TextColor3 = T.dim,
    TextXAlignment = Enum.TextXAlignment.Right,
    BackgroundTransparency = 1,
    Position = UDim2.new(1, -74, 0, 0),
    Size = UDim2.fromOffset(34, 44),
}, top)

local minBtn = mk("TextButton", {
    Text = "—",
    Font = F_B,
    TextSize = 14,
    TextColor3 = T.dim,
    BackgroundTransparency = 1,
    Size = UDim2.fromOffset(32, 44),
    Position = UDim2.new(1, -68, 0, 0),
    AutoButtonColor = false,
}, top)
minBtn.MouseButton1Click:Connect(function() setPanel(false) end)

local closeBtn = mk("TextButton", {
    Text = "✕",
    Font = F_B,
    TextSize = 13,
    TextColor3 = T.dim,
    BackgroundTransparency = 1,
    Size = UDim2.fromOffset(32, 44),
    Position = UDim2.new(1, -36, 0, 0),
    AutoButtonColor = false,
}, top)
closeBtn.MouseButton1Click:Connect(function() setPanel(false) end)

-- 拖拽（窗口 + 顶部栏）
do
    local dragging, st, sp = false, nil, nil
    local function begin(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1
        or i.UserInputType == Enum.UserInputType.Touch then
            dragging, st, sp = true, i.Position, win.Position
        end
    end
    top.InputBegan:Connect(begin)
    win.InputBegan:Connect(function(i)
        if i.UserInputType ~= Enum.UserInputType.MouseButton1
        and i.UserInputType ~= Enum.UserInputType.Touch then return end
        if i.Position.Y - win.AbsolutePosition.Y < 44 then begin(i) end
    end)
    UserInputService.InputChanged:Connect(function(i)
        if not dragging then return end
        if i.UserInputType == Enum.UserInputType.MouseMovement
        or i.UserInputType == Enum.UserInputType.Touch then
            local d = i.Position - st
            win.Position = UDim2.new(
                sp.X.Scale, sp.X.Offset + d.X,
                sp.Y.Scale, sp.Y.Offset + d.Y)
        end
    end)
    UserInputService.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1
        or i.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
end

-- 状态胶囊行
local statusRow = mk("Frame", {
    Size = UDim2.new(1, 0, 0, 38),
    Position = UDim2.fromOffset(0, 44),
    BackgroundTransparency = 1,
}, win)
pad(statusRow, 8, 8, 5, 5)
mk("UIListLayout", {
    FillDirection = Enum.FillDirection.Horizontal,
    Padding = UDim.new(0, 6),
    SortOrder = Enum.SortOrder.LayoutOrder,
    VerticalAlignment = Enum.VerticalAlignment.Center,
}, statusRow)

-- 滚动区
local SC_TOP = 82
local SC_H = H - SC_TOP - 64 - 2
local sc = mk("ScrollingFrame", {
    Size = UDim2.new(1, -12, 0, SC_H),
    Position = UDim2.fromOffset(6, SC_TOP),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ScrollBarThickness = 3,
    ScrollBarImageColor3 = T.line,
    ScrollBarImageTransparency = 0.25,
    ScrollingDirection = Enum.ScrollingDirection.Y,
    CanvasSize = UDim2.new(),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, win)
mk("UIListLayout", {
    Padding = UDim.new(0, 8),
    SortOrder = Enum.SortOrder.LayoutOrder,
}, sc)

-- 底部主控栏
local dock = mk("Frame", {
    Size = UDim2.new(1, 0, 0, 64),
    Position = UDim2.new(0, 0, 1, -64),
    BackgroundColor3 = T.panel,
    BorderSizePixel = 0,
}, win)
pad(dock, 8, 8, 6, 8)
mk("UIListLayout", {
    FillDirection = Enum.FillDirection.Horizontal,
    Padding = UDim.new(0, 6),
    SortOrder = Enum.SortOrder.LayoutOrder,
}, dock)

-- ---------------------------------------------------------------
-- 5.5 控件工厂
-- ---------------------------------------------------------------
local function btn(parent, text, cb, o)
    o = o or {}
    local b = mk("TextButton", {
        Text = text,
        Font = F_S,
        TextSize = o.textSize or 12,
        TextColor3 = o.textColor or T.text,
        BackgroundColor3 = o.bg or T.sub,
        BorderSizePixel = 0,
        Size = o.size or UDim2.new(1, 0, 0, 30),
        TextXAlignment = o.align or Enum.TextXAlignment.Center,
        AutoButtonColor = false,
        LayoutOrder = nxt(),
    }, parent)
    glass(b, o.bg or T.sub, o.alpha or 0.5, o.radius or 10)
    paint(b, o.bg or T.sub)
    hoverable(b)
    pressFx(b)
    if cb then
        b.MouseButton1Click:Connect(function() pcall(cb, b) end)
    end
    return b
end

local function tgl(parent, label, def, cb)
    local on = def and true or false
    local row = mk("TextButton", {
        Text = "",
        BackgroundColor3 = T.card,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 34),
        AutoButtonColor = false,
        LayoutOrder = nxt(),
    }, parent)
    glass(row, T.card, 0.5, 9)
    paint(row, T.card)
    hoverable(row)
    pressFx(row)

    mk("TextLabel", {
        Text = label,
        Font = F_S,
        TextSize = 12,
        TextColor3 = T.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        BackgroundTransparency = 1,
        Position = UDim2.fromOffset(10, 0),
        Size = UDim2.new(1, -62, 1, 0),
    }, row)

    local pill = mk("Frame", {
        Size = UDim2.fromOffset(34, 18),
        Position = UDim2.new(1, -44, 0.5, -9),
        BackgroundColor3 = on and T.green or T.track,
        BorderSizePixel = 0,
    }, row)
    corner(pill, 9)
    local pillStroke = mk("UIStroke", {
        Color = T.green,
        Thickness = 1.4,
        Transparency = on and 0.1 or 1,
    }, pill)

    local knob = mk("Frame", {
        Size = UDim2.fromOffset(14, 14),
        Position = on and UDim2.new(1, -16, 0.5, -7) or UDim2.new(0, 2, 0.5, -7),
        BackgroundColor3 = Color3.fromRGB(250, 250, 255),
        BorderSizePixel = 0,
    }, pill)
    corner(knob, 7)
    local knobScale = mk("UIScale", { Scale = 1 }, knob)

    local function draw(anim)
        local ti = TweenInfo.new(anim and 0.2 or 0.01,
            anim and Enum.EasingStyle.Quart or Enum.EasingStyle.Linear,
            Enum.EasingDirection.Out)
        TweenService:Create(pill, ti, {
            BackgroundColor3 = on and T.green or T.track,
        }):Play()
        TweenService:Create(pillStroke, ti, {
            Transparency = on and 0.1 or 1,
        }):Play()
        TweenService:Create(knob, TweenInfo.new(anim and 0.26 or 0.01,
            Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
            Position = on and UDim2.new(1, -16, 0.5, -7) or UDim2.new(0, 2, 0.5, -7),
        }):Play()

        if anim then
            knobScale.Scale = on and 1.28 or 0.82
            TweenService:Create(knobScale,
                TweenInfo.new(0.3, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out),
                { Scale = 1 }):Play()
        end
    end

    row.MouseButton1Click:Connect(function()
        on = not on
        draw(true)
        pcall(cb, on)
    end)

    return row, function() return on end
end

local function sld(parent, label, mn, mx, def, cb, fmt)
    local v = def
    local box = mk("Frame", {
        Size = UDim2.new(1, 0, 0, 48),
        BackgroundColor3 = T.card,
        BorderSizePixel = 0,
        LayoutOrder = nxt(),
    }, parent)
    glass(box, T.card, 0.5, 9)

    mk("TextLabel", {
        Text = label,
        Font = F_S,
        TextSize = 12,
        TextColor3 = T.dim,
        TextXAlignment = Enum.TextXAlignment.Left,
        BackgroundTransparency = 1,
        Position = UDim2.fromOffset(10, 7),
        Size = UDim2.new(0.42, 0, 0, 16),
    }, box)

    local val = mk("TextLabel", {
        Text = fmt and fmt(v) or tostring(v),
        Font = F_B,
        TextSize = 12,
        TextColor3 = T.text,
        TextXAlignment = Enum.TextXAlignment.Right,
        BackgroundTransparency = 1,
        Position = UDim2.new(0.42, 0, 7),
        Size = UDim2.new(0.58, -10, 0, 16),
    }, box)

    local track = mk("Frame", {
        Size = UDim2.new(1, -20, 0, 4),
        Position = UDim2.new(0, 10, 1, -14),
        BackgroundColor3 = T.track,
        BorderSizePixel = 0,
    }, box)
    corner(track, 2)

    local fill = mk("Frame", {
        Size = UDim2.fromScale((v - mn) / (mx - mn), 1),
        BackgroundColor3 = T.accent,
        BorderSizePixel = 0,
    }, track)
    corner(fill, 2)
    mk("UIGradient", {
        Color = ColorSequence.new{
            ColorSequenceKeypoint.new(0, T.accent),
            ColorSequenceKeypoint.new(1, T.violet),
        },
    }, fill)

    local knobP = (v - mn) / (mx - mn)
    local knob = mk("Frame", {
        Size = UDim2.fromOffset(12, 12),
        Position = UDim2.new(knobP, -6, 0.5, -6),
        BackgroundColor3 = Color3.fromRGB(250, 250, 255),
        BorderSizePixel = 0,
    }, track)
    corner(knob, 6)
    mk("UIStroke", {
        Color = T.accent, Thickness = 1.2, Transparency = 0.4,
    }, knob)
    local knobScale = mk("UIScale", { Scale = 1 }, knob)

    local hit = mk("Frame", {
        Size = UDim2.new(1, -20, 0, 22),
        Position = UDim2.new(0, 10, 1, -24),
        BackgroundTransparency = 1,
    }, box)

    local dragging = false
    local function apply(posX)
        local rel = clamp((posX - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1)
        v = mn + (mx - mn) * rel
        if mx - mn <= 2 then
            v = math.floor(v * 100 + 0.5) / 100
        else
            v = math.floor(v + 0.5)
        end
        fill.Size = UDim2.fromScale(rel, 1)
        knob.Position = UDim2.new(rel, -6, 0.5, -6)
        val.Text = fmt and fmt(v) or tostring(v)
        pcall(cb, v)
    end

    hit.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1
        or i.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            TweenService:Create(knobScale,
                TweenInfo.new(0.14, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
                { Scale = 1.45 }):Play()
            TweenService:Create(track,
                TweenInfo.new(0.14), { BackgroundColor3 = T.track:Lerp(T.accent, 0.25) }):Play()
            apply(i.Position.X)
        end
    end)
    UserInputService.InputChanged:Connect(function(i)
        if not dragging then return end
        if i.UserInputType == Enum.UserInputType.MouseMovement
        or i.UserInputType == Enum.UserInputType.Touch then
            apply(i.Position.X)
        end
    end)
    UserInputService.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1
        or i.UserInputType == Enum.UserInputType.Touch then
            if not dragging then return end
            dragging = false
            TweenService:Create(knobScale,
                TweenInfo.new(0.28, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out),
                { Scale = 1 }):Play()
            TweenService:Create(track,
                TweenInfo.new(0.2), { BackgroundColor3 = T.track }):Play()
        end
    end)

    return box, function() return v end
end

local function seg(parent, items, cb, defIndex)
    local wrap = mk("Frame", {
        Size = UDim2.new(1, 0, 0, 34),
        BackgroundColor3 = T.card,
        BorderSizePixel = 0,
        LayoutOrder = nxt(),
    }, parent)
    corner(wrap, 8)
    pad(wrap, 4, 4, 4, 4)
    mk("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal,
        Padding = UDim.new(0, 4),
        VerticalAlignment = Enum.VerticalAlignment.Center,
        SortOrder = Enum.SortOrder.LayoutOrder,
    }, wrap)

    local btns = {}
    local cur = defIndex or 1

    local function select(i, fire)
        cur = i
        for k, b in ipairs(btns) do
            local active = (k == i)
            paint(b, active and T.accent or T.sub)
            b.TextColor3 = active and Color3.fromRGB(255, 255, 255) or T.dim
        end
        if fire then pcall(cb, items[i].value, i) end
    end

    for i, it in ipairs(items) do
        local b = mk("TextButton", {
            Text = it.text,
            Font = F_S,
            TextSize = 11,
            TextColor3 = T.dim,
            BackgroundColor3 = T.sub,
            BorderSizePixel = 0,
            Size = UDim2.new(1 / #items, -3, 1, 0),
            AutoButtonColor = false,
            LayoutOrder = i,
        }, wrap)
        corner(b, 6)
        b.MouseButton1Click:Connect(function() select(i, true) end)
        btns[i] = b
    end

    select(cur, false)
    return wrap
end

local function card(title, color)
    local c = mk("Frame", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = T.panel,
        BorderSizePixel = 0,
        LayoutOrder = nxt(),
    }, sc)
    glass(c, T.panel, 0.56, 14)
    pad(c, 8, 8, 0, 0)

    mk("UIListLayout", {
        Padding = UDim.new(0, 0),
        SortOrder = Enum.SortOrder.LayoutOrder,
    }, c)

    local hdr = mk("TextButton", {
        Text = "",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 34),
        AutoButtonColor = false,
        LayoutOrder = 1,
    }, c)

    local bar = mk("Frame", {
        Size = UDim2.fromOffset(3, 13),
        Position = UDim2.fromOffset(2, 10),
        BackgroundColor3 = color or T.accent,
        BorderSizePixel = 0,
    }, hdr)
    corner(bar, 2)

    mk("TextLabel", {
        Text = title,
        Font = F_B,
        TextSize = 12,
        TextColor3 = T.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        BackgroundTransparency = 1,
        Position = UDim2.fromOffset(12, 0),
        Size = UDim2.new(1, -44, 1, 0),
    }, hdr)

    local arrow = mk("TextLabel", {
        Text = "▾",
        Font = F_B,
        TextSize = 12,
        TextColor3 = T.dim,
        BackgroundTransparency = 1,
        Position = UDim2.new(1, -22, 0, 0),
        Size = UDim2.fromOffset(16, 34),
    }, hdr)

    local body = mk("Frame", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        LayoutOrder = 2,
    }, c)
    mk("UIListLayout", {
        Padding = UDim.new(0, 6),
        SortOrder = Enum.SortOrder.LayoutOrder,
    }, body)
    pad(body, 0, 0, 0, 8)

    local open = true
    local savedH = 0
    c:SetAttribute("IsOpen", true)

    hdr.MouseButton1Click:Connect(function()
        open = not open
        c:SetAttribute("IsOpen", open)
        arrow.Text = open and "▾" or "▸"
        arrow.TextColor3 = open and T.dim or T.accent

        if open then
            body.Visible = true
            c.AutomaticSize = Enum.AutomaticSize.None
            c.Size = UDim2.new(1, 0, 0, 34)
            TweenService:Create(c,
                TweenInfo.new(0.26, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
                { Size = UDim2.new(1, 0, 0, savedH) }):Play()
            task.delay(0.28, function()
                if c:GetAttribute("IsOpen") then
                    c.AutomaticSize = Enum.AutomaticSize.Y
                    c.Size = UDim2.new(1, 0, 0, 0)
                end
            end)
        else
            savedH = c.AbsoluteSize.Y
            c.AutomaticSize = Enum.AutomaticSize.None
            c.Size = UDim2.new(1, 0, 0, savedH)
            TweenService:Create(c,
                TweenInfo.new(0.2, Enum.EasingStyle.Quart, Enum.EasingDirection.In),
                { Size = UDim2.new(1, 0, 0, 34) }):Play()
            task.delay(0.22, function()
                if not c:GetAttribute("IsOpen") then body.Visible = false end
            end)
        end
    end)

    return body
end

-- ---------------------------------------------------------------
-- 5.6 底部主控按钮
-- ---------------------------------------------------------------
local dockButtons = {}

local function dockBtn(key, icon, label, accentColor, cb)
    local b = mk("TextButton", {
        Text = "",
        BackgroundColor3 = T.sub,
        BorderSizePixel = 0,
        Size = UDim2.new(1 / 4, -6, 1, 0),
        AutoButtonColor = false,
        LayoutOrder = nxt(),
    }, dock)
    glass(b, T.sub, 0.46, 11)
    paint(b, T.sub)
    hoverable(b)
    pressFx(b)

    -- 点击涟漪
    b.MouseButton1Click:Connect(function()
        local rip = mk("Frame", {
            Size = UDim2.fromOffset(10, 10),
            Position = UDim2.new(0.5, -5, 0.5, -5),
            BackgroundColor3 = accentColor,
            BackgroundTransparency = 0.55,
            BorderSizePixel = 0,
            ZIndex = 2,
        }, b)
        corner(rip, 5)
        TweenService:Create(rip, TweenInfo.new(0.45, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
            Size = UDim2.fromOffset(120, 120),
            Position = UDim2.new(0.5, -60, 0.5, -60),
            BackgroundTransparency = 1,
        }):Play()
        task.delay(0.5, function() pcall(function() rip:Destroy() end) end)
    end)

    local st = stroke(b, T.line, 1, 0.1)

    local ic = mk("TextLabel", {
        Text = icon,
        Font = F_B,
        TextSize = 16,
        TextColor3 = accentColor,
        BackgroundTransparency = 1,
        Position = UDim2.fromOffset(0, 7),
        Size = UDim2.new(1, 0, 0, 18),
    }, b)

    local tx = mk("TextLabel", {
        Text = label,
        Font = F_S,
        TextSize = 11,
        TextColor3 = T.dim,
        BackgroundTransparency = 1,
        Position = UDim2.new(0, 0, 1, -19),
        Size = UDim2.new(1, 0, 0, 15),
    }, b)

    b.MouseButton1Click:Connect(function() pcall(cb) end)

    dockButtons[key] = { btn = b, icon = ic, text = tx, stroke = st, accent = accentColor }
    return b
end

-- ---------------------------------------------------------------
-- 5.7 状态胶囊
-- ---------------------------------------------------------------
local pills = {}

local function pill(key, label, accentColor, cb)
    local p = mk("TextButton", {
        Text = "",
        BackgroundColor3 = T.card,
        BorderSizePixel = 0,
        Size = UDim2.new(1 / 4, -6, 1, 0),
        AutoButtonColor = false,
        LayoutOrder = nxt(),
    }, statusRow)
    glass(p, T.card, 0.5, 9)
    paint(p, T.card)
    hoverable(p)
    pressFx(p)
    local st = stroke(p, T.line, 1, 0.15)

    local dot = mk("Frame", {
        Size = UDim2.fromOffset(6, 6),
        Position = UDim2.new(0, 9, 0.5, 0),
        BackgroundColor3 = T.track,
        BorderSizePixel = 0,
    }, p)
    corner(dot, 3)

    local tx = mk("TextLabel", {
        Text = label,
        Font = F_S,
        TextSize = 11,
        TextColor3 = T.dim,
        TextXAlignment = Enum.TextXAlignment.Left,
        BackgroundTransparency = 1,
        Position = UDim2.fromOffset(20, 0),
        Size = UDim2.new(1, -24, 1, 0),
    }, p)

    p.MouseButton1Click:Connect(function() pcall(cb) end)

    pills[key] = { btn = p, dot = dot, text = tx, stroke = st, accent = accentColor }
    return p
end

-- ---------------------------------------------------------------
-- 5.8 隐身卡片
-- ---------------------------------------------------------------
do
    local body = card("隐　　身", T.violet)

    btn(body, "开启隐身", function(b)
        actInvis()
    end, { bg = T.sub, size = UDim2.new(1, 0, 0, 34), textSize = 13 })

    seg(body, {
        { text = "网络隐身", value = "network" },
        { text = "本地自隐", value = "local" },
        { text = "鬼影", value = "ghost" },
        { text = "静默", value = "silent" },
    }, function(v)
        C.invisMode = v
        invisRefresh()
    end, 1)

    sld(body, "透明度", 0, 1, C.invisAlpha, function(v)
        C.invisAlpha = v
        if C.invisOn and C.invisMode == "network" then
            local ch = LP.Character
            if ch then
                for _, d in ipairs(ch:GetDescendants()) do
                    if d:IsA("BasePart") then d.Transparency = v end
                end
            end
        end
    end, function(v) return string.format("%.2f", v) end)

    sld(body, "鬼影透明度", 0, 1, Invis.ghostAlpha, function(v)
        Invis.ghostAlpha = v
        if C.invisOn and C.invisMode == "ghost" then
            invisRefresh()
        end
    end, function(v) return string.format("%.2f", v) end)

    tgl(body, "幽灵轮廓（仅自己可见）", true, function(on)
        C.invisOutline = on
        invisRefresh()
    end)
    tgl(body, "静音脚步与工具音", true, function(on)
        C.invisMute = on
        invisRefresh()
    end)
    tgl(body, "维持守护（抗还原）", true, function(on)
        C.invisGuard = on
        if C.invisOn then invisStart() end
    end)
    tgl(body, "跟随时自动隐身", false, function(on)
        C.invisWithFollow = on
    end)
end

-- ---------------------------------------------------------------
-- 5.9 视角卡片
-- ---------------------------------------------------------------
do
    local body = card("视　　角", T.amber)

    btn(body, "锁定视角", function(b)
        actCam()
    end, { bg = T.sub, size = UDim2.new(1, 0, 0, 34), textSize = 13 })

    seg(body, {
        { text = "跟随", value = "lock" },
        { text = "环绕", value = "orbit" },
        { text = "瞄准", value = "aim" },
    }, function(v)
        Cam.mode = v
        Cam.cur = nil
        if Cam.on then
            camStop()
            camStart()
        end
    end, 1)

    sld(body, "相机距离", 4, 40, Cam.dist, function(v) Cam.dist = v end,
        function(v) return string.format("%.1f", v) end)
    sld(body, "相机高度", -6, 10, Cam.height, function(v) Cam.height = v end,
        function(v) return string.format("%.1f", v) end)
    sld(body, "俯仰", -60, 60, Cam.pitch, function(v) Cam.pitch = v end,
        function(v) return string.format("%d°", math.floor(v)) end)
    sld(body, "偏航", -180, 180, Cam.yaw, function(v) Cam.yaw = v end,
        function(v) return string.format("%d°", math.floor(v)) end)
    sld(body, "视野 FOV", 40, 120, Cam.fov, function(v)
        Cam.fov = v
        camRefresh()
    end, function(v) return string.format("%d", math.floor(v)) end)
    sld(body, "平滑", 0, 100, Cam.smooth, function(v) Cam.smooth = v end,
        function(v)
            return v >= 99.5 and "MAX 硬锁" or (string.format("%d", math.floor(v)) .. "%")
        end)
    sld(body, "瞄准高度", 0, 4, Cam.aimY, function(v) Cam.aimY = v end,
        function(v) return string.format("%.1f", v) end)

    tgl(body, "鼠标环绕", false, function(on) Cam.mouse = on end)
    tgl(body, "遮挡收缩", true, function(on) Cam.clip = on end)
    tgl(body, "跟随自动锁定视角", false, function(on) Cam.autoWithFollow = on end)
end

-- ---------------------------------------------------------------
-- 5.9b 节奏卡片（周五夜放克）
-- ---------------------------------------------------------------
do
    local body = card("节　　奏 · 周五夜放克", T.green)

    btn(body, "开始自动演奏", function()
        actRhythm()
    end, { bg = T.sub, size = UDim2.new(1, 0, 0, 34), textSize = 13 })

    seg(body, {
        { text = "谱面驱动", value = "chart" },
        { text = "画面驱动", value = "visual" },
    }, function(v)
        R.mode = v
        R.notes = nil
        R.cursor = 1
        if R.on then
            rhythmStop()
            rhythmStart()
        end
    end, 1)

    sld(body, "判定提前量", -120, 120, R.leadMs, function(v) R.leadMs = v end,
        function(v) return string.format("%d ms", math.floor(v)) end)
    sld(body, "视觉判定窗口", 10, 120, R.windowPx, function(v) R.windowPx = v end,
        function(v) return string.format("%d px", math.floor(v)) end)

    btn(body, "重新扫描谱面", function()
        local ok = rhythmRescan()
        if ok then
            showHint("谱面已载入 · " .. R.source, 2)
        else
            showHint("未找到谱面模块", 2)
        end
    end, { size = UDim2.new(1, 0, 0, 28), textSize = 11 })

    btn(body, "重新检测音轨", function()
        R.clock = findClock()
        if R.clock then
            showHint("时钟 · " .. R.clock.Name, 2)
        else
            showHint("未找到播放中的音轨", 2)
        end
    end, { size = UDim2.new(1, 0, 0, 28), textSize = 11 })

    btn(body, "诊断（输出到控制台）", function()
        rhythmDiagnose()
        showHint("诊断已输出 · 打开控制台查看", 2)
    end, { size = UDim2.new(1, 0, 0, 28), textSize = 11 })

    btn(body, "发送测试按键（判断游戏是否吃键）", function()
        local n = rhythmTestKey("left")
        showHint("已发送 " .. n, 1.6)
    end, { size = UDim2.new(1, 0, 0, 28), textSize = 11 })

    -- 音符键位（可改）
    for _, lm in ipairs({
        { field = "left",  label = "左键" },
        { field = "down",  label = "下键" },
        { field = "up",    label = "上键" },
        { field = "right", label = "右键" },
    }) do
        local row = mk("TextButton", {
            Text = "",
            BackgroundColor3 = T.card,
            BorderSizePixel = 0,
            Size = UDim2.new(1, 0, 0, 28),
            AutoButtonColor = false,
            LayoutOrder = nxt(),
        }, body)
        glass(row, T.card, 0.5, 9)
        paint(row, T.card)
        hoverable(row)
        pressFx(row)

        local nameLbl = mk("TextLabel", {
            Text = lm.label,
            Font = F_S,
            TextSize = 11,
            TextColor3 = T.dim,
            TextXAlignment = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1,
            Position = UDim2.fromOffset(10, 0),
            Size = UDim2.new(0.5, 0, 1, 0),
        }, row)

        local keyLbl = mk("TextLabel", {
            Text = R.laneKeys[lm.field] and R.laneKeys[lm.field].Name or "?",
            Font = F_B,
            TextSize = 11,
            TextColor3 = T.text,
            TextXAlignment = Enum.TextXAlignment.Right,
            BackgroundTransparency = 1,
            Position = UDim2.new(0.5, 0, 0, 0),
            Size = UDim2.new(0.5, -10, 1, 0),
        }, row)

        row.MouseButton1Click:Connect(function()
            local field = "lane_" .. lm.field
            if capture == field then
                capture = nil
                refreshBinds()
            else
                capture = field
                refreshBinds()
                keyLbl.Text = "按任意键…"
                keyLbl.TextColor3 = T.amber
            end
        end)

        bindRows["lane_" .. lm.field] = {
            btn = row, key = keyLbl, label = lm.label, lane = lm.field,
        }
    end

    local info = mk("TextLabel", {
        Text = "谱面 · 未扫描",
        Font = F_S,
        TextSize = 11,
        TextColor3 = T.dim,
        TextXAlignment = Enum.TextXAlignment.Left,
        BackgroundColor3 = T.card,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 40),
        LayoutOrder = nxt(),
    }, body)
    corner(info, 8)
    mk("UIPadding", { PaddingLeft = UDim.new(0, 10) }, info)

    task.spawn(function()
        while S.alive and info.Parent do
            task.wait(0.25)
            if R.on then
                local total = R.notes and #R.notes or 0
                info.Text = string.format("音轨 %s · 谱面 %d · 已打 %d",
                    R.clock and R.clock.Name or "无", total, R.fired)
                info.TextColor3 = T.text
            else
                info.Text = "谱面 · " .. R.source
                info.TextColor3 = T.dim
            end
        end
    end)
end

-- ---------------------------------------------------------------
-- 5.9c 战场增强卡片
-- ---------------------------------------------------------------
do
    local body = card("战　场 · 瞄准 / 移动 / 反击", T.red)

    tgl(body, "瞄准锁定（预测补偿）", false, function(on)
        Aim.on = on
        local _, _, hum = myParts()
        if hum and not on then hum.AutoRotate = true end
    end)

    sld(body, "预测系数", 0, 1, Aim.prediction, function(v) Aim.prediction = v end,
        function(v) return string.format("%.2f s", v) end)
    tgl(body, "自动预测（按 Ping 计算）", true, function(on) Aim.autoPred = on end)
    tgl(body, "锁定保持自身高度", false, function(on) Aim.keepY = on end)

    tgl(body, "移动加速", false, function(on) Mv.on = on end)
    sld(body, "加速力度", 1, 400, Mv.speed, function(v) Mv.speed = v end,
        function(v) return string.format("%d", math.floor(v)) end)

    tgl(body, "飞行（相机方向）", false, function(on)
        Fly.on = on
        if not on then
            local _, root, hum = myParts()
            if root then root.Velocity = Vector3.zero end
            if hum then hum.AutoRotate = true end
        end
    end)
    sld(body, "飞行速度", 10, 300, Fly.speed, function(v) Fly.speed = v end,
        function(v) return string.format("%d", math.floor(v)) end)

    tgl(body, "防甩飞（noclip 其他角色）", false, function(on)
        AF.on = on
        AF.acc = 0
    end)

    tgl(body, "显示他人死亡反击", false, function(on)
        if on then dcStart() else dcStop() end
    end)
    tgl(body, "死亡反击表情特效", false, function(on) DC.fx = on end)

    tgl(body, "瞬移贴背（无延迟）", false, function(on)
        if on then tpBackStart() else tpBackStop() end
    end)
    sld(body, "贴背距离", 1, 12, TP.dist, function(v) TP.dist = v end,
        function(v) return string.format("%.1f studs", v) end)
    sld(body, "最小间隔", 0, 200, TP.minGap * 1000, function(v)
        TP.minGap = v / 1000
    end, function(v) return string.format("%d ms", math.floor(v)) end)
    tgl(body, "仅目标硬直时贴背", false, function(on) TP.onlyRagdoll = on end)
    tgl(body, "跳过被抓 / 无敌目标", true, function(on) TP.skipGrabbed = on end)

    tgl(body, "伪装设备平台（排行榜图标）", false, function(on)
        if on then
            local ok = platformStart()
            if not ok then
                showHint("当前环境不支持平台钩子", 2)
            else
                showHint("设备已伪装 · 重进服务器或重生后生效", 2.6)
            end
        else
            platformStop()
            showHint("设备伪装已关闭", 1.6)
        end
    end)

    seg(body, {
        { text = "手机", value = "mobile" },
        { text = "电脑", value = "pc" },
    }, function(v)
        PF.mode = v
    end, 1)
end

-- ---------------------------------------------------------------
-- 5.10 跟随卡片
-- ---------------------------------------------------------------
do
    local body = card("跟　　随", T.accent)

    local listBox = mk("Frame", {
        Size = UDim2.new(1, 0, 0, 104),
        BackgroundColor3 = T.card,
        BorderSizePixel = 0,
        LayoutOrder = nxt(),
        ClipsDescendants = true,
    }, body)
    corner(listBox, 8)
    pad(listBox, 4, 4, 4, 4)

    local list = mk("ScrollingFrame", {
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 3,
        ScrollBarImageColor3 = T.line,
        CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
    }, listBox)
    mk("UIListLayout", {
        Padding = UDim.new(0, 3),
        SortOrder = Enum.SortOrder.LayoutOrder,
    }, list)

    local listBtns = {}

    local function refreshList()
        for _, b in ipairs(listBtns) do pcall(function() b:Destroy() end) end
        listBtns = {}

        local function add(text, player)
            local b = mk("TextButton", {
                Text = text,
                Font = F_S,
                TextSize = 11,
                TextColor3 = player and T.amber or T.dim,
                BackgroundColor3 = T.sub,
                BorderSizePixel = 0,
                Size = UDim2.new(1, 0, 0, 24),
                TextXAlignment = Enum.TextXAlignment.Left,
                AutoButtonColor = false,
                LayoutOrder = nxt(),
            }, list)
            corner(b, 5)
            paint(b, T.sub)
            hoverable(b)
            mk("UIPadding", { PaddingLeft = UDim.new(0, 8) }, b)
            b.MouseButton1Click:Connect(function()
                C.lockTarget = player
                refreshList()
                showHint(player and ("已锁定 " .. player.Name) or "自动锁定最近目标", 1.4)
            end)
            table.insert(listBtns, b)
        end

        add("● 自动锁最近", nil)
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LP then add("○ " .. p.Name, p) end
        end
    end

    refreshList()

    btn(body, "刷新目标列表", refreshList, {
        size = UDim2.new(1, 0, 0, 26),
        textSize = 11,
    })

    sld(body, "背后距离", 2, 14, C.dist, function(v) C.dist = v end,
        function(v) return string.format("%.1f studs", v) end)
    sld(body, "垂直偏移", -4, 8, C.height, function(v) C.height = v end,
        function(v) return string.format("%.1f", v) end)
    sld(body, "侧后角度", -90, 90, C.sideAngle, function(v) C.sideAngle = v end,
        function(v) return string.format("%d°", math.floor(v)) end)
    sld(body, "瞄准高度", 0, 4, C.aimY, function(v) C.aimY = v end,
        function(v) return string.format("%.1f", v) end)
    sld(body, "刚性强度", 0, 100, C.rigidness, function(v) C.rigidness = v end,
        function(v)
            return v >= 99.5 and "MAX 零延迟" or (string.format("%d", math.floor(v)) .. "%")
        end)
    sld(body, "单帧限速", 0, 60, C.maxStep, function(v) C.maxStep = v end,
        function(v) return v <= 0 and "关闭" or (string.format("%.0f studs", v)) end)

    tgl(body, "自动旋转朝向", false, function(on) C.autoRotate = on end)

    seg(body, {
        { text = "刚性 CFrame", value = "rigid" },
        { text = "物理约束", value = "physics" },
    }, function(v)
        C.mode = v
        if C.follow then startFollow() end
    end, 1)
end

-- ---------------------------------------------------------------
-- 5.11 按键卡片
-- ---------------------------------------------------------------
local BIND_META = {
    { field = "keyFollow", label = "跟随启停" },
    { field = "keyInvis",  label = "隐身启停" },
    { field = "keyCam",    label = "视角锁定" },
    { field = "keyRhythm", label = "节奏演奏" },
    { field = "keyToggle", label = "显隐面板" },
}

local function keyName(k)
    return k and k.Name or "?"
end

do
    local body = card("按　　键", T.green)

    for _, meta in ipairs(BIND_META) do
        local row = mk("TextButton", {
            Text = "",
            BackgroundColor3 = T.card,
            BorderSizePixel = 0,
            Size = UDim2.new(1, 0, 0, 30),
            AutoButtonColor = false,
            LayoutOrder = nxt(),
        }, body)
        corner(row, 8)
        paint(row, T.card)
        hoverable(row)

        local name = mk("TextLabel", {
            Text = meta.label,
            Font = F_S,
            TextSize = 11,
            TextColor3 = T.dim,
            TextXAlignment = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1,
            Position = UDim2.fromOffset(10, 0),
            Size = UDim2.new(0.5, 0, 1, 0),
        }, row)

        local key = mk("TextLabel", {
            Text = keyName(C[meta.field]),
            Font = F_B,
            TextSize = 11,
            TextColor3 = T.text,
            TextXAlignment = Enum.TextXAlignment.Right,
            BackgroundTransparency = 1,
            Position = UDim2.new(0.5, 0, 0, 0),
            Size = UDim2.new(0.5, -10, 1, 0),
        }, row)

        row.MouseButton1Click:Connect(function()
            if capture == meta.field then
                capture = nil
                refreshBinds()
            else
                capture = meta.field
                refreshBinds()
                row.Text = ""
                key.Text = "按任意键…"
                key.TextColor3 = T.amber
            end
        end)

        bindRows[meta.field] = { btn = row, key = key, label = meta.label }
    end

    btn(body, "重置按键为默认", function()
        C.keyFollow = Enum.KeyCode.H
        C.keyInvis  = Enum.KeyCode.U
        C.keyCam    = Enum.KeyCode.V
        C.keyRhythm = Enum.KeyCode.RightControl
        C.keyToggle = Enum.KeyCode.RightAlt
        capture = nil
        refreshBinds()
        showHint("按键已重置", 1.4)
    end, { size = UDim2.new(1, 0, 0, 28), textSize = 11 })
end

-- ---------------------------------------------------------------
-- 5.12 操作卡片
-- ---------------------------------------------------------------
do
    local body = card("操　　作", T.red)

    btn(body, "传送到目标背后", function()
        local t = resolveTarget()
        if not (t and t.Character) then
            showHint("没有可用的目标", 1.4)
            return
        end
        local tRoot = t.Character:FindFirstChild("HumanoidRootPart")
        local _, root = myParts()
        if not (tRoot and root) then return end
        local want, aim = computeSlot(tRoot)
        root.CFrame = CFrame.lookAt(want, aim)
        showHint("已传送到 " .. t.Name .. " 背后", 1.4)
    end, { size = UDim2.new(1, 0, 0, 30) })

    btn(body, "切换移动悬浮球", function()
        if mobileGui then
            mobileBarSet(not mobileGui.Enabled)
            if mobileGui.Enabled then
                showHint("悬浮球已显示", 1.6)
            else
                showHint("悬浮球已隐藏", 1.6)
            end
        end
    end, { size = UDim2.new(1, 0, 0, 30) })

    btn(body, "关闭全部功能", function()
        stopFollow()
        invisStop()
        camStop()
        rhythmStop()
        extStop()
        dcStop()
        tpBackStop()
        platformStop()
        refreshBinds()
        refreshStatus()
        showHint("跟随 / 隐身 / 视角 / 节奏 / 战场 已关闭", 1.6)
    end, { size = UDim2.new(1, 0, 0, 30) })

    btn(body, "全部还原并卸载", function()
        S.alive = false
        stopFollow()
        invisStop()
        camStop()
        rhythmStop()
        extStop()
        dcStop()
        tpBackStop()
        platformStop()
        clearEsp()
        S.espChar = nil
        for _, c in pairs(S.conns) do pcall(function() c:Disconnect() end) end
        S.conns = {}
        teardownPhysics()
        pcall(function() gui:Destroy() end)
        pcall(function() hintGui:Destroy() end)
        pcall(function() miniGui:Destroy() end)
        pcall(function() mobileGui:Destroy() end)
    end, { size = UDim2.new(1, 0, 0, 30), bg = Color3.fromRGB(74, 30, 36) })
end

-- ---------------------------------------------------------------
-- 5.13 主控栏按钮
-- ---------------------------------------------------------------
dockBtn("follow", "▶", "跟 随", T.accent, function() actFollow() end)
dockBtn("invis", "◐", "隐 身", T.violet, function() actInvis() end)
dockBtn("cam", "◎", "视 角", T.amber, function() actCam() end)
dockBtn("rhythm", "♪", "节 奏", T.green, function() actRhythm() end)

-- ---------------------------------------------------------------
-- 5.14 状态胶囊实例
-- ---------------------------------------------------------------
pill("follow", "跟随", T.accent, function() actFollow() end)
pill("invis", "隐身", T.violet, function() actInvis() end)
pill("cam", "视角", T.amber, function() actCam() end)
pill("rhythm", "节奏", T.green, function() actRhythm() end)

-- ---------------------------------------------------------------
-- 5.15 动作函数（供胶囊 / dock / 快捷键共用）
-- ---------------------------------------------------------------
function actFollow()
    if C.follow then
        stopFollow()
    else
        startFollow()
    end
    refreshBinds()
    refreshStatus()
end

function actInvis()
    if C.invisOn then
        invisStop()
    else
        invisStart()
    end
    refreshBinds()
    refreshStatus()
end

function actCam()
    if Cam.on then
        camStop()
    else
        camStart()
    end
    refreshBinds()
    refreshStatus()
end

function actRhythm()
    if R.on then
        rhythmStop()
    else
        rhythmStart()
    end
    refreshBinds()
    refreshStatus()
end
-- ---------------------------------------------------------------
-- 5.16 刷新函数
-- ---------------------------------------------------------------
function refreshBinds()
    for _, meta in ipairs(BIND_META) do
        local row = bindRows[meta.field]
        if row and capture ~= meta.field then
            row.key.Text = keyName(C[meta.field])
            row.key.TextColor3 = T.text
        end
    end
    -- 节奏四键
    for field, row in pairs(bindRows) do
        if row.lane and capture ~= field then
            local k = R.laneKeys[row.lane]
            row.key.Text = k and k.Name or "?"
            row.key.TextColor3 = T.text
        end
    end
end

function refreshStatus()
    local map = {
        follow = { on = C.follow, color = T.accent },
        invis  = { on = C.invisOn, color = T.violet },
        cam    = { on = Cam.on, color = T.amber },
        rhythm = { on = R.on, color = T.green },
    }
    for key, info in pairs(map) do
        local p = pills[key]
        if p then
            local changed = (p.lastOn ~= info.on)
            p.lastOn = info.on

            p.dot.BackgroundColor3 = info.on and info.color or T.track
            p.text.TextColor3 = info.on and T.text or T.dim
            p.stroke.Color = info.on and info.color or T.line
            p.stroke.Transparency = info.on and 0.25 or 0.15

            if changed and info.on then
                local ds = p.dot:FindFirstChildOfClass("UIScale")
                if not ds then
                    ds = mk("UIScale", { Scale = 1 }, p.dot)
                end
                ds.Scale = 2.2
                TweenService:Create(ds,
                    TweenInfo.new(0.42, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out),
                    { Scale = 1 }):Play()
            end
        end
        local d = dockButtons[key]
        if d then
            local changed = (d.lastOn ~= info.on)
            d.lastOn = info.on

            d.icon.TextColor3 = info.on and info.color or T.dim
            d.text.TextColor3 = info.on and T.text or T.dim
            d.stroke.Color = info.on and info.color or T.line
            d.stroke.Transparency = info.on and 0.2 or 0.1
            paint(d.btn, info.on and T.card or T.sub)

            if changed and info.on then
                local is = d.icon:FindFirstChildOfClass("UIScale")
                if not is then
                    is = mk("UIScale", { Scale = 1 }, d.icon)
                end
                is.Scale = 1.7
                TweenService:Create(is,
                    TweenInfo.new(0.45, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out),
                    { Scale = 1 }):Play()
            end
        end
    end
end

-- ---------------------------------------------------------------
-- 5.17 卡密授权（只显示输入框）
-- ---------------------------------------------------------------
local AUTH_KEY = "114514"
local authed = false

do
    -- 授权期间收起主界面，面板内只留卡密框
    sc.Visible = false
    statusRow.Visible = false
    dock.Visible = false
    top.Visible = false

    local function restorePanel()
        sc.Visible = true
        statusRow.Visible = true
        dock.Visible = true
        top.Visible = true
    end

    local lock = mk("Frame", {
        Size = UDim2.fromScale(1, 1),
        Position = UDim2.fromOffset(0, 0),
        BackgroundColor3 = Color3.fromRGB(10, 12, 20),
        BorderSizePixel = 0,
        ZIndex = 40,
        Active = true,
        ClipsDescendants = true,
    }, win)
    corner(lock, 18)
    glass(lock, Color3.fromRGB(12, 14, 22), 0.45, 18)

    -- 唯一可见元素：卡密输入框
    local input = mk("TextBox", {
        Text = "",
        PlaceholderText = "输入卡密 · 回车确认",
        PlaceholderColor3 = T.dim,
        Font = F_S,
        TextSize = 14,
        TextColor3 = T.text,
        BackgroundColor3 = T.card,
        BorderSizePixel = 0,
        ClearTextOnFocus = false,
        TextXAlignment = Enum.TextXAlignment.Center,
        Size = UDim2.fromOffset(220, 42),
        Position = UDim2.new(0.5, -110, 0.5, -21),
        ZIndex = 42,
    }, lock)
    corner(input, 12)
    local inputStroke = stroke(input, Color3.fromRGB(255, 255, 255), 1, 0.35)
    local inputScale = mk("UIScale", { Scale = 1 }, input)

    -- 入场：淡入 + 轻微放大
    input.BackgroundTransparency = 1
    input.TextTransparency = 1
    inputScale.Scale = 0.9
    task.defer(function()
        TweenService:Create(input, TweenInfo.new(0.42),
            { BackgroundTransparency = 0.12, TextTransparency = 0 }):Play()
        TweenService:Create(inputScale,
            TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
            { Scale = 1 }):Play()
    end)

    -- 聚焦反馈
    local function focusInput(on)
        TweenService:Create(inputStroke,
            TweenInfo.new(0.2), {
                Transparency = on and 0.02 or 0.35,
                Color = on and T.accent or Color3.fromRGB(255, 255, 255),
            }):Play()
        TweenService:Create(inputScale,
            TweenInfo.new(0.26, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
            { Scale = on and 1.04 or 1 }):Play()
    end

    input.Focused:Connect(function() focusInput(true) end)
    input.FocusLost:Connect(function() focusInput(false) end)

    -- 每次输入闪一下描边
    local charCount = 0
    input:GetPropertyChangedSignal("Text"):Connect(function()
        charCount = charCount + 1
        local mark = charCount
        if authed then return end
        TweenService:Create(inputStroke, TweenInfo.new(0.06), {
            Transparency = 0,
        }):Play()
        task.delay(0.09, function()
            if charCount ~= mark then return end
            if not input:IsFocused() then
                TweenService:Create(inputStroke, TweenInfo.new(0.28), {
                    Transparency = 0.35,
                    Color = Color3.fromRGB(255, 255, 255),
                }):Play()
            end
        end)
    end)

    -- 错误提示：平时不占位，出错才出现
    local tip = mk("TextLabel", {
        Text = "",
        Font = F_S,
        TextSize = 11,
        TextColor3 = T.red,
        TextTransparency = 1,
        BackgroundTransparency = 1,
        Size = UDim2.fromOffset(220, 16),
        Position = UDim2.new(0.5, -110, 0.5, 30),
        ZIndex = 42,
    }, lock)

    -- ---------- 验证 ----------
    local tries = 0
    local busy = false

    local function tryAuth()
        if authed or busy then return end

        if string.gsub(input.Text, "%s", "") == AUTH_KEY then
            authed = true
            busy = true

            TweenService:Create(tip, TweenInfo.new(0.15), { TextTransparency = 1 }):Play()
            input.TextTransparency = 1
            inputStroke.Color = T.green
            inputStroke.Transparency = 0

            -- ① 输入框原地收缩成圆
            local rc = input:FindFirstChildOfClass("UICorner")
            local t1 = TweenService:Create(input,
                TweenInfo.new(0.34, Enum.EasingStyle.Quart, Enum.EasingDirection.InOut), {
                    Size = UDim2.fromOffset(36, 36),
                    Position = UDim2.new(0.5, -18, 0.5, -18),
                    BackgroundColor3 = T.green,
                    BackgroundTransparency = 0,
                })
            t1:Play()
            if rc then
                TweenService:Create(rc,
                    TweenInfo.new(0.34, Enum.EasingStyle.Quart, Enum.EasingDirection.InOut), {
                        CornerRadius = UDim.new(1, 0),
                    }):Play()
            end

            -- ② 同中心继续铺满面板
            t1.Completed:Connect(function()
                local t2 = TweenService:Create(input,
                    TweenInfo.new(0.62, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
                        Size = UDim2.fromOffset(1400, 1400),
                        Position = UDim2.new(0.5, -700, 0.5, -700),
                        BackgroundColor3 = T.bg,
                        BackgroundTransparency = 0,
                    })
                t2:Play()
                TweenService:Create(inputStroke,
                    TweenInfo.new(0.34), { Transparency = 1 }):Play()

                task.delay(0.2, function() restorePanel() end)

                -- ③ 铺满后化开
                t2.Completed:Connect(function()
                    TweenService:Create(input,
                        TweenInfo.new(0.46, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
                            BackgroundTransparency = 1,
                        }):Play()
                    TweenService:Create(lock,
                        TweenInfo.new(0.5), { BackgroundTransparency = 1 }):Play()
                    task.delay(0.55, function()
                        pcall(function() lock:Destroy() end)
                        showHint("授权通过 · 欢迎使用", 2)
                    end)
                end)
            end)
        else
            busy = true
            tries = tries + 1

            tip.Text = "卡密错误"
            tip.TextColor3 = T.red
            tip.TextTransparency = 1
            tip.Position = UDim2.new(0.5, -110, 0.5, 35)
            TweenService:Create(tip, TweenInfo.new(0.2, Enum.EasingStyle.Quart,
                Enum.EasingDirection.Out), {
                    TextTransparency = 0,
                    Position = UDim2.new(0.5, -110, 0.5, 30),
                }):Play()

            input.Text = ""

            local x0 = UDim2.new(0.5, -110, 0.5, -21)
            task.spawn(function()
                for i = 1, 3 do
                    TweenService:Create(input, TweenInfo.new(0.045), {
                        Position = x0 + UDim2.fromOffset(9, 0) }):Play()
                    task.wait(0.055)
                    TweenService:Create(input, TweenInfo.new(0.045), {
                        Position = x0 + UDim2.fromOffset(-9, 0) }):Play()
                    task.wait(0.055)
                end
                TweenService:Create(input, TweenInfo.new(0.12), {
                    Position = x0 }):Play()
            end)

            TweenService:Create(lock, TweenInfo.new(0.1), {
                BackgroundColor3 = Color3.fromRGB(74, 14, 26) }):Play()
            task.delay(0.15, function()
                TweenService:Create(lock, TweenInfo.new(0.38), {
                    BackgroundColor3 = Color3.fromRGB(12, 14, 22) }):Play()
            end)

            inputStroke.Color = T.red
            TweenService:Create(inputStroke, TweenInfo.new(0.08), {
                Transparency = 0 }):Play()
            task.delay(0.55, function()
                if not authed then
                    inputStroke.Color = Color3.fromRGB(255, 255, 255)
                    inputStroke.Transparency = 0.35
                end
                busy = false
            end)
        end
    end

    input.FocusLost:Connect(function(enter)
        if enter then tryAuth() end
    end)
end

-- ---------------------------------------------------------------
-- 5.17b 面板开合：转一圈收成圆点 / 从圆点转一圈展开
-- ---------------------------------------------------------------
local MINI_POS = UDim2.new(1, -60, 0, 20)
local FULL_POS = UDim2.new(0.5, -W / 2, 0.5, -H / 2)

local function contentVisible(v)
    sc.Visible = v
    statusRow.Visible = v
    dock.Visible = v
    top.Visible = v
end

setPanel = function(show)
    if show == panelOpen or panelAnim then return end
    panelAnim = true
    panelOpen = show

    local c = win:FindFirstChildOfClass("UICorner")
    local g = win:FindFirstChildOfClass("UIGradient")

    if show then
        -- 从圆点展开
        mini.Visible = false
        gui.Enabled = true
        contentVisible(false)

        win.Size = UDim2.fromOffset(44, 44)
        win.Position = MINI_POS
        win.BackgroundTransparency = 0.08
        if c then c.CornerRadius = UDim.new(1, 0) end
        if g then g.Rotation = 450 end

        task.delay(0.1, function() contentVisible(true) end)

        if c then
            TweenService:Create(c,
                TweenInfo.new(0.62, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
                { CornerRadius = UDim.new(0, 18) }):Play()
        end
        if g then
            TweenService:Create(g,
                TweenInfo.new(0.62, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
                { Rotation = 90 }):Play()
        end
        TweenService:Create(win,
            TweenInfo.new(0.62, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
                Size = UDim2.fromOffset(W, H),
                Position = FULL_POS,
                BackgroundTransparency = 0.28,
            }):Play()

        task.delay(0.64, function() panelAnim = false end)
    else
        -- 转一圈缩小成圆点
        if c then
            TweenService:Create(c,
                TweenInfo.new(0.58, Enum.EasingStyle.Quart, Enum.EasingDirection.In),
                { CornerRadius = UDim.new(1, 0) }):Play()
        end
        if g then
            TweenService:Create(g,
                TweenInfo.new(0.58, Enum.EasingStyle.Quart, Enum.EasingDirection.In),
                { Rotation = 450 }):Play()
        end
        TweenService:Create(win,
            TweenInfo.new(0.58, Enum.EasingStyle.Quart, Enum.EasingDirection.In), {
                Size = UDim2.fromOffset(44, 44),
                Position = MINI_POS,
                BackgroundTransparency = 0.08,
            }):Play()

        task.delay(0.6, function()
            if panelOpen then return end
            contentVisible(false)
            gui.Enabled = false
            mini.Visible = true
            panelAnim = false
            showHint("已收起 · 点右上圆点展开", 2)
        end)
    end
end

-- ---------------------------------------------------------------
-- 5.17c 移动端悬浮球（触屏设备自动显示）
-- ---------------------------------------------------------------
do
    mobileGui = mk("ScreenGui", {
        Name = "SBGMobile",
        ResetOnSpawn = false,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        IgnoreGuiInset = true,
    }, guiRoot)

    mobileBall = mk("TextButton", {
        Text = "◉",
        Font = F_B,
        TextSize = 20,
        TextColor3 = T.text,
        BackgroundColor3 = T.panel,
        BackgroundTransparency = 0.06,
        Size = UDim2.fromOffset(54, 54),
        Position = UDim2.new(1, -74, 1, -120),
        AutoButtonColor = false,
    }, mobileGui)
    corner(mobileBall, 27)
    stroke(mobileBall, Color3.fromRGB(255, 255, 255), 1, 0.5)
    mk("UIGradient", {
        Rotation = 90,
        Color = ColorSequence.new{
            ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(150, 180, 255)),
        },
        Transparency = NumberSequence.new{
            NumberSequenceKeypoint.new(0, 0.5),
            NumberSequenceKeypoint.new(1, 0.9),
        },
    }, mobileBall)

    local bs = mk("UIScale", { Scale = 1 }, mobileBall)

    -- 拖动 + 区分点击
    local dragging, moved = false, false
    local st, sp

    mobileBall.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1
        or i.UserInputType == Enum.UserInputType.Touch then
            dragging, moved = true, false
            st, sp = i.Position, mobileBall.Position
        end
    end)
    UserInputService.InputChanged:Connect(function(i)
        if not dragging then return end
        if i.UserInputType == Enum.UserInputType.MouseMovement
        or i.UserInputType == Enum.UserInputType.Touch then
            local d = i.Position - st
            if math.abs(d.X) + math.abs(d.Y) > 6 then moved = true end
            mobileBall.Position = UDim2.new(
                sp.X.Scale, sp.X.Offset + d.X,
                sp.Y.Scale, sp.Y.Offset + d.Y)
        end
    end)
    UserInputService.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1
        or i.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)

    mobileBall.MouseButton1Click:Connect(function()
        if moved then return end
        if setPanel then setPanel(not panelOpen) end
        bs.Scale = 0.8
        TweenService:Create(bs,
            TweenInfo.new(0.34, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
            { Scale = 1 }):Play()
    end)

    -- 触屏设备默认显示，键鼠环境隐藏
    local isTouch = UserInputService.TouchEnabled
        and not UserInputService.KeyboardEnabled
    mobileGui.Enabled = isTouch

    function mobileBarSet(on)
        mobileGui.Enabled = on and true or false
    end
end

-- ---------------------------------------------------------------
-- 5.18 启动
-- ---------------------------------------------------------------
extStart()
refreshBinds()
refreshStatus()

--=====================================================================
-- 6. 输入
--=====================================================================
UserInputService.InputBegan:Connect(function(i, gp)
    -------------------------------------------------------------------
    -- 键位捕获优先级最高
    -------------------------------------------------------------------
    if capture then
        if i.KeyCode == Enum.KeyCode.Escape then
            capture = nil
            refreshBinds()
            showHint("已取消改键", 1.4)
            return
        end
        if i.KeyCode and i.KeyCode ~= Enum.KeyCode.Unknown then
            local dup = nil
            for _, meta in ipairs(BIND_META) do
                if C[meta.field] == i.KeyCode and meta.field ~= capture then
                    dup = meta.label
                end
            end
            if capture:sub(1, 5) == "lane_" then
                R.laneKeys[capture:sub(6)] = i.KeyCode
            else
                C[capture] = i.KeyCode
            end
            capture = nil
            refreshBinds()
            if dup then
                showHint("已绑定 " .. i.KeyCode.Name .. "（原属：" .. dup .. "）")
            else
                showHint("已绑定 " .. i.KeyCode.Name, 1.4)
            end
        end
        return
    end

    if gp then return end
    if not authed then return end

    if i.KeyCode == C.keyToggle then
        setPanel(not gui.Enabled)
        return
    end

    if i.KeyCode == C.keyFollow then
        actFollow()
    elseif i.KeyCode == C.keyInvis then
        actInvis()
    elseif i.KeyCode == C.keyCam then
        actCam()
    elseif i.KeyCode == C.keyRhythm then
        actRhythm()
    end
end)

print("[SBG] loaded — 显隐 " .. C.keyToggle.Name
    .. " / 跟随 " .. C.keyFollow.Name
    .. " / 隐身 " .. C.keyInvis.Name
    .. " / 视角 " .. C.keyCam.Name
    .. " / 节奏 " .. C.keyRhythm.Name)
