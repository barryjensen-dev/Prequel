-- ♻️ Safe reload
if _G.AutoAimScriptLoader and _G.AutoAimScriptLoader.Unload then
	_G.AutoAimScriptLoader.Unload()
end
_G.AutoAimScriptLoader = {}

if _G.AutoAimScriptLoader.Running then return end
_G.AutoAimScriptLoader.Running = true

-- SERVICES
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Teams = game:GetService("Teams")
local Camera = workspace.CurrentCamera
local LocalPlayer = Players.LocalPlayer

-- SETTINGS
local TOOL_NAMES = {"M9", "Remington 870", "AK-47", "M4A1"}
local LINE_THICKNESS = 1
local ROTATE_SPEED = 0.15
local FIRE_COOLDOWN = 0.3
local PREDICTION_FACTOR = 1
local CAMERA_SMOOTHING_FACTOR = 0.15
local SHAKE_INTENSITY = 0.15
local AIM_FOV_RADIUS = 200 -- pixels radius around crosshair for valid targets
local TARGET_PERSIST_TIME = 0.6 -- seconds to persist on same target

-- STATE
local ESP, connections = {}, {}
local enabled = true
local hue = 0
local lastFireTime = 0
local PROJECTILE_SPEED = 125
local currentTarget = nil
local lastTargetChangeTime = 0

-- CLEANUP
function _G.AutoAimScriptLoader.Unload()
	for _, conn in pairs(connections) do pcall(function() conn:Disconnect() end) end
	for _, lines in pairs(ESP) do for _, line in pairs(lines) do if line and line.Remove then pcall(function() line:Remove() end) end end end
	ESP = {}
	_G.AutoAimScriptLoader.Running = false
	print("[AutoAim] Unloaded.")
end

-- UTILS
local function newLine()
	local success, line = pcall(function()
		local l = Drawing.new("Line")
		l.Thickness = LINE_THICKNESS
		l.Visible = true
		return l
	end)
	return success and line or nil
end

local function getJoints(char)
	return {
		Head = char:FindFirstChild("Head"),
		Torso = char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("Torso") or char:FindFirstChild("UpperTorso"),
		LeftArm = char:FindFirstChild("Left Arm") or char:FindFirstChild("LeftUpperArm"),
		RightArm = char:FindFirstChild("Right Arm") or char:FindFirstChild("RightUpperArm"),
		LeftLeg = char:FindFirstChild("Left Leg") or char:FindFirstChild("LeftUpperLeg"),
		RightLeg = char:FindFirstChild("Right Leg") or char:FindFirstChild("RightUpperLeg"),
	}
end

local function createESP(player)
	if player == LocalPlayer or ESP[player] then return end
	ESP[player] = {
		Tracer = newLine(),
		HeadTorso = newLine(),
		LeftArm = newLine(),
		RightArm = newLine(),
		LeftLeg = newLine(),
		RightLeg = newLine(),
	}
end

local function removeESP(player)
	if ESP[player] then for _, line in pairs(ESP[player]) do if line then pcall(function() line:Remove() end) end end end
	ESP[player] = nil
end

-- Checks if target is visible via raycast from camera to target HRP
local function hasLineOfSight(target)
	local char = target.Character
	if not char then return false end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not hrp then return false end
	local origin = Camera.CFrame.Position
	local direction = (hrp.Position - origin)
	local raycastParams = RaycastParams.new()
	raycastParams.FilterDescendantsInstances = {LocalPlayer.Character}
	raycastParams.FilterType = Enum.RaycastFilterType.Blacklist
	local raycastResult = workspace:Raycast(origin, direction, raycastParams)
	if raycastResult then
		if raycastResult.Instance:IsDescendantOf(char) then
			return true
		end
		return false
	end
	return true
end

-- Calculates distance in screen pixels between crosshair and target's HRP screen position
local function screenDistanceToTarget(target)
	local hrp = target.Character and target.Character:FindFirstChild("HumanoidRootPart")
	if not hrp then return math.huge end
	local screenPos, onScreen = Camera:WorldToViewportPoint(hrp.Position)
	if not onScreen then return math.huge end
	local centerX, centerY = Camera.ViewportSize.X/2, Camera.ViewportSize.Y/2
	local dx = screenPos.X - centerX
	local dy = screenPos.Y - centerY
	return math.sqrt(dx*dx + dy*dy)
end

-- Gets target's health (or math.huge if can't find)
local function getTargetHealth(target)
	local humanoid = target.Character and target.Character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		return humanoid.Health
	end
	return math.huge
end

-- Gets best target according to health priority, line-of-sight, and FOV radius
local function getBestTarget()
	local now = tick()
	local validTargets = {}

	for _, p in pairs(Players:GetPlayers()) do
		if p ~= LocalPlayer and p.Character and p.Character:FindFirstChild("HumanoidRootPart") then
			if p.Team == LocalPlayer.Team or LocalPlayer:IsFriendsWith(p.UserId) then continue end
			if not hasLineOfSight(p) then continue end
			local distToCenter = screenDistanceToTarget(p)
			if distToCenter > AIM_FOV_RADIUS then continue end
			table.insert(validTargets, p)
		end
	end

	-- If current target is valid and persist timer not expired, keep it
	if currentTarget and table.find(validTargets, currentTarget) and now - lastTargetChangeTime < TARGET_PERSIST_TIME then
		return currentTarget
	end

	-- Otherwise select lowest health target among valid targets
	table.sort(validTargets, function(a,b)
		return getTargetHealth(a) < getTargetHealth(b)
	end)

	currentTarget = validTargets[1]
	lastTargetChangeTime = now
	return currentTarget
end

local function getPredictedPosition(target)
	local hrp = target.Character and target.Character:FindFirstChild("HumanoidRootPart")
	if not hrp then return nil end
	local velocity = hrp.Velocity
	local distance = (Camera.CFrame.Position - hrp.Position).Magnitude
	local timeToHit = distance / PROJECTILE_SPEED
	return hrp.Position + (velocity * timeToHit * PREDICTION_FACTOR)
end

local function faceTarget(target)
	local myHRP = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
	local predicted = getPredictedPosition(target)
	if myHRP and predicted then
		local dir = (predicted - myHRP.Position).Unit
		myHRP.CFrame = myHRP.CFrame:Lerp(CFrame.lookAt(myHRP.Position, myHRP.Position + dir), ROTATE_SPEED)
	end
end

local function autoAimAndFire(target)
	local char, backpack = LocalPlayer.Character, LocalPlayer:FindFirstChild("Backpack")
	if not char or not backpack then return end

	local tool
	for _, t in ipairs(backpack:GetChildren()) do if t:IsA("Tool") and table.find(TOOL_NAMES, t.Name) then tool = t break end end
	for _, t in ipairs(char:GetChildren()) do if t:IsA("Tool") and table.find(TOOL_NAMES, t.Name) then tool = t break end end
	if not tool then return end

	if not char:FindFirstChild(tool.Name) then
		char.Humanoid:EquipTool(tool)
		task.wait(0.1)
	end

	local now = tick()
	if now - lastFireTime >= FIRE_COOLDOWN then
		lastFireTime = now
		local remote = tool:FindFirstChildWhichIsA("RemoteEvent", true)
		local predicted = getPredictedPosition(target) or target.Character.HumanoidRootPart.Position
		if remote then
			pcall(function() remote:FireServer(predicted) end)
		else
			pcall(function() tool:Activate() end)
		end
	end

	-- Auto reload
	local ammo = tool:FindFirstChild("Ammo") or tool:FindFirstChild("Clip")
	if ammo and ammo:IsA("IntValue") and ammo.Value <= 0 then
		local reloadRemote = tool:FindFirstChild("Reload") or tool:FindFirstChildWhichIsA("RemoteEvent", true)
		if reloadRemote then
			pcall(function() reloadRemote:FireServer() end)
		else
			-- Fallback: Send "R" key press (less reliable)
			local VirtualInputManager = game:GetService("VirtualInputManager")
			VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.R, false, game)
			task.wait(0.05)
			VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.R, false, game)
		end
	end
end

-- Camera smoothing + shake
local camOriginalCFrame = Camera.CFrame
local function updateCamera()
	local target = getBestTarget()
	if not target then
		Camera.CFrame = Camera.CFrame:Lerp(camOriginalCFrame, CAMERA_SMOOTHING_FACTOR)
		return
	end

	local predicted = getPredictedPosition(target)
	if not predicted then
		Camera.CFrame = Camera.CFrame:Lerp(camOriginalCFrame, CAMERA_SMOOTHING_FACTOR)
		return
	end

	local lookCFrame = CFrame.lookAt(Camera.CFrame.Position, predicted)

	local shakeX = (math.random() - 0.5) * SHAKE_INTENSITY
	local shakeY = (math.random() - 0.5) * SHAKE_INTENSITY
	local shakeZ = (math.random() - 0.5) * SHAKE_INTENSITY
	local shake = CFrame.new(shakeX, shakeY, shakeZ)

	Camera.CFrame = Camera.CFrame:Lerp(lookCFrame * shake, CAMERA_SMOOTHING_FACTOR)
end

local hue = 0
local function updateESP()
	hue = (hue + 0.005) % 1

	for p, lines in pairs(ESP) do
		local char = p.Character
		local j = char and getJoints(char)
		local hrp = j and j.Torso
		if char and j and j.Head and hrp then
			local headPos, headVisible = Camera:WorldToViewportPoint(j.Head.Position)
			local torsoPos, torsoVisible = Camera:WorldToViewportPoint(hrp.Position)

			local c = {
				lines.HeadTorso, Color3.fromHSV(hue, 1, 1),
				lines.LeftArm,   Color3.fromHSV((hue+0.1)%1, 1, 1),
				lines.RightArm,  Color3.fromHSV((hue+0.2)%1, 1, 1),
				lines.LeftLeg,   Color3.fromHSV((hue+0.3)%1, 1, 1),
				lines.RightLeg,  Color3.fromHSV((hue+0.4)%1, 1, 1),
				lines.Tracer,    Color3.fromHSV((hue+0.5)%1, 1, 1),
			}
			for i = 1, #c, 2 do c[i].Color = c[i+1] end

			lines.HeadTorso.Visible = headVisible and torsoVisible
			if lines.HeadTorso.Visible then
				lines.HeadTorso.From = Vector2.new(headPos.X, headPos.Y)
				lines.HeadTorso.To = Vector2.new(torsoPos.X, torsoPos.Y)
			end

			for limb, part in pairs({LeftArm=j.LeftArm, RightArm=j.RightArm, LeftLeg=j.LeftLeg, RightLeg=j.RightLeg}) do
				if part then
					local pos, visible = Camera:WorldToViewportPoint(part.Position)
					lines[limb].Visible = visible and torsoVisible
					if visible then
						lines[limb].From = Vector2.new(torsoPos.X, torsoPos.Y)
						lines[limb].To = Vector2.new(pos.X, pos.Y)
					end
				end
			end

			local pos, vis = Camera:WorldToViewportPoint(hrp.Position)
			lines.Tracer.Visible = vis
			if vis then
				lines.Tracer.From = Vector2.new(Camera.ViewportSize.X/2, Camera.ViewportSize.Y)
				lines.Tracer.To = Vector2.new(pos.X, pos.Y)
			end
		else
			for _, l in pairs(lines) do l.Visible = false end
		end
	end
end

-- Auto projectile speed detection
local function setupProjectileSpeedDetector()
	local function track(bullet)
		local start = bullet.Position
		local t0 = tick()
		task.delay(0.1, function()
			if bullet and bullet.Parent then
				local dist = (bullet.Position - start).Magnitude
				local dt = tick() - t0
				if dt > 0 then
					local speed = dist / dt
					if speed > 5 then PROJECTILE_SPEED = speed end
				end
			end
		end)
	end
	local folder = workspace:FindFirstChild("GunProjectiles")
	if folder then table.insert(connections, folder.ChildAdded:Connect(track)) end
	table.insert(connections, workspace.ChildAdded:Connect(function(c)
		if c:IsA("BasePart") and c.Name == "Bullet" then track(c) end
	end))
end

-- MAIN LOOP
table.insert(connections, RunService.RenderStepped:Connect(function()
	if not enabled then return end
	updateESP()
	local target = getBestTarget()
	if target then
		faceTarget(target)
		autoAimAndFire(target)
	end
	updateCamera()
end))

-- PLAYER HANDLING
table.insert(connections, Players.PlayerAdded:Connect(function(p)
	p.CharacterAdded:Connect(function() task.wait(1) createESP(p) end)
end))
table.insert(connections, Players.PlayerRemoving:Connect(removeESP))
for _, p in ipairs(Players:GetPlayers()) do if p ~= LocalPlayer then createESP(p) end end

setupProjectileSpeedDetector()
