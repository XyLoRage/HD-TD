--[[
ClientRenders: draws what the server only simulates. The server has a Folder per enemy
 and a target per tower; every model, animation and bullet here exists on this client
alone, so a full wave costs the server nothing to replicate. It predicts movement from
the same speed and path as EnemyAI instead of receiving positions.
]]
local RunService = game:GetService("RunService")
local TweenSvc = game:GetService("TweenService")
local RepStorage = game:GetService("ReplicatedStorage")

-- This script runs from ReplicatedFirst, which starts before the map has replicated.
if not game:IsLoaded() then
	game.Loaded:Wait()
end

local dataDir = RepStorage:WaitForChild("Data")
local EnemyData = require(dataDir:WaitForChild("EnemyData"))
local TowerData = require(dataDir:WaitForChild("TowerData"))

local enmDir = workspace:WaitForChild("Enemies")
local twrDir = workspace:WaitForChild("Towers")
local pathDir = workspace:WaitForChild("Path")
local cliDir = workspace:WaitForChild("Client")
local vfxDir = workspace:WaitForChild("VFX")
local bltTmpl = RepStorage:WaitForChild("VFX"):WaitForChild("Projectiles"):WaitForChild("Yellow")

local TURN_RATE = 8 -- how fast models swing round, higher = snappier
local SIDE_SPRD = 0.7 -- max studs off the path's centre, stops enemies walking in one file
local ANIM_RATE = 0.15 -- walk cycles per stud of speed, keeps feet in time with the ground
local BLT_TAIL = 6 -- bullet length in studs, how far the head leads the tail

type EnemyObj = {
	part: Folder,
	model: Model,
	root: BasePart,
	speed: number,
	pos: Vector3,
	vel: Vector3,
	fwd: Vector3,
	tgtWp: number,
	side: number,
	height: Vector3,
}

type TowerObj = {
	root: BasePart,
	stats: { [string]: any },
	tgtVal: ObjectValue,
	barrel: BasePart,
	shoot: AnimationTrack,
	cool: number,
}

local enemies: { [Instance]: EnemyObj } = {}
local towers: { TowerObj } = {}
local waypoints: { Vector3 } = {}
local bltPool: { BasePart } = {}
-- Reused every frame by BulkMoveTo so moving a wave doesn't allocate two tables per frame.
local bulkPart: { BasePart } = {}
local bulkCf: { CFrame } = {}

---------------------------------------[[PATH]]---------------------------------------
-- Waypoints float at slightly different heights. Dropping each one onto the road means
-- the feet stay on the ground, without anyone having to place the parts perfectly.
local function buildPath(): ()
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { pathDir, twrDir, cliDir, vfxDir }
	for _, part in ipairs(pathDir:GetChildren()) do
		local hit = workspace:Raycast(part.Position + Vector3.yAxis * 5, Vector3.yAxis * -20, params)
		waypoints[tonumber(part.Name)] = hit and hit.Position or part.Position
	end
end

local function flatUnit(vec: Vector3, default: Vector3): Vector3
	local flat = Vector3.new(vec.X, 0, vec.Z)
	return flat.Magnitude > 0.01 and flat.Unit or default
end

-- Keeps turning at the same speed whatever the framerate; a fixed alpha wouldn't.
local function turnAlpha(dt: number): number
	return math.clamp(TURN_RATE * dt, 0, 1)
end

---------------------------------------[[ENEMIES]]---------------------------------------
local Enemy = {}
Enemy.__index = Enemy

-- Forces looping because the walk has to keep going whatever the asset was exported as.
local function playLoop(animator: Animator, anim: Animation, speed: number?): AnimationTrack
	local track = animator:LoadAnimation(anim)
	track.Looped = true
	track:Play(nil, nil, speed)
	return track
end

function Enemy.new(part: Folder): EnemyObj
	local def = EnemyData[part:GetAttribute("EnemyID")]
	local speed = part:GetAttribute("Speed")
	local model = def.model.Model:Clone()
	local root = model.PrimaryPart
	-- The root's centre sits half a root plus one leg above the feet. Read from the model
	-- because the Tank is scaled up and would sink into the road with a fixed number.
	local height = Vector3.yAxis * (root.Size.Y / 2 + model["Left Leg"].Size.Y)
	local start = waypoints[1]
	local fwd = flatUnit(waypoints[2] - start, -Vector3.zAxis)

	root.CFrame = CFrame.lookAt(start + height, start + height + fwd)
	model.Name = part.Name
	model.Parent = cliDir
	playLoop(model.AnimationController.Animator, model.Animation, speed * ANIM_RATE)

	return setmetatable({
		part = part,
		model = model,
		root = root,
		speed = speed,
		pos = start,
		vel = fwd * speed,
		fwd = fwd,
		tgtWp = 2,
		side = (math.random() * 2 - 1) * SIDE_SPRD,
		height = height,
	}, Enemy) :: any
end

--[[ leftover distance carries past a corner, which
is what keeps both sides in step without sending positions. stops at the last waypoint
and waits there for the server to remove it.]]
function Enemy:walk(dt: number): ()
	local left = self.speed * dt
	while left > 0 do
		local wp = waypoints[self.tgtWp]
		if not wp then
			self.vel = Vector3.zero
			return
		end
		local dir = wp - self.pos
		local dist = dir.Magnitude
		if dist > 0 then
			self.vel = dir.Unit * self.speed
			self.fwd = flatUnit(dir, self.fwd)
		end
		if dist > left then
			self.pos += dir.Unit * left
			return
		end
		self.pos = wp
		self.tgtWp += 1
		left -= dist
	end
end

-- returns CFrame instead of applying it so the frame loop can move every enemy in
-- one bulkmoveTo call, which is far cheaper than setting CFrame on each root.
function Enemy:step(dt: number): CFrame
	self:walk(dt)
	-- The sidestep follows the model's CURRENT facing, not the path's. Using the path's
	-- would snap the enemy sideways at a corner while it is still mid-turn.
	local look = self.root.CFrame.LookVector
	local perp = Vector3.new(-look.Z, 0, look.X)
	local newPos = self.pos + self.height + perp * self.side
	local rotated = CFrame.new(newPos) * self.root.CFrame.Rotation
	return rotated:Lerp(CFrame.lookAt(newPos, newPos + self.fwd), turnAlpha(dt))
end

-- Where a bullet leaving now should aim, so it meets the enemy instead of landing behind.
function Enemy:aimPos(flight: number): Vector3
	return self.root.Position + self.vel * flight
end

function Enemy:destroy(): ()
	self.model:Destroy() -- the animation track goes with it
end

local function addEnemy(part: Instance): ()
	enemies[part] = Enemy.new(part :: Folder)
end

local function delEnemy(part: Instance): ()
	local enm = enemies[part]
	if enm then
		enm:destroy()
		enemies[part] = nil
	end
end

---------------------------------------[[BULLETS]]---------------------------------------
-- Towers fire constantly, so bullets are recycled instead of cloned and destroyed.
local function takeBlt(): BasePart
	local blt = table.remove(bltPool)
	if not blt then
		blt = bltTmpl:Clone()
		blt.Beam.Enabled = false -- hidden until both ends are on the barrel
		blt.Parent = vfxDir
	end
	return blt
end

local function giveBlt(blt: BasePart): ()
	blt.Beam.Enabled = false
	table.insert(bltPool, blt)
end

--[[ The Beam stretches between two attachments, so the bullet is both ends travelling:
the head leaves straight away and the tail chases it after a short delay. That delay
is what gives the tracer its length, at any bullet speed.]]
local function shootBlt(from: Vector3, to: Vector3, speed: number): ()
	local flight = (to - from).Magnitude / speed
	local blt = takeBlt()
	local head, tail = blt.Point2, blt.Point1
	blt.Position = from
	head.WorldPosition = from
	tail.WorldPosition = from
	blt.Beam.Enabled = true

	local style, way = Enum.EasingStyle.Linear, Enum.EasingDirection.Out
	local gap = math.min(BLT_TAIL / speed, flight)
	local tailTwn = TweenSvc:Create(tail, TweenInfo.new(flight, style, way, 0, false, gap), { WorldPosition = to })
	-- The tail lands last, so its Completed is the moment the bullet is free to reuse.
	tailTwn.Completed:Once(function()
		giveBlt(blt)
	end)
	TweenSvc:Create(head, TweenInfo.new(flight, style, way), { WorldPosition = to }):Play()
	tailTwn:Play()
end

---------------------------------------[[TOWERS]]---------------------------------------
local Tower = {}
Tower.__index = Tower

function Tower.new(dir: Instance): TowerObj
	local model = dir:WaitForChild("Model")
	local gunDir = dir:FindFirstChildOfClass("Folder")
	local animator = model.AnimationController.Animator
	gunDir.HandleMiddle.Parent = model
	-- anim player
	playLoop(animator, gunDir.Idle).Priority = Enum.AnimationPriority.Idle
	return setmetatable({
		root = model.PrimaryPart,
		stats = TowerData[dir.Name],
		tgtVal = model:WaitForChild("Target"),
		barrel = gunDir.Barrel.Value,
		shoot = animator:LoadAnimation(gunDir.Shoot),
		cool = 0,
	}, Tower) :: any
end

-- stretches the shot over the attack interval so a fast and a slow gun can share the
-- rule. length is 0 until the asset has loaded, and dividing by it would break the speed.
function Tower:playShot(): ()
	local track = self.shoot
	track:Stop()
	track:Play(0)
	if track.Length > 0 then
		track:AdjustSpeed(track.Length / self.stats.atkSpeed)
	end
end

function Tower:fire(enm: EnemyObj): ()
	local stats = self.stats
	local from = self.barrel.Position
	local flight = (enm.root.Position - from).Magnitude / stats.bulletSpd
	self.cool = stats.atkSpeed
	self:playShot()
	shootBlt(from, enm:aimPos(flight), stats.bulletSpd)
end

-- the root is anchored and everything else hangs off it by joints, so turning this one
-- part turns the whole tower, gun included.
function Tower:face(pos: Vector3, dt: number): ()
	local base = self.root.Position
	local goal = CFrame.lookAt(base, base + flatUnit(pos - base, self.root.CFrame.LookVector))
	self.root.CFrame = self.root.CFrame:Lerp(goal, turnAlpha(dt))
end

-- The target can be a destroyed enemy for a moment (the server retargets once per shot).
-- It simply isn't in the table any more, and that's the only check needed.
function Tower:step(dt: number): ()
	self.cool -= dt
	local enm = enemies[self.tgtVal.Value]
	if not enm then
		return
	end
	self:face(enm.root.Position, dt)
	if self.cool <= 0 then
		self:fire(enm)
	end
end

---------------------------------------[[STARTUP]]---------------------------------------
buildPath()

for _, dir in ipairs(twrDir:GetChildren()) do
	table.insert(towers, Tower.new(dir))
end

-- whatever spawned while this client was loading wouldn't fire ChildAdded.
for _, part in ipairs(enmDir:GetChildren()) do
	addEnemy(part)
end
enmDir.ChildAdded:Connect(addEnemy)
enmDir.ChildRemoved:Connect(delEnemy)

RunService.RenderStepped:Connect(function(dt: number)
	table.clear(bulkPart)
	table.clear(bulkCf)
	for _, enm in enemies do
		table.insert(bulkPart, enm.root)
		table.insert(bulkCf, enm:step(dt))
	end
	workspace:BulkMoveTo(bulkPart, bulkCf, Enum.BulkMoveMode.FireCFrameChanged)
	-- towers go after enemies so they aim at this frame's positions, not last frame's.
	for _, twr in ipairs(towers) do
		twr:step(dt)
	end
end)
