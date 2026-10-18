dofile( "$SURVIVAL_DATA/Scripts/game/survival_collections.lua" )
dofile( "$SURVIVAL_DATA/Scripts/game/survival_constants.lua" )
dofile( "$SURVIVAL_DATA/Scripts/util.lua" )
dofile( "$SURVIVAL_DATA/Scripts/game/managers/QuestManager.lua" )
dofile( "$SURVIVAL_DATA/Scripts/game/managers/QuestEntityManager.lua" )
dofile( "$SURVIVAL_DATA/Scripts/game/managers/DialogManager.lua" )

DrillbotManager = class()
DrillbotManager.executionOrder = 49

local NextWagonOffset = sm.vec3.new( 0, 68, 0 )
local MoveCenterDuration = 5
local BossPlacementOffset = sm.vec3.new( 0, -75, -15 )

local Wagons = {
	sm.uuid.new( "d8b50b83-3b46-4a37-a6b2-3f689524572b" ),
	sm.uuid.new( "3b0123f1-f795-4464-89e7-0e7417cb4f08" ),
	sm.uuid.new( "b8499b1e-4dd7-4341-9074-7bed518d71b1" ),
}

local function IsWagon( uuid )
	return isAnyOf( uuid, Wagons )
end

local WagonRamp = sm.uuid.new( "a5d5080d-2385-420e-93dd-73b2f01ce0d4" )
local WagonHatch = sm.uuid.new( "5ee4c8d1-3a9b-4247-b003-389d59155183" )
local SideCartScoop = sm.uuid.new( "ebd59724-4b50-4102-8ef9-b988941562f2" )
local SideCartRoots = { sm.uuid.new( "f82d863d-543f-48ba-9368-986729b878d0" ), -- bosstrain sidecart02
						sm.uuid.new( "3b0123f1-f795-4464-89e7-0e7417cb4f08" ) -- bosstrain smallwagon
					}

local DefaultSphereJoints = 4 -- Standard amount of sphere joints. Used to calculate deformation
local SphereJointDiameterMin = 1.0 -- Min compressed
local SphereJointDiameterDefault = 4.0 -- Perfect sphere
local SphereJointDiameterMax = 6.0 -- Max stretched
local MinSpineLength = SphereJointDiameterMin * DefaultSphereJoints
local MaxSpineLength = SphereJointDiameterMax * DefaultSphereJoints
local MaxAllowedSphereJoints = 40 -- Arbitrary value that isn't infinite

function DrillbotManager.Cl_UpdateSphereJointEffects( upperCharacter, lowerCharacter, sphereJointEffects )
	if upperCharacter and upperCharacter:isVisible() and lowerCharacter and lowerCharacter:isVisible() then
		local upperSpineJoint = upperCharacter:getTpBonePos( "spine01_jnt" ) or upperCharacter.worldPosition
		local lowerSpineJoint = lowerCharacter:getTpBonePos( "upperbody_append_jnt" ) or lowerCharacter.worldPosition

		local spineVec = ( upperSpineJoint - lowerSpineJoint )
		local spineLength = spineVec:length()
		local spineDirection = spineVec:safeNormalize( sm.vec3.zero() )

		local sphereJointDiameter = math.max( math.min( spineLength , MaxSpineLength ), MinSpineLength ) / DefaultSphereJoints

		-- Calculate the amount of positions on the spine that are available
		local spineSteps = round( spineLength / sphereJointDiameter )
		local clampedSpineSteps = math.max( 1, math.min( MaxAllowedSphereJoints, spineSteps ) )

		-- Calculate positions for sphere effects on the spine
		local spinePositions = {}
		for i = 1, clampedSpineSteps do
			spinePositions[#spinePositions+1] = lowerSpineJoint + spineDirection * ( i - 1 ) * sphereJointDiameter
		end

		-- Update spine effects
		local defaultEffectDirection = sm.vec3.new( 0, 0, 1 )
		local scale = sphereJointDiameter / SphereJointDiameterDefault
		local sphereJointScale = sm.vec3.one() * 0.25 - defaultEffectDirection * 0.25 + defaultEffectDirection * 0.25 * scale
		local sphereJointRotation = sm.vec3.getRotation( defaultEffectDirection, spineDirection:safeNormalize( defaultEffectDirection ) )

		local iMax = math.max( #spinePositions, #sphereJointEffects )
		for i = 1, iMax do
			local sphereEffect = sphereJointEffects[i]
			if spinePositions[i] then
				if not sm.exists( sphereEffect ) then
					-- Create effect if it's missing
					sphereEffect = sm.effect.createEffect( "eff_drillbot_spherejoint" )
					sphereJointEffects[#sphereJointEffects+1] = sphereEffect
				end
				sphereEffect:setPosition( spinePositions[i] )
				sphereEffect:setRotation( sphereJointRotation )
				if i == 1 then
					-- Use default scale for the base
					sphereEffect:setScale( sm.vec3.one() * 0.25 )
				else
					sphereEffect:setScale( sphereJointScale )
				end
				if not sphereEffect:isPlaying() then
					sphereEffect:start()
				end
			else
				if sm.exists( sphereEffect ) and sphereEffect:isPlaying() then
					-- Turn off effect, if it exists
					sphereEffect:stop()
				end
			end
		end
	else
		-- Stop spine effects when one of the characters is missing.
		for _, sphereEffect in ipairs( sphereJointEffects ) do
			if sm.exists( sphereEffect ) and sphereEffect:isPlaying() then
				sphereEffect:stop()
			end
		end
	end
end

local BreakLockCount = 6

local TubeEffectEjectSpeed = 15
local TubeEffectEjectDistance = 45

local FightStageWagonPrefabs = {
	1,
	2,
	3,
	5
}
local FightStageCount = #FightStageWagonPrefabs - 1

local PlayerSpawnPoints = {
	sm.vec3.new( 1, 1, 10 ), sm.vec3.new( 0, 1, 10 ), sm.vec3.new( -1, 1, 10 ),
	sm.vec3.new( 1, 0, 10 ), sm.vec3.new( 0, 0, 10 ), sm.vec3.new( -1, 0, 10 ),
	sm.vec3.new( 1, -1, 10 ), sm.vec3.new( 0, -1, 10 ), sm.vec3.new( -1, -1, 10 ),
}
local PlayerSpawnPitch = DegToRad( 0 )
local PlayerSpawnYaw = DegToRad( 180 )

local ExitCinematicName = "cinematic.drillbotend_exit"
local OutsideCinematicName = "cinematic.drillbotend_outside"

local DrillbotFightDialogUuid = "20d62271-e951-4af7-9ea8-e5426a76255e"
local CombatDialogCooldownTicks = 40 * 14
local DownDialogCooldownTicks = 40 * 10
local TransitionDialogCooldownTicks = 40 * 6

local DrillbotFightDialogEntries = {
	fight = {
		Hubert_Clone = { "hubert_dbf_fight_01", "hubert_dbf_fight_02", "hubert_dbf_fight_03", "hubert_dbf_fight_04", "hubert_dbf_fight_05" },
		Lorenzo_Clone = { "lorenzo_dbf_fight_01", "lorenzo_dbf_fight_02", "lorenzo_dbf_fight_03", "lorenzo_dbf_fight_04", "lorenzo_dbf_fight_05" },
	},
	down = {
		Hubert_Clone = { "hubert_dbf_down_01", "hubert_dbf_down_02", "hubert_dbf_down_03", "hubert_dbf_down_04" },
		Lorenzo_Clone = { "lorenzo_dbf_down_01", "lorenzo_dbf_down_02", "lorenzo_dbf_down_03", "lorenzo_dbf_down_04" },
	},
	transition = {
		Hubert_Clone = { "hubert_dbf_transition_01", "hubert_dbf_transition_02", "hubert_dbf_transition_03", "hubert_dbf_transition_04" },
		Lorenzo_Clone = { "lorenzo_dbf_transition_01", "lorenzo_dbf_transition_02", "lorenzo_dbf_transition_03", "lorenzo_dbf_transition_04" },
	}
}

local DrillbotFightActorTracks = {
	Lorenzo_Clone = { "drillbot_wagon_lorenzo01", "drillbot_wagon_lorenzo02", "drillbot_wagon_lorenzo03", "drillbot_wagon_lorenzo04" },
	Hubert_Clone = { "drillbot_wagon_hubert01", "drillbot_wagon_hubert02", "drillbot_wagon_hubert03", "drillbot_wagon_hubert04" }
}

local DrillbotFightDialogSpeakers = {
	{ actorName = "Hubert_Clone", speakerName = DialogSpeakerName.Hubert_Clone },
	{ actorName = "Lorenzo_Clone", speakerName = DialogSpeakerName.Lorenzo_Clone }
}

local EndCinematicSequence = {
	{ pieceType = DrillbotTrackTypes.Cinematic, id = 1 },
}

local TestSequence = {
	{ pieceType = DrillbotTrackTypes.DownTransition, id = 1 },
	{ pieceType = DrillbotTrackTypes.Down, id = 1 },
	{ pieceType = DrillbotTrackTypes.DownTransition, id = 1 },
	{ pieceType = DrillbotTrackTypes.Down, id = 1 },
	{ pieceType = DrillbotTrackTypes.DownTransition, id = 1 },
	{ pieceType = DrillbotTrackTypes.Down, id = 1 },
}

-- Gyro-Core boss shortcut: retain the mandatory wagon exit/entry transitions,
-- but omit the rollercoaster sections and their falling-bot ambushes.
local StageSequences = {
	{
		{ pieceType = DrillbotTrackTypes.EndTransition, id = 1 },
		{ pieceType = DrillbotTrackTypes.End, id = 1 },
		{ pieceType = DrillbotTrackTypes.Enter, id = 3 }
	},
	{
		{ pieceType = DrillbotTrackTypes.EndTransition, id = 1 },
		{ pieceType = DrillbotTrackTypes.End, id = 1 },
		{ pieceType = DrillbotTrackTypes.Enter, id = 1 }
	},
	{
		{ pieceType = DrillbotTrackTypes.EndTransition, id = 1 },
		{ pieceType = DrillbotTrackTypes.End, id = 2 },
		{ pieceType = DrillbotTrackTypes.Enter, id = 5 }
	}
}

local CoasterIntroSequence1 = {
	{ pieceType = DrillbotTrackTypes.EndTransition, id = 1 },
	{ pieceType = DrillbotTrackTypes.End, id = 1 },
	{ pieceType = DrillbotTrackTypes.Rollercoaster, id = 1 },
	{ pieceType = DrillbotTrackTypes.Rollercoaster, id = 2 },
	{ pieceType = DrillbotTrackTypes.Rollercoaster, id = 3 },
}

local CoasterOutroSequence1 = {
	{ pieceType = DrillbotTrackTypes.Rollercoaster, id = 4 },
	{ pieceType = DrillbotTrackTypes.Rollercoaster, id = 5 },
	{ pieceType = DrillbotTrackTypes.Enter, id = 1 }
}

-- TODO choose these on train cart index, instead of random
local DownTransitionPool = {
	{
		{ pieceType = DrillbotTrackTypes.DownTransition, id = 2 },
		{ pieceType = DrillbotTrackTypes.DownTransition, id = 1 }
	},
	{
		{ pieceType = DrillbotTrackTypes.DownTransition, id = 2 },
		{ pieceType = DrillbotTrackTypes.DownTransition, id = 1 }
	}
}

-- Rollercoaster ambush node activation tables
-- Each entry: { name = "eventNodeName", tickDelay = ticksBeforeActivation }
local CoasterAmbush1Nodes = {
	{ name = "coasterAmbush1-1", tickDelay = 0 },
	{ name = "coasterAmbush1-2", tickDelay = 40 * 2 },
}
local CoasterAmbush2Nodes = {
	{ name = "coasterAmbush2-1", tickDelay = 0 },
	{ name = "coasterAmbush2-2", tickDelay = 40 * 2 },
	{ name = "coasterAmbush2-3", tickDelay = 40 * 4 },
}

-- Attacks
local DelayTickTime = 40 * 3 -- Time spent in the delay state
local ScytheMaxTickTime = 40 * 35 -- Max time before aborting the scythe state
local ShootMaxTickTime = 40 * 20 -- Max time before aborting the shoot state

local AttackStartTicksByPreviousAttack = {
	-- previous attack's out animation used to base the sync window on
	[DrillbotAttack.ATTACK_LEFT] = 80,
	[DrillbotAttack.ATTACK_RIGHT] = 80,
	[DrillbotAttack.COMBO_LEFT01] = 80,
	[DrillbotAttack.COMBO_LEFT02] = 80,
	[DrillbotAttack.SHOOT] = 85
}

local function GetAttackStartTicks( attackState )
	return AttackStartTicksByPreviousAttack[attackState] or 0
end
local MechanicsPotatoDamage = 5
local MechanicsPotatoVelocity = 36
local MechanicsPotatoShootInitialTickDelay = 40 * 8
local MechanicsPotatoShootCooldownTicks = 6

local AttackPatterns =
{
	{ -- Stage 1
		{
			pattern = { DrillbotAttack.ATTACK_LEFT,
						DrillbotAttack.ATTACK_RIGHT },	
			sidecarts = { 	{ side = "left", index = 1, delay = 12 },
							{ side = "left", index = 12, delay = 31 } },
			nextPatternIndex = { 2 }
		},
		{
			pattern = { DrillbotAttack.SHOOT },
			sidecarts = { 	{ side = "right", index = 1, delay = 4 } },
			nextPatternIndex = { 3 }
		},
		{
			pattern = { DrillbotAttack.DELAY },
			nextPatternIndex = { 4 }
		},
		{
			pattern = { DrillbotAttack.ATTACK_LEFT,
						DrillbotAttack.ATTACK_RIGHT },
			sidecarts = { 	{ side = "left", index = 2, delay = 12 } },
			nextPatternIndex = { 5 }
		},
		{
			pattern = { DrillbotAttack.DRILL },
			nextPatternIndex = { 5 }
		}
	},
	{ -- Stage 2
		{
			pattern = { DrillbotAttack.SHOOT },
			sidecarts = { 	{ side = "right", index = 1, delay = 0 },
							{ side = "left", index = 1, delay = 0 },
							{ side = "right", index = 12, delay = 6 } },
			nextPatternIndex = { 2 }
		},
		{
			pattern = { DrillbotAttack.SHOOT },
			nextPatternIndex = { 3 }
		},
		{
			pattern = { DrillbotAttack.ATTACK_LEFT,
						DrillbotAttack.ATTACK_RIGHT },
			sidecarts = { 	{ side = "left", index = 3, delay = 13 },
							{ side = "right", index = 4, delay = 32 } },
			nextPatternIndex = { 4 }
		},
		{
			pattern = { DrillbotAttack.DELAY, DrillbotAttack.DELAY, DrillbotAttack.DELAY },
			nextPatternIndex = { 5 }
		},
		{
			pattern = { DrillbotAttack.SHOOT },
			sidecarts = { { side = "right", index = 7, delay = 0 } },
			nextPatternIndex = { 6 }
		},
		{
			pattern = { DrillbotAttack.DRILL },
			nextPatternIndex = { 6 }
		}
	},
	{ -- Stage 3
		{
			pattern = { DrillbotAttack.ATTACK_LEFT },
			sidecarts = { 	{ side = "right", index = 12, delay = 0 },
							{ side = "left", index = 8, delay = 8 } },
			nextPatternIndex = { 2 }
		},
		{
			pattern = { DrillbotAttack.DELAY, DrillbotAttack.DELAY},
			nextPatternIndex = { 3 }
		},
		{
			pattern = { DrillbotAttack.ATTACK_RIGHT },
			sidecarts = { 	{ side = "right", index = 9, delay = 8 } },
			nextPatternIndex = { 4 }
		},
		{
			pattern = { DrillbotAttack.DELAY, DrillbotAttack.DELAY, DrillbotAttack.DELAY, DrillbotAttack.DELAY  },
			nextPatternIndex = { 5 }
		},
		{
			pattern = { DrillbotAttack.COMBO_LEFT01 },
			sidecarts = { 	{ side = "left", index = 12, delay = 11 }, 
							{ side = "right", index = 4, delay = 15 } },
			nextPatternIndex = { 6 }
		},
		{
			pattern = { DrillbotAttack.SHOOT },
			nextPatternIndex = { 7 }
		},
		{
			pattern = { DrillbotAttack.DELAY, DrillbotAttack.DELAY },
			sidecarts = { 	{ side = "left", index = 7, delay = 15 } }, -- Do not use a right side cart from here on, it may block the cinematic mechanic car from spawning
			nextPatternIndex = { 8 }
		},
		{
			pattern = { DrillbotAttack.COMBO_LEFT02 },
			nextPatternIndex = { 9 }
		},
		{
			pattern = { DrillbotAttack.DRILL },
			nextPatternIndex = { 9 }
		}
	},
	{ -- Stage 4
		{
			pattern = { DrillbotAttack.DELAY },
			nextPatternIndex = { 1 }
		}
	}
}


































































































































































































































































































































































DrillbotManager.DrillbotTrackOverrideAnimations = {
	"enter_start",
	"enter_ceiling",
	"enter_wall_right",
	"enter_wall_left",
	"enter_floor",
	"enter_destructcinematic",
	"ani_destructcinematic",
	"stuck_in_prep",
	"stuck_in",
	"stuck_loop",
	"stuck_out",
	"stuck_out_loop",
	"stuck_out_run"
}

--[[ Server ]]

function DrillbotManager.sv_makeClientData( self )
	return {
		currentCartIdx = self.sv.saved.currentCartIdx,
		cartArray = self.sv.saved.cartArray,
		outOfArenaPlayers = self.sv.saved.outOfArenaPlayers,
		fightCenter = self.sv.saved.fightCenter,
		runningState = self.sv.saved.runningState,
		pendingRunningStateTransition = self.sv.saved.pendingRunningStateTransition,
	}
end

function DrillbotManager.sv_initData( self )
	self.sv.saved = sm.storage.load( STORAGE_CHANNEL_DRILLBOT_MANAGER )
	if self.sv.saved == nil then
		self.sv.saved = {
			currentCartIdx = 0,
			cartArray = { false, false, false, false },
			fightCenter = sm.vec3.new( 0, 0, 0 ),
			lastTrackPieceType = nil,
			runningState = "center",
			pendingRunningStateTransition = nil,
			
			playerList = {},
			outOfArenaPlayers = {},
			activated = false,

			leftSideCart = nil,
			rightSideCart = nil,

			endCinematic = false
		}
		-- save data is synchronized when on world load callback
	end

	-- all created kinematics will store themselves here using their storageTag
	-- when created from the terrain script they will register via Sv_RegisterKinematic
	self.sv.namedKinematics = {}
	self.sv.sideCartRequestQueue = {}
	self.sv.eventSpawnNodes = {}
	self.sv.mechanicsUnits = {}
	self.sv.mechanicsNextShootTickByUnit = {}
	self.sv.dialogState = {
		nextCategoryTick = { fight = 0, down = 0, transition = 0 },
		lastSpeakerActorName = nil,
		lastEntryBySpeaker = {}
	}

	-- Boss state
	if self.sv.saved.lastTrackPieceType == DrillbotTrackTypes.Rollercoaster or self.sv.saved.lastTrackPieceType == DrillbotTrackTypes.End then
		self.sv.showDrillbot = false
	else
		self.sv.showDrillbot = true
	end
	self.sv.lowerUnit = nil
	self.sv.upperUnit = nil
	self.sv.bossState = {
		faceHits = 0, -- These hits damage the drillbot when downed
		targetPlayer = nil,
		attackState = nil,
		attackStartTick = nil,
		attackStateData = {},

		-- Attack pattern
		attackStage = 1,
		nextAttackPattern = 1,
		nextAttackIndex = 1,
		attackStateRevision = 0
	}
	self.sv.bossStateDirty = true

	-- TODO decide if boss state should be part of save data
end

function DrillbotManager.server_onCreate( self )
	local world = self.scriptableObject:getWorld()

	g_drillbotManagerServerWorld = g_drillbotManagerServerWorld or {}
	g_drillbotManagerServerWorld[world.id] = self
	self.sv = {}

	self.sv.tileStorageKey = TileStorageManager.Sv_GetTileStorageKeyFromCell( world, 0, 0 )
	
	self:sv_initData()

	self:loadPrefabs()

	
	sm.storage.save( STORAGE_CHANNEL_DRILLBOT_MANAGER, self.sv.saved )
	self.network:setClientData( self.sv.bossState, 2 )
	self.network:setClientData( self:sv_makeClientData(), 1 )

	if not self.sv.saved.finishedFight then
		self.sv.loadDummy = self.scriptableObject:getWorld():loadCellWithHandle( 0, 0 ) -- ensure world remains loaded even as players move in and out.
	end
end

function DrillbotManager.sv_bumpAttackState( self )
	local revisionThreshold = 1000000 -- Arbitrary value to avoid inf
	self.sv.bossState.attackStateRevision = ( self.sv.bossState.attackStateRevision + 1 ) % revisionThreshold
end



function DrillbotManager.server_onUnload( self )
	sm.storage.save( STORAGE_CHANNEL_DRILLBOT_MANAGER, self.sv.saved )
end

function DrillbotManager.sv_getRandomDialogEntry( self, category, actorName )
	local entriesBySpeaker = DrillbotFightDialogEntries[category]
	if not entriesBySpeaker then
		return nil
	end

	local entries = entriesBySpeaker[actorName]
	if not entries or #entries == 0 then
		return nil
	end

	local randomIndex = math.random( #entries )
	local entry = entries[randomIndex]
	local lastEntry = self.sv.dialogState.lastEntryBySpeaker[actorName]
	if #entries > 1 and entry == lastEntry then
		randomIndex = ( randomIndex % #entries ) + 1
		entry = entries[randomIndex]
	end
	self.sv.dialogState.lastEntryBySpeaker[actorName] = entry
	return entry
end

function DrillbotManager.sv_playRandomFightDialog( self, category, cooldownTicks, optionalActorName )
	if not DialogManager or not DialogSpeakerName or not self.sv.dialogState then
		return
	end

	local currentTick = sm.game.getCurrentTick()
	local nextAllowedTick = self.sv.dialogState.nextCategoryTick[category] or 0
	if currentTick < nextAllowedTick then
		return
	end

	local availableSpeakers = {}
	for _, speaker in ipairs( DrillbotFightDialogSpeakers ) do
		if speaker.speakerName then
			local isValidSpeaker = false
			if optionalActorName then
				isValidSpeaker = speaker.actorName == optionalActorName
			else
				isValidSpeaker = speaker.actorName ~= self.sv.dialogState.lastSpeakerActorName
			end
			if isValidSpeaker then
				local unit = QuestActorManager.Sv_GetActorUnit( speaker.actorName )
				if unit then
					availableSpeakers[#availableSpeakers + 1] = {
						actorName = speaker.actorName,
						speakerName = speaker.speakerName,
						unit = unit
					}
				end
			end
		end
	end

	if #availableSpeakers == 0 then
		return
	end

	local selectedSpeaker = availableSpeakers[math.random( #availableSpeakers )]
	local entry = self:sv_getRandomDialogEntry( category, selectedSpeaker.actorName )
	if not entry then
		return
	end

	DialogManager.Sv_PlayDialog(
		DrillbotFightDialogUuid,
		entry,
		self.scriptableObject,
		DialogType.Person,
		selectedSpeaker.speakerName,
		DialogPriority.Shout,
		selectedSpeaker.unit
	)

	self.sv.dialogState.lastSpeakerActorName = selectedSpeaker.actorName
	self.sv.dialogState.nextCategoryTick[category] = currentTick + cooldownTicks
end

function DrillbotManager.Sv_SideCartDestroyed( world, rootStorageTag )
	if g_drillbotManagerServerWorld[world.id] then
		g_drillbotManagerServerWorld[world.id]:sv_sideCartDestroyed( rootStorageTag )
	end
end

function DrillbotManager.sv_sideCartDestroyed( self, rootStorageTag )
	
	local removeSideCart = false
	local removedSidecart = nil
	if self.sv.saved.leftSideCart and self.sv.saved.leftSideCart.rootStorageTag == rootStorageTag then
		self.sv.saved.leftSideCart = nil
		removeSideCart = true
		removedSidecart = "leftSideCart"
	end
	if self.sv.saved.rightSideCart and self.sv.saved.rightSideCart.rootStorageTag == rootStorageTag then
		self.sv.saved.rightSideCart = nil
		removeSideCart = true
		removedSidecart = "rightSideCart"
	end
	if removeSideCart then
		local tsKinematics = TileStorageManager.Sv_GetValue( self.sv.tileStorageKey, DRILLBOT_KINEMATICS_TABLE )
		tsKinematics = tsKinematics or {}
		if self.sv.saved.rightSideCart == nil and tsKinematics.rightSideCart then
			for key, _ in pairs( tsKinematics.rightSideCart ) do
				tsKinematics.rightSideCart[key] = nil
			end
		end
		if self.sv.saved.leftSideCart == nil and tsKinematics.leftSideCart then
			for key, _ in pairs( tsKinematics.leftSideCart ) do
				tsKinematics.leftSideCart[key] = nil
			end
		end

		local tsKinematicsStorage = TileStorageManager.Sv_GetValue( self.sv.tileStorageKey, KINEMATIC_STORAGE_TABLE ) or {}
		for key, _ in pairs( tsKinematicsStorage ) do
			if key:match( removedSidecart ) then
				tsKinematicsStorage[key] = nil
			end
		end
		TileStorageManager.Sv_SetValue( self.sv.tileStorageKey, KINEMATIC_STORAGE_TABLE, tsKinematicsStorage )
		TileStorageManager.Sv_SetValue( self.sv.tileStorageKey, DRILLBOT_KINEMATICS_TABLE, tsKinematics )
		TileStorageManager.Sv_Save()
	end
end

function DrillbotManager.sv_updateCombat( self )
	local currentTick = sm.game.getCurrentTick()

	-- Spawn side carts
	for index = #self.sv.sideCartRequestQueue, 1, -1 do
		local sideCartRequest = self.sv.sideCartRequestQueue[index]
		local sidecartAvailable =
			( self.sv.saved.leftSideCart == nil and sideCartRequest.side == "left" )
			or ( self.sv.saved.rightSideCart == nil and sideCartRequest.side == "right" )
		if sidecartAvailable then
			if currentTick >= sideCartRequest.triggerTick then
	


				self:sv_e_requestSideCart( sideCartRequest )
				table.remove( self.sv.sideCartRequestQueue, index )
			end
		end
	end

	if self.sv.saved.breakLockSignal then
		-- Force combat to stop when the locks are broken
		self.sv.requestStopAttack = true
	end

	local upperCharacter = self.sv.upperUnit and self.sv.upperUnit.character or nil

	local finishedAttackState = nil
	local function finishAttack()
		finishedAttackState = self.sv.bossState.attackState
		self:sv_playRandomFightDialog( "fight", CombatDialogCooldownTicks )
		self.sv.bossState.attackStateData = {}
		self.sv.bossState.attackState = nil
		self.sv.bossState.attackStartTick = nil
		self:sv_bumpAttackState()
		self.sv.bossStateDirty = true
	end

	-- Update state conditions
	if self.sv.bossState.attackState then
		if self.sv.bossState.attackState == DrillbotAttack.DELAY then
			if self.sv.requestStopAttack or currentTick >= self.sv.bossState.attackStateData.delayTimeoutTick then
				-- Finish delay
				finishAttack()
			else
				-- Go center
				if not isAnyOf( "center", { self.sv.requestRunState, self.sv.saved.runningState } ) and self.sv.saved.pendingRunningStateTransition == nil then
					self.sv.requestRunState = "center"
				end
			end
		elseif self.sv.bossState.attackState == DrillbotAttack.ATTACK_LEFT then
			if self.sv.requestStopAttack or currentTick >= self.sv.bossState.attackStateData.scytheTimeoutTick then
				-- Finish left attack
				finishAttack()
			else
				-- Go left
				if not isAnyOf( "left", { self.sv.requestRunState, self.sv.saved.runningState } ) and self.sv.saved.pendingRunningStateTransition == nil then
					self.sv.requestRunState = "left"
				end
			end
		elseif self.sv.bossState.attackState == DrillbotAttack.ATTACK_RIGHT then
			if self.sv.requestStopAttack or currentTick >= self.sv.bossState.attackStateData.scytheTimeoutTick then
				-- Finish right attack
				finishAttack()
			else
				-- Go right
				if not isAnyOf( "right", { self.sv.requestRunState, self.sv.saved.runningState } ) and self.sv.saved.pendingRunningStateTransition == nil then
					self.sv.requestRunState = "right"
				end
			end
		elseif self.sv.bossState.attackState == DrillbotAttack.DRILL then
			if self.sv.requestStopAttack then
				-- Finish drill attack
				finishAttack()
			else
				-- Go center
				if not isAnyOf( "center", { self.sv.requestRunState, self.sv.saved.runningState } ) and self.sv.saved.pendingRunningStateTransition == nil then
					self.sv.requestRunState = "center"
				end
			end
		elseif self.sv.bossState.attackState == DrillbotAttack.SHOOT then
			if self.sv.requestStopAttack or currentTick >= self.sv.bossState.attackStateData.shootTimeoutTick then
				-- Finish shoot attack
				finishAttack()
			else
				-- Go center
				if not isAnyOf( "center", { self.sv.requestRunState, self.sv.saved.runningState } ) and self.sv.saved.pendingRunningStateTransition == nil then
					self.sv.requestRunState = "center"
				end
			end
		elseif self.sv.bossState.attackState == DrillbotAttack.COMBO_LEFT01 then
			if self.sv.requestStopAttack or currentTick >= self.sv.bossState.attackStateData.scytheTimeoutTick then
				-- Finish left attack
				finishAttack()
			else
				-- Go left
				if not isAnyOf( "left", { self.sv.requestRunState, self.sv.saved.runningState } ) and self.sv.saved.pendingRunningStateTransition == nil then
					self.sv.requestRunState = "left"
				end
			end
		elseif self.sv.bossState.attackState == DrillbotAttack.COMBO_LEFT02 then
			if self.sv.requestStopAttack or currentTick >= self.sv.bossState.attackStateData.scytheTimeoutTick then
				-- Finish left attack
				finishAttack()
			else
				-- Go left
				if not isAnyOf( "left", { self.sv.requestRunState, self.sv.saved.runningState } ) and self.sv.saved.pendingRunningStateTransition == nil then
					self.sv.requestRunState = "left"
				end
			end
		end
	end
	self.sv.requestStopAttack = nil

	-- Select a combat state, as long as the locks are not broken
	if self.sv.bossState.attackState == nil and not self.sv.saved.breakLockSignal then
		-- Select next attack
		-- Handled by character until finished or aborted
		local attackStage = AttackPatterns[self.sv.bossState.attackStage]
		local attackPattern = attackStage[self.sv.bossState.nextAttackPattern]
		local nextAttack = attackPattern.pattern[self.sv.bossState.nextAttackIndex]

		-- Queue the side cart spawns for this attack pattern
		if attackPattern.sidecarts and self.sv.bossState.nextAttackIndex == 1 then
			for _, sideCartData in ipairs( attackPattern.sidecarts ) do
				local delayTicks = math.max( 0, math.floor( ( sideCartData.delay or 0 ) * 40 ) )
				self.sv.sideCartRequestQueue[#self.sv.sideCartRequestQueue + 1] = {
					side = sideCartData.side,
					index = sideCartData.index,
					triggerTick = currentTick + delayTicks
				}



			end
		end




		self.sv.bossState.nextAttackIndex = self.sv.bossState.nextAttackIndex + 1
		if self.sv.bossState.nextAttackIndex > #attackPattern.pattern then
			self.sv.bossState.nextAttackPattern = attackPattern.nextPatternIndex[math.random( 1, #attackPattern.nextPatternIndex )]
			self.sv.bossState.nextAttackIndex = 1
		end
		self.sv.bossState.attackState = nextAttack
		self.sv.bossState.attackStartTick = currentTick + GetAttackStartTicks( finishedAttackState )
		local attackOrigin = upperCharacter and ( upperCharacter:getTpBonePos( "drill_jnt" ) or upperCharacter.worldPosition ) or self.sv.saved.fightCenter
		local targetPlayer = nil
		if attackOrigin then
			local closestPlayer = GetClosestPlayer( attackOrigin, nil, self.scriptableObject:getWorld() )
			if closestPlayer and sm.exists( closestPlayer.character ) then
				targetPlayer = closestPlayer
			end
		end
		self.sv.bossState.targetPlayer = targetPlayer
		self:sv_bumpAttackState()




		self.sv.bossStateDirty = true

		-- Setup initial conditions for combat states
		self.sv.bossState.attackStateData = {}

		if self.sv.bossState.attackState == DrillbotAttack.DELAY then
			self.sv.bossState.attackStateData.delayTimeoutTick = currentTick + DelayTickTime
		elseif self.sv.bossState.attackState == DrillbotAttack.ATTACK_LEFT then
			self.sv.bossState.attackStateData.scytheTimeoutTick = currentTick + ScytheMaxTickTime
		elseif self.sv.bossState.attackState == DrillbotAttack.ATTACK_RIGHT then
			self.sv.bossState.attackStateData.scytheTimeoutTick = currentTick + ScytheMaxTickTime
		elseif self.sv.bossState.attackState == DrillbotAttack.SHOOT then
			self.sv.bossState.attackStateData.shootTimeoutTick = currentTick + ShootMaxTickTime
		elseif self.sv.bossState.attackState == DrillbotAttack.COMBO_LEFT01 then
			self.sv.bossState.attackStateData.scytheTimeoutTick = currentTick + ScytheMaxTickTime
		elseif self.sv.bossState.attackState == DrillbotAttack.COMBO_LEFT02 then
			self.sv.bossState.attackStateData.scytheTimeoutTick = currentTick + ScytheMaxTickTime
		end
	end
end

function DrillbotManager.sv_updateMechanicsShooting( self, currentTick )

	if #self.sv.mechanicsUnits == 0 then
		return
	end

	if not ( self.sv.upperUnit and sm.exists( self.sv.upperUnit ) ) then
		return
	end

	local drillbotCharacter = self.sv.upperUnit.character
	local drillbotHeadPos = drillbotCharacter and ( drillbotCharacter:getTpBonePos( "head_rot_jnt" ) or drillbotCharacter.worldPosition ) or nil
	if not drillbotHeadPos then
		return
	end

	for i = #self.sv.mechanicsUnits, 1, -1 do
		local mechanicUnit = self.sv.mechanicsUnits[i]
		if sm.exists( mechanicUnit ) and mechanicUnit.character then
			local nextShootTick = self.sv.mechanicsNextShootTickByUnit[mechanicUnit.id] or 0
			if currentTick >= nextShootTick then
				local mechanicCharacter = mechanicUnit.character
				local mechanicShootPos = mechanicCharacter:getTpBonePos( "jnt_right_hand" ) or mechanicCharacter.worldPosition
				local aimDirection = ( drillbotHeadPos - mechanicShootPos ):safeNormalize( sm.vec3.new( 0, 1, 0 ) )
				sm.projectile.projectileAttack( projectile_cinematic_potato, MechanicsPotatoDamage, mechanicShootPos, aimDirection * MechanicsPotatoVelocity, mechanicUnit )
				self.sv.mechanicsNextShootTickByUnit[mechanicUnit.id] = currentTick + MechanicsPotatoShootCooldownTicks
			end
		else
			self.sv.mechanicsNextShootTickByUnit[mechanicUnit.id] = nil
			table.remove( self.sv.mechanicsUnits, i )
		end
	end
end

function DrillbotManager.server_onFixedUpdate( self, dt )
	local currentTick = sm.game.getCurrentTick()

	-- Gyro-Core boss shortcut: discard queued rollercoaster ambush spawns.
	self.sv.pendingAmbushNodes = nil
	-- Process pending delayed ambush node activations
	if self.sv.pendingAmbushNodes and #self.sv.pendingAmbushNodes > 0 then
		local remaining = {}
		for _, entry in ipairs( self.sv.pendingAmbushNodes ) do
			if currentTick >= entry.triggerTick then
				self:sv_spawnEventNodes( entry.name, g_DrillbotWorld.world )
			else
				remaining[#remaining + 1] = entry
			end
		end
		self.sv.pendingAmbushNodes = remaining
	end

	-- If not activated, players in the world respawn at spawn point as if they had died in the fight.
	if not self.sv.saved.activated then
		local players = GetPlayersInWorld( self.scriptableObject:getWorld() )
		for _, player in ipairs( players ) do
			sm.event.sendToPlayer( player, "sv_e_drillbotEject" )
		end
		return
	end

	if not self.sv.bosstrainWagonPrefabs then
		return
	end
	
	local saveAndSync = false
	
	if self.sv.saved.outOfArenaPlayers then
		local toRemove = {}
		for playerId, value in pairs( self.sv.saved.outOfArenaPlayers ) do
			if value.timer > 0 then -- if on the last cart, skip the timer and appear on the platform immediately, since there is no spectate camera
				if self.sv.saved.currentCartIdx > FightStageCount then
					self.sv.saved.outOfArenaPlayers[playerId].timer = 0
				else
					self.sv.saved.outOfArenaPlayers[playerId].timer = math.max( 0, value.timer - dt )
				end
				-- skip saving timer changes
				if self.sv.saved.outOfArenaPlayers[playerId].timer == 0 then
					local player = self.sv.saved.outOfArenaPlayers[playerId].player
					if player and player.character then
						-- teleport back to arena, if next wagon exists, offset by that
						local offset -- if there is a next, land there.
						if self.sv.saved.cartArray and self.sv.saved.cartArray[self.sv.saved.currentCartIdx + 1] then
							offset = NextWagonOffset
						else
							offset = sm.vec3.zero()
						end
						
						local newCharacter = sm.character.createCharacter( player, g_DrillbotWorld.world, self.sv.saved.fightCenter + offset + sm.vec3.new( 0, -15, 7 ), 0, 0 )
						if newCharacter then
							player:setCharacter( newCharacter )
							newCharacter:setTumbling( true )
							newCharacter:setDowned( true )
							newCharacter:applyTumblingImpulse( RandomUnitVector() * newCharacter.mass )
						end
						toRemove[#toRemove + 1] = playerId
					end
				end
			else
				toRemove[#toRemove + 1] = playerId
			end
		end
		-- clear expired timers
	
		for _, playerId in ipairs( toRemove ) do
			if self.sv.saved.outOfArenaPlayers[playerId] then
				local character = self.sv.saved.outOfArenaPlayers[playerId].player.character
				if ( character and character:isDowned() == false )
					or self.sv.saved.outOfArenaPlayers[playerId].cartIndex < self.sv.saved.currentCartIdx
					or self.sv.saved.cartArray[self.sv.saved.outOfArenaPlayers[playerId].cartIndex + 1] == false then
					-- remove out of arena status if player is revived, if the fight has progressed past their the cart they were on, or if there is no next cart
					self.sv.saved.outOfArenaPlayers[playerId] = nil
					saveAndSync = true -- clients care about existence
				end
			end
		end
	end

	self.sv.lowerUnit = sm.exists( self.sv.lowerUnit ) and self.sv.lowerUnit or nil
	self.sv.upperUnit = sm.exists( self.sv.upperUnit ) and self.sv.upperUnit or nil
	if self.sv.lowerUnit == nil and self.sv.showDrillbot then
		local params = {}
		self.sv.lowerUnit = sm.unit.createUnit( unit_drillbotLegs, self.sv.saved.fightCenter + BossPlacementOffset, 0, params, nil, false )
	end
	if self.sv.upperUnit == nil and self.sv.showDrillbot then
		local params = {}
		self.sv.upperUnit = sm.unit.createUnit( unit_drillbot, self.sv.saved.fightCenter + BossPlacementOffset, 0, params, nil, false )
	end
	self:sv_updateMechanicsShooting( currentTick )

	local currentCartStorageTag = self.sv.saved.cartArray[self.sv.saved.currentCartIdx].cartStorageTag

	if not sm.exists( self.sv.namedKinematics[currentCartStorageTag] ) then
		-- Recovery patch: A bug caused the the world to be stuck in a world without any carts, if we detect this we will reset the fight state and exit.
		local tsKinematics = TileStorageManager.Sv_GetValue( self.sv.tileStorageKey, DRILLBOT_KINEMATICS_TABLE )
		local currentCartPersisted = tsKinematics ~= nil and tsKinematics.carts ~= nil and tsKinematics.carts[self.sv.saved.currentCartIdx] ~= nil
		if not currentCartPersisted then
			print( "DRILLBOTMANAGER FixedUpdate: Current cart missing from tile storage, recovering broken fight state via sv_resetAndExit" )
			self:sv_resetAndExit()
		end
		return
	end

	if g_DrillbotWorld.world.publicData.piece and g_DrillbotWorld.world.publicData.piece.pieceType then
		local trackPieceType = g_DrillbotWorld.world.publicData.piece.pieceType
		local instanceId = g_DrillbotWorld.world.publicData.instanceId

		if self.sv.lastInstanceId ~= instanceId and self.sv.saved.pendingRunningStateTransition then
			self.sv.saved.runningState = self.sv.saved.pendingRunningStateTransition.state -- we have reached a new piece, we will apply the run state instantly for the server
			self.sv.saved.pendingRunningStateTransition = nil
			saveAndSync = true -- the servers true runstate is synced out.
		end

		if self.sv.requestRunState then
			self.sv.saved.pendingRunningStateTransition =  { state = self.sv.requestRunState, instanceId = instanceId + 1 } -- this transition will take place on the next track instance
			self.sv.requestRunState = nil
			saveAndSync = true -- client will receive the pending transition, will begin transition on the instanceId
		end

		if trackPieceType == g_DrillbotWorld.world.publicData.trackState then -- in a looping section
			if trackPieceType ~= DrillbotTrackTypes.Combat then
				-- Ensure no combat softlocks can occur
				if self.sv.bossState.attackState then
					self.sv.bossStateDirty = true
				end
				self.sv.bossState.attackState = nil
				self.sv.bossState.attackStateData = {}
			end

			if trackPieceType == DrillbotTrackTypes.Rollercoaster then
				if self.sv.endRollercoasterSignal then
					self:sv_requestLoopingState( DrillbotTrackTypes.Combat )
					self:sv_requestSequence( CoasterOutroSequence1 )
				end
			elseif trackPieceType == DrillbotTrackTypes.Combat then
				-- Gyro-Core boss shortcut: do not select any attacks or queue enemy sidecarts.
				-- Clear a previous attack too, in case the modification was enabled mid-fight.
				self.sv.sideCartRequestQueue = {}
				if self.sv.bossState.attackState ~= nil then
					self.sv.bossState.attackState = nil
					self.sv.bossState.attackStateData = {}
					self.sv.bossState.attackStartTick = nil
					self.sv.bossState.targetPlayer = nil
					self:sv_bumpAttackState()
					self.sv.bossStateDirty = true
				end

				-- Pretend all locks on this wagon have been broken, ONCE per cart.
				-- Reuse the original Combat -> Down transition (and its world-track setup).
				if self.sv.saved.skipCombatCart ~= self.sv.saved.currentCartIdx then
					self.sv.saved.skipCombatCart = self.sv.saved.currentCartIdx
					self.sv.saved.breakLockSignal = true
					saveAndSync = true
				end

				if self.sv.bosstrainWagonPrefabs then -- cannot spawn next wagon until this is loaded
					if self.sv.saved.breakLockSignal then
						if self.sv.saved.runningState == "center" then
							self:sv_requestLoopingState( DrillbotTrackTypes.Down )
							self:sv_requestSequenceFromPool( DownTransitionPool )
						else
							self:sv_requestLoopingState( DrillbotTrackTypes.Down )
							self.sv.saved.pendingRunningStateTransition = { state = "center", instanceId = instanceId + 1  }
							g_DrillbotWorld.Sv_QueueTrackRequest( { type = "piece", pieceType = DrillbotTrackTypes.Combat, id = 1 } ) -- request an extra piece for the transition to center
							self:sv_requestSequenceFromPool( DownTransitionPool )
							saveAndSync = true
						end
					end
				end
			elseif trackPieceType == DrillbotTrackTypes.Down then
				-- Gyro-Core boss shortcut: automatically finish the downed/hammer phase.
				-- The original flip path advances the wagon and queues the next section.
				if self.sv.saved.skipDownCart ~= self.sv.saved.currentCartIdx then
					self.sv.saved.skipDownCart = self.sv.saved.currentCartIdx
					self.sv.saved.trainFlipSignal = true
					saveAndSync = true
				end
				if self.sv.saved.trainFlipSignal then
					if false --[[loopable coaster]] then
						self:sv_requestLoopingState( DrillbotTrackTypes.Rollercoaster ) --set state to assume after sequence
						self:sv_requestSequence( CoasterIntroSequence1 ) -- request premade rollercoaster sequence
					else
						self:sv_requestLoopingState( DrillbotTrackTypes.Combat )
						local sequenceIndex = ( ( self.sv.saved.currentCartIdx - 1 ) % #StageSequences ) + 1
						self:sv_requestSequence( StageSequences[sequenceIndex] )

						local currentCartStorageTag = self.sv.saved.cartArray[self.sv.saved.currentCartIdx].cartStorageTag
						local cartKinematic = self.sv.namedKinematics[currentCartStorageTag]
						sm.event.sendToHarvestable( cartKinematic, "sv_e_setActiveTracks", { tracksToActivate = { "down_preflip" }, tracksToDeactivate = { "down_idle" } }  )
						sm.event.sendToHarvestable( cartKinematic, "sv_e_activate", { tick = sm.game.getCurrentTick(), trackName = "down_preflip" } )
						for _, name in pairs( DRILLBOT_FIGHT_ACTORS ) do
							QuestActorManager.Sv_NotifyActor( name, "notify.drillbot_preflip" )
						end
						self:sv_playRandomFightDialog( "transition", 0 )
						self:sv_playRandomFightDialog( "transition", 0 )
					end
					local currentRampStorageTag = self.sv.saved.cartArray[self.sv.saved.currentCartIdx].rampStorageTag
					local rampKinematic = self.sv.namedKinematics[currentRampStorageTag]
					sm.event.sendToHarvestable( rampKinematic, "sv_e_activate", { tick = sm.game.getCurrentTick(), trackName = "open" } )
					self.sv.saved.currentCartIdx = self.sv.saved.currentCartIdx + 1 -- next cart
					if self.sv.saved.currentCartIdx <= FightStageCount then -- spawn the next cart unless this was the last cart
						self:sv_spawnCart( self.sv.saved.currentCartIdx + 1 )
					else
						-- if there are no more carts to spawn, we will be on the platform for the end cinematic
						self:sv_requestSequence( EndCinematicSequence )
					end
					saveAndSync = true
				end
			elseif trackPieceType == DrillbotTrackTypes.Intro then
				self:sv_requestLoopingState( DrillbotTrackTypes.Combat )
			end
		end

		-- piece type change signaling moving to a new section
		if self.sv.saved.lastTrackPieceType ~= trackPieceType then
			-- when exiting a section
			if self.sv.saved.lastTrackPieceType == DrillbotTrackTypes.End then
				self.sv.showDrillbot = false
				if sm.exists( self.sv.lowerUnit )then
					self.sv.lowerUnit:destroy()
					self.sv.lowerUnit = nil
				end
				if sm.exists( self.sv.upperUnit ) then
					self.sv.upperUnit:destroy()
					self.sv.upperUnit = nil
				end
			end

			-- when entering a section
			if	trackPieceType == DrillbotTrackTypes.Rollercoaster then
				local currentCartStorageTag = self.sv.saved.cartArray[self.sv.saved.currentCartIdx].cartStorageTag
				local cartKinematic = self.sv.namedKinematics[currentCartStorageTag]
				sm.event.sendToHarvestable( cartKinematic, "sv_e_setActiveTracks", { tracksToActivate = { "rollercoaster_idle01" }, tracksToDeactivate = { "idle" } }  )
				sm.event.sendToHarvestable( cartKinematic, "sv_e_activate", { tick = sm.game.getCurrentTick(), trackName = "rollercoaster_idle01" } )

				-- Activate rollercoaster ambushers with per-node delays
				if not self.sv.pendingAmbushNodes then
					self.sv.pendingAmbushNodes = {}
				end
				local nodeTable = nil
				if self.sv.saved.currentCartIdx == 2 then
					nodeTable = CoasterAmbush1Nodes
				elseif self.sv.saved.currentCartIdx == 3 then
					nodeTable = CoasterAmbush2Nodes
				end
				if nodeTable then
					local currentTick = sm.game.getCurrentTick()
					for _, entry in ipairs( nodeTable ) do
						self.sv.pendingAmbushNodes[#self.sv.pendingAmbushNodes + 1] = {
							name = entry.name,
							triggerTick = currentTick + entry.tickDelay,
						}
					end
				end
			end
			if trackPieceType == DrillbotTrackTypes.DownTransition then
				local currentCartStorageTag = self.sv.saved.cartArray[self.sv.saved.currentCartIdx].cartStorageTag
				local cartKinematic = self.sv.namedKinematics[currentCartStorageTag]
				sm.event.sendToHarvestable( cartKinematic, "sv_e_setActiveTracks", { tracksToActivate = { "down_start" }, tracksToDeactivate = { "idle" } }  )
				sm.event.sendToHarvestable( cartKinematic, "sv_e_activate", { tick = sm.game.getCurrentTick(), trackName = "down_start" } )
				self.network:sendToClients( "cl_n_startBallBurstEffects", self.sv.saved.currentCartIdx )

				local currentHatch01StorageTag = self.sv.saved.cartArray[self.sv.saved.currentCartIdx].hatch01StorageTag
				local hatch01Kinematic = self.sv.namedKinematics[currentHatch01StorageTag]
				sm.event.sendToHarvestable( hatch01Kinematic, "sv_e_activate", { tick = sm.game.getCurrentTick(), trackName = "down_start" } )
				local currentHatch02StorageTag = self.sv.saved.cartArray[self.sv.saved.currentCartIdx].hatch02StorageTag
				local hatch02Kinematic = self.sv.namedKinematics[currentHatch02StorageTag]
				sm.event.sendToHarvestable( hatch02Kinematic, "sv_e_activate", { tick = sm.game.getCurrentTick(), trackName = "down_start" } )
			end
			if trackPieceType == DrillbotTrackTypes.EndTransition then
				self.network:sendToClients( "cl_n_startCountDown", self.sv.saved.currentCartIdx-1 )
				self.network:sendToClients( "cl_n_startWagonSlicedEffects", self.sv.saved.currentCartIdx - 1 )
			end
			if trackPieceType == DrillbotTrackTypes.Down then
				local currentCartStorageTag = self.sv.saved.cartArray[self.sv.saved.currentCartIdx].cartStorageTag
				local cartKinematic = self.sv.namedKinematics[currentCartStorageTag]
				sm.event.sendToHarvestable( cartKinematic, "sv_e_setActiveTracks", { tracksToActivate = { "down_idle" }, tracksToDeactivate = { "down_start" } }  )
				sm.event.sendToHarvestable( cartKinematic, "sv_e_activate", { tick = sm.game.getCurrentTick(), trackName = "down_idle" } )
				for _, name in pairs( DRILLBOT_FIGHT_ACTORS ) do
					QuestActorManager.Sv_NotifyActor( name, "notify.drillbot_down" )
				end
			end
			if trackPieceType == DrillbotTrackTypes.Enter then
				local currentCartStorageTag = self.sv.saved.cartArray[self.sv.saved.currentCartIdx].cartStorageTag
				local cartKinematic = self.sv.namedKinematics[currentCartStorageTag]
				sm.event.sendToHarvestable( cartKinematic, "sv_e_setActiveTracks", { tracksToActivate = { "idle" }, tracksToDeactivate = { "rollercoaster_idle01" } }  )
				sm.event.sendToHarvestable( cartKinematic, "sv_e_activate", { tick = sm.game.getCurrentTick(), trackName = "idle" } )

				self.sv.showDrillbot = true

				-- Reset face hits
				self.sv.bossState.faceHits = 0
				self.sv.bossState.attackStage = math.min( self.sv.bossState.attackStage + 1, #AttackPatterns )
				self.sv.bossState.nextAttackPattern = 1
				self.sv.bossState.nextAttackIndex = 1
				self:sv_bumpAttackState()
				self.network:setClientData( self.sv.bossState, 2 )
			end
			if trackPieceType == DrillbotTrackTypes.End then
				local cartStorageTag = self.sv.saved.cartArray[self.sv.saved.currentCartIdx-1].cartStorageTag
				local cartKinematic = self.sv.namedKinematics[cartStorageTag]
				local endTrackName = self.sv.saved.currentCartIdx == 4 and "down_transition" or "down_flip"

				sm.event.sendToHarvestable( cartKinematic, "sv_e_setActiveTracks", { tracksToActivate = { endTrackName }, transitionTime = 0.1 } )
				sm.event.sendToHarvestable( cartKinematic, "sv_e_activate", { tick = sm.game.getCurrentTick(), trackName = endTrackName } )
				sm.event.sendToHarvestable( cartKinematic, "sv_e_hideWagon" )

				self.sv.saved.cartArray[self.sv.saved.currentCartIdx-1] = false -- flipped cart is considered destroyed, it will destroy itself on flip completion
				local tsKinematics = TileStorageManager.Sv_GetValue( self.sv.tileStorageKey, DRILLBOT_KINEMATICS_TABLE )
				if tsKinematics and tsKinematics.carts then
					tsKinematics.carts[self.sv.saved.currentCartIdx-1] = nil -- removed from tilestorage, will not be reloaded.
					TileStorageManager.Sv_SetValue( self.sv.tileStorageKey, DRILLBOT_KINEMATICS_TABLE, tsKinematics )
					TileStorageManager.Sv_Save()
				end

				for actorName, tracks in pairs( DrillbotFightActorTracks ) do
					local nextTrackName = tracks[self.sv.saved.currentCartIdx] -- track idx has updated
					if nextTrackName then
						local currentTrackName = QuestActorManager.Sv_GetActorTrackName( actorName )
						if nextTrackName ~= currentTrackName then
							QuestActorManager.Sv_BeginActorTrack( nextTrackName, actorName )
						end
					end
				end

				self.sv.saved.fightCenter = self.sv.saved.fightCenter + NextWagonOffset -- next time bot appears it will be at the latest cart
			end
			if trackPieceType == DrillbotTrackTypes.Cinematic then
				-- request side cart for cinematic
				self:sv_e_requestSideCart( { side = "right", index = 13 } )
				-- Gyro-Core boss shortcut: no final mechanics-bot spawn/shooting wave.
				-- Keep the cinematic and exit-location loading intact.

				for _, name in pairs( DRILLBOT_FIGHT_ACTORS ) do
					QuestActorManager.Sv_NotifyActor( name, "notify.drillbot_exit" )
				end

				self.sv.saved.endCinematic = true
				saveAndSync = true
				-- start cinematic
				sm.game.pauseSaving( "DB Mountain", 40 * 60 * 1 );
				EffectManager.Sv_PlayNamedCinematic( { 
					name = ExitCinematicName, 
					callbackData = { world = self.scriptableObject:getWorld(), tileStorageKey = self.sv.tileStorageKey },
					interruptible = false
				 } )
				
				 --load exit location
				local locations = sm.storage.load( STORAGE_CHANNEL_LOCATIONS )
				if locations and locations["drillbotMountain"] then
					self.sv.exitLocation = locations["drillbotMountain"]
					local cellX = math.floor( self.sv.exitLocation.pos.x / 64 )
					local cellY = math.floor( self.sv.exitLocation.pos.y / 64 )
					-- load cell for host, until host arrives.
					self.sv.exitLocation.world:loadCell( cellX, cellY, sm.player.getHostPlayer(), "sv_exitLocationLoaded", nil, self )
				else
					sm.log.error( "Error: No location 'drillbotMountain' found in location storage" )
				end
			end
		end

		self.sv.saved.lastTrackPieceType = trackPieceType
		saveAndSync = true

		self.sv.lastInstanceId = instanceId
	end

	if self.sv.saved.trainFlipSignal or self.sv.saved.breakLockSignal then
		saveAndSync = true
	end
	self.sv.saved.breakLockSignal = false
	self.sv.saved.trainFlipSignal = false
	self.sv.endRollercoasterSignal = false -- not saved because only from test command

	if saveAndSync then
		sm.storage.save( STORAGE_CHANNEL_DRILLBOT_MANAGER, self.sv.saved )
		self.network:setClientData( self:sv_makeClientData(), 1 )
	end

	if self.sv.bossStateDirty then
		-- Should happen after sv_updateCombat
		self.sv.bossStateDirty = false
		self.network:setClientData( self.sv.bossState, 2 )
	end

	if self.sv.saved.playerList and not IsEmptyTable( self.sv.saved.playerList ) then
		local goneCount = 0
		for _, player in ipairs( self.sv.saved.playerList ) do
			if not sm.exists( player ) or not player:isActive() then
				-- Player disconnected during the fight; count as gone.
				goneCount = goneCount + 1
			else
				local character = player.character
				if character and character:isDowned() == true then
					if self.sv.saved.endCinematic then
						-- force revive all player after final stage
						sm.event.sendToPlayer( player, "sv_n_revive", { skipRevivalItem = true } )
					else
						goneCount = goneCount + 1
					end
				end
			end
		end

		-- when last stage is cleared, the finale will happen even if all players are dead. todo check if this is desired.
		if goneCount == #self.sv.saved.playerList then
			-- no connected players remain, reset fight
			self:sv_resetAndExit()
		end
	end

	if saveAndSync then
		sm.storage.save( STORAGE_CHANNEL_DRILLBOT_MANAGER, self.sv.saved )
		self.network:setClientData( self:sv_makeClientData(), 1 )
	end
end

function DrillbotManager.sv_exitLocationLoaded( self )
	local xMin, xMax, yMin, yMax = GetTileRanges( self.sv.exitLocation.pos, self.sv.exitLocation.world.id )
	--get DRILLBOT_EJECT nodes from the tiles
	local nodes = {}
	for x = xMin, xMax do
		for y = yMin, yMax do
			local cellNodes = sm.cell.getNodesByTag( x, y, "DRILLBOT_EJECT", self.sv.exitLocation.world )
			for _, node in ipairs( cellNodes ) do
				if isAnyOf( "DRILLBOT_EJECT", node.tags ) then
					node.world = self.sv.exitLocation.world
					nodes[#nodes + 1] = node
				end
			end
		end
	end
	self.sv.ejectNodes = nodes
end

function DrillbotManager.sv_resetAndExit( self )
	for _, player in ipairs( self.sv.saved.playerList ) do
		-- attempting to eject/respawn inactive players has the unfortunate side effect of activating them even if offline, quickfix just avoid it.
		if player:isActive() then
			sm.event.sendToPlayer( player, "sv_e_drillbotEject" )
		end
	end

	-- unregister actor tracks and actors from carts
	for _, cart in ipairs( self.sv.saved.cartArray ) do
		if cart and cart.actorTrackNames then
			for _, trackName in ipairs( cart.actorTrackNames ) do
				QuestEntityManager.Sv_UnregisterActorTrack( trackName )
			end
		end
		if cart and cart.actorNames then
			for _, actorName in ipairs( cart.actorNames ) do
				QuestActorManager.Sv_UnregisterActor( actorName )
			end
		end
	end
	for _, cartKey in ipairs( { "leftSideCart", "rightSideCart" } ) do
		local sideCart = self.sv.saved[cartKey]
		if sideCart and sideCart.actorTrackNames then
			for _, trackName in ipairs( sideCart.actorTrackNames ) do
				QuestEntityManager.Sv_UnregisterActorTrack( trackName )
			end
		end
		if sideCart and sideCart.actorNames then
			for _, actorName in ipairs( sideCart.actorNames ) do
				QuestActorManager.Sv_UnregisterActor( actorName )
			end
		end
	end
	for _, actorName in pairs( DRILLBOT_FIGHT_ACTORS ) do
		QuestActorManager.Sv_UnregisterActor( actorName )
	end

	-- clear all stored objects
	local world = self.scriptableObject:getWorld()
	local allBodies = sm.body.getAllBodies( world )
	for _, value in ipairs( allBodies ) do
		sm.body.destroyCreation( value )
	end
	local allHarvestables = sm.harvestable.getAllHarvestables( world )
	for _, value in ipairs( allHarvestables ) do
		sm.harvestable.destroy( value )
	end
	TileStorageManager.Sv_ClearTileStorage( self.sv.tileStorageKey )
	TileStorageManager.Sv_Save()

	local allUnits = sm.unit.getAllUnits( world )
	for _, unit in ipairs( allUnits ) do
		unit:destroy()
	end

	-- clear eventSpawn nodes
	self.sv.eventSpawnNodes = {}

	for _, unit in pairs( self.sv.mechanicsUnits ) do
		sm.unit.forceDestroy( unit )
	end
	self.sv.mechanicsUnits = {}
	self.sv.mechanicsNextShootTickByUnit = {}

	if self.sv.lowerUnit then
		if sm.exists( self.sv.lowerUnit ) then
			self.sv.lowerUnit:destroy()
		else
			sm.unit.forceDestroy( self.sv.lowerUnit )
		end
	end
	self.sv.lowerUnit = nil
	if self.sv.upperUnit then
		if sm.exists( self.sv.upperUnit ) then
			self.sv.upperUnit:destroy()
		else
			sm.unit.forceDestroy( self.sv.upperUnit )
		end
	end
	self.sv.upperUnit = nil

	-- reset manager and reinit
	sm.storage.save( STORAGE_CHANNEL_DRILLBOT_MANAGER, nil )
	self:sv_initData()
	self.sv.saved.activated = false

	sm.storage.save( STORAGE_CHANNEL_DRILLBOT_MANAGER, self.sv.saved )
	
	-- reset quest
	QuestManager.Sv_SendEvent( "event.quest_bosstrain.fail_bossfight" )
	
	-- fully clear client state, client data 1 and 2 will be set on next fight start.
	self.network:sendToClients( "cl_n_reset", true )
	self.network:setClientData( {}, 1 )
	self.network:setClientData( {}, 2 )
end

function DrillbotManager.sv_registerCartNodes( self, prefabNodes, cartPosition, world, cartData )
	cartData.actorTrackNames = {}
	cartData.actorTrackNodes = {}

	-- Register ACTORTRACK nodes first so tracks are available when quest actors spawn
	for _, node in ipairs( prefabNodes ) do
		if isAnyOf( "ACTORTRACK", node.tags ) then
			local tempNode = shallowcopy( node )
			tempNode.pos = tempNode.pos + cartPosition
			tempNode.position = tempNode.pos
			tempNode.rotation = tempNode.rot
			QuestEntityManager.Sv_RegisterActorTrackFromNode( tempNode, world )
			if tempNode.params and tempNode.params.name then
				cartData.actorTrackNames[#cartData.actorTrackNames+1] = tempNode.params.name
				cartData.actorTrackNodes[#cartData.actorTrackNodes+1] = tempNode
			end
		end
	end

	-- Spawn SPAWNABLE_UNIT nodes and track actor names
	for _, node in ipairs( prefabNodes ) do
		if isAnyOf( "SPAWNABLE_UNIT", node.tags ) then
			local tempNode = shallowcopy( node )
			tempNode.pos = tempNode.pos + cartPosition
			tempNode.position = tempNode.pos
			tempNode.rotation = tempNode.rot

			if node.params and node.params.eventName then
				self.sv.eventSpawnNodes[node.params.eventName] = self.sv.eventSpawnNodes[node.params.eventName] or {}
				self.sv.eventSpawnNodes[node.params.eventName][#self.sv.eventSpawnNodes[node.params.eventName]+1] = tempNode
			else
				sm.event.sendToWorld( world, "sv_e_spawnNodeUnit", { node = tempNode } )
			end
			local actorName = SafeNestedAccess( tempNode, "params", "questActorParams", "actorName" )
			if actorName and actorName ~= "" then
				cartData.actorNames = cartData.actorNames or {}
				cartData.actorNames[#cartData.actorNames+1] = actorName
			end
		end
	end
end

function DrillbotManager.sv_spawnCart( self, cartIndex )
	local prefab = self.sv.bosstrainWagonPrefabs[FightStageWagonPrefabs[cartIndex]]
	if not prefab then
		prefab = self.sv.bosstrainWagonPrefabs[1]
	end
	local rootName = "wagon"..cartIndex

	assert( prefab )
	assert( cartIndex > 0 )
	local cartPosition = ( NextWagonOffset * ( cartIndex - 1 ) )
	
	assert(self.sv.saved.cartArray[cartIndex] == nil or self.sv.saved.cartArray[cartIndex] == false )
	self.sv.saved.cartArray[cartIndex] = {
		breakLockCounter = BreakLockCount,
		cartStorageTag = nil,
		rampStorageTag = nil,
		hatch01StorageTag = nil,
		hatch02StorageTag = nil,
		camera = nil
	 }
	local cart = self.sv.saved.cartArray[cartIndex]

	local world = self.scriptableObject:getWorld()

	local tsKinematics = TileStorageManager.Sv_GetValue( self.sv.tileStorageKey, DRILLBOT_KINEMATICS_TABLE )
	tsKinematics = tsKinematics or {}
	tsKinematics.carts = tsKinematics.carts or {}
	tsKinematics.carts[cartIndex] = {}

	for kinematicIndex, prefabKinematic in ipairs( prefab.kinematics ) do
		local storageTag = "cart(" .. kinematicIndex .. "," .. cartIndex .. ")"
		if prefabKinematic.params.parentedKinematic then
			prefabKinematic.params.parentedKinematic.rootName = rootName
		end
		
		local createdKinematic = sm.harvestable.createHarvestable( prefabKinematic.uuid, cartPosition+prefabKinematic.pos, prefabKinematic.rot )
		if createdKinematic then
			local params = DeepCopy( prefabKinematic.params )
			params.storageTag = storageTag
			params.cartIndex = cartIndex
			if IsWagon( prefabKinematic.uuid ) then
				params.name = rootName
			end
			createdKinematic:setParams( params )
			
			tsKinematics.carts[cartIndex][storageTag] = {
				uuid = prefabKinematic.uuid,
				createdPos = cartPosition+prefabKinematic.pos,
				createdRot = prefabKinematic.rot,
				params = params
			}

			if IsWagon( prefabKinematic.uuid ) then
				cart.cartStorageTag = storageTag
			elseif prefabKinematic.uuid == WagonRamp then
				cart.rampStorageTag = storageTag
			elseif prefabKinematic.uuid == WagonHatch then
				if cart.hatch01StorageTag then
					cart.hatch02StorageTag = storageTag
				else
					cart.hatch01StorageTag = storageTag
				end
			end

			self.sv.namedKinematics[storageTag] = createdKinematic
		end
	end

	self:sv_registerCartNodes( prefab.nodes, cartPosition, world, cart )

	for _, node in ipairs( prefab.nodes ) do
		if isAnyOf( "CAMERA", node.tags ) then
			--  save the camera world position for this cart
			local tempNode = shallowcopy( node )
			tempNode.pos = tempNode.pos + cartPosition
			tempNode.position = tempNode.pos
			tempNode.rotation = tempNode.rot
	
			cart.camera = tempNode
		end
	end

	for _, value in ipairs( prefab.creations ) do
		-- removing "?JB:" prefix signifying it is a json blueprint and not a path.
		sm.creation.importFromString( world, string.sub( value.pathOrJson, 5, string.len( value.pathOrJson ) ), value.pos+cartPosition, value.rot )
	end

	TileStorageManager.Sv_SetValue( self.sv.tileStorageKey, DRILLBOT_KINEMATICS_TABLE, tsKinematics )
	TileStorageManager.Sv_Save()
end

function DrillbotManager.sv_requestSequenceFromPool( self, pool )
	if #pool > 0 then
		local sequence = pool[math.random(#pool)]
		self:sv_requestSequence( sequence )
	end
end

function DrillbotManager.sv_requestSequence( self, sequence )
	for index, request in ipairs( sequence ) do
		request.type = "piece"
		g_DrillbotWorld.Sv_QueueTrackRequest( request )
	end
end

function DrillbotManager.sv_requestLoopingState( self, state )
	g_DrillbotWorld.Sv_QueueTrackRequest( { type = "state", state = state } )
end

function DrillbotManager.sv_spawnMechanicsUnits( self )
	local eventNodes = self.sv.eventSpawnNodes["drillbot_fight.mechanics"]
	if not eventNodes then
		return
	end

	local spawnTick = sm.game.getCurrentTick()
	for _, tempNode in ipairs( eventNodes ) do
		for _, tag in ipairs( tempNode.tags ) do
			if tag ~= "SPAWNABLE_UNIT" then
				local createdUnit = CreateUnit( tag, tempNode, tempNode.params )
				if sm.exists( createdUnit ) then
					self.sv.mechanicsUnits[#self.sv.mechanicsUnits + 1] = createdUnit
					self.sv.mechanicsNextShootTickByUnit[createdUnit.id] = spawnTick + MechanicsPotatoShootInitialTickDelay + math.random( MechanicsPotatoShootCooldownTicks )
				end
				break
			end
		end
	end
end

function DrillbotManager.sv_spawnEventNodes( self, eventName, world )
	local eventNodes = self.sv.eventSpawnNodes[eventName]
	if not eventNodes then
		return
	end

	for _, tempNode in ipairs( eventNodes ) do
		sm.event.sendToWorld( world, "sv_e_spawnNodeUnit", { node = tempNode } )
	end
end

--[[ Manager ]]

function DrillbotManager.loadPrefabs( self )
	if not self.sv.bosstrainWagonPrefabs or not self.sv.sideCartPrefabs then
		local prefabs = sm.storage.load( STORAGE_CHANNEL_DRILLBOT_PREFABS )
		if prefabs then
			self.sv.bosstrainWagonPrefabs = prefabs.BosstrainPrefabs
			self.sv.sideCartPrefabs = prefabs.SideCartPrefabs
			return true
		end
		return false
	end
	return true
end

function DrillbotManager.sv_tryStartSpawn( self )
	assert( self.sv.saved.currentCartIdx == 0, "Current cart index should be 0 when trying to start the fight" )
	if self:loadPrefabs() then
		self.sv.saved.currentCartIdx = self.sv.saved.currentCartIdx + 1 -- first cart
		self:sv_spawnCart( self.sv.saved.currentCartIdx )
		self:sv_spawnCart( self.sv.saved.currentCartIdx + 1 )
		local world = self.scriptableObject:getWorld()
		for _, player in pairs( self.sv.saved.playerList ) do
			local character = player:getCharacter()
			if character and sm.exists( character ) then
				local spawnPointIndex = player.id % #PlayerSpawnPoints + 1
				local spawnPoint = PlayerSpawnPoints[spawnPointIndex]
				local newCharacter = sm.character.createCharacter( player, world, spawnPoint, PlayerSpawnYaw, PlayerSpawnPitch )
				player:setCharacter( newCharacter )
				sm.event.sendToPlayer( player, "sv_e_setBlockRespawn", true )
			end
		end
		-- Gyro-Core boss shortcut: do not spawn the opening enemy wave.
		-- Companion quest actors are spawned separately by sv_registerCartNodes.
		self.sv.saved.activated = true -- fight start success
		sm.event.sendToWorld( world, "sv_e_activate" )
		self.network:setClientData( self.sv.bossState, 2 )
	end
end

function DrillbotManager.Sv_StartFight( world, playerList )
	if g_drillbotManagerServerWorld and g_drillbotManagerServerWorld[world.id] then
		sm.event.sendToScriptableObject( g_drillbotManagerServerWorld[world.id].scriptableObject, "sv_e_startFight", playerList )
	end
end

-- entry point for starting the fight
function DrillbotManager.sv_e_startFight( self, playerList )
	self.sv.saved.playerList = playerList
	self:sv_tryStartSpawn()
	sm.storage.save( STORAGE_CHANNEL_DRILLBOT_MANAGER, self.sv.saved )
	self.network:setClientData( self:sv_makeClientData(), 1 )
end

function DrillbotManager.Sv_EndFight( world )
	if g_drillbotManagerServerWorld and g_drillbotManagerServerWorld[world.id] then
		sm.event.sendToScriptableObject( g_drillbotManagerServerWorld[world.id].scriptableObject, "sv_e_endFight" )
	end
end

function DrillbotManager.sv_e_endFight( self )
	print("DrillbotManager: Ending fight, moving players out of arena")

	local playersToMove = shallowcopy( self.sv.saved.playerList )

	-- collect players in the exit location tile if they are already there.
	local xMin, xMax, yMin, yMax = GetTileRanges( self.sv.exitLocation.pos, self.sv.exitLocation.world.id )
	local playersInOverworld = GetPlayersInWorld( self.sv.exitLocation.world )
	for _, player in ipairs( playersInOverworld ) do
		local character = player:getCharacter()
		if character and sm.exists( character ) then
			local pos = character:getWorldPosition()
			local cellX = math.floor( pos.x / 64 )
			local cellY = math.floor( pos.y / 64 )
			if cellX >= xMin and cellX <= xMax and cellY >= yMin and cellY <= yMax then
				table.insert( playersToMove, player )
			end
		end
	end
	
	-- use eject nodes to move players out of arena, else use the drillbotmountain location as fallback.
	if self.sv.ejectNodes and #self.sv.ejectNodes > 0 then
		local index = 1
		for _, player in ipairs( playersToMove ) do
			sm.event.sendToPlayer( player, "sv_e_setBlockRespawn", false )
			if player and player.character and sm.exists( player.character ) then
				local node = self.sv.ejectNodes[index]
				if node then
					local yaw = 0
					local spawnDirection = node.rotation * sm.vec3.new( 0, 0, 1 )
					yaw = math.atan2( spawnDirection.y, spawnDirection.x ) - math.pi/2
					local newCharacter = sm.character.createCharacter( player, node.world, node.position + sm.vec3.new( 0, 0, 1 ), yaw, 0 )
					player:setCharacter( newCharacter )
					index = index + 1
					if index > #self.sv.ejectNodes then
						index = 1
					end
				end
			end
		end
	else
		for _, player in ipairs( playersToMove ) do
			if player and player.character and sm.exists( player.character ) then
				sm.event.sendToPlayer( player, "sv_e_setBlockRespawn", false )
				if self.sv.exitLocation and self.sv.exitLocation.world and self.sv.exitLocation.pos then
					local newCharacter = sm.character.createCharacter( player, self.sv.exitLocation.world, self.sv.exitLocation.pos, 0, 0 )
					player:setCharacter( newCharacter )					
				end
			end
		end
	end

	--shutdown of the fight
	self.sv.saved.playerList = {}
	self.sv.saved.outOfArenaPlayers = {}
	self.sv.saved.activated = false
	sm.event.sendToWorld( self.scriptableObject:getWorld(), "sv_e_deactivate" )
	self.sv.showDrillbot = false
	self.sv.loadDummy:release()
	self.sv.loadDummy = nil
	self.sv.saved.finishedFight = true
	sm.storage.save( STORAGE_CHANNEL_DRILLBOT_MANAGER, self.sv.saved )

	EffectManager.Sv_PlayNamedCinematic( {
		name = OutsideCinematicName,
		callbackData = { world = self.sv.exitLocation.world, tileStorageKey = TileStorageManager.Sv_GetTileStorageKeyFromPosition( self.sv.exitLocation.world, self.sv.exitLocation.pos ) },
		interruptible = false
	} )
end

function DrillbotManager.Sv_WorldReady( world )
	if g_drillbotManagerServerWorld and g_drillbotManagerServerWorld[world.id] then
		sm.event.sendToScriptableObject( g_drillbotManagerServerWorld[world.id].scriptableObject, "sv_e_worldReady" )
	end
end

function DrillbotManager.sv_e_worldReady( self )
	if not IsEmptyTable( self.sv.saved.playerList ) and not self.sv.saved.activated then
		-- currently waiting to start fight
		self:sv_tryStartSpawn()
		sm.storage.save( STORAGE_CHANNEL_DRILLBOT_MANAGER, self.sv.saved )
		self.network:setClientData( self:sv_makeClientData(), 1 )
	else
		-- not currently waiting to start fight, but prefabs should be loaded now, ready for fight start.
		self:loadPrefabs()
	end

	-- re-register actor tracks from saved cart data after reload
	if self.sv.saved.activated then
		local world = self.scriptableObject:getWorld()
		for _, cart in ipairs( self.sv.saved.cartArray ) do
			if cart and cart.actorTrackNodes then
				for _, trackNode in ipairs( cart.actorTrackNodes ) do
					QuestEntityManager.Sv_RegisterActorTrackFromNode( trackNode, world )
				end
			end
		end
		for _, cartKey in ipairs( { "leftSideCart", "rightSideCart" } ) do
			local sideCart = self.sv.saved[cartKey]
			if sideCart and sideCart.actorTrackNodes then
				for _, trackNode in ipairs( sideCart.actorTrackNodes ) do
					QuestEntityManager.Sv_RegisterActorTrackFromNode( trackNode, world )
				end
			end
		end
	end
end

function DrillbotManager.Cl_WorldReady( world )
	if g_drillbotManagerClientWorld and g_drillbotManagerClientWorld[world.id] then
		g_drillbotManagerClientWorld[world.id]:cl_worldReady()
	end
end

function DrillbotManager.cl_worldReady( self )
	--if manager was created before terrain finish, prefabs will be loaded here
	if not self.cl.bosstrainWagonPrefabs then
		local prefabs = sm.storage.load( STORAGE_CHANNEL_DRILLBOT_PREFABS )
		if prefabs then
			self.cl.bosstrainWagonPrefabs = prefabs.BosstrainPrefabs
		end
	end

	-- if the manager knows about the kinematics, we now have the prefabs, and so we can create cart effects.
	-- if kinematics are not known, wait until client data update, then we will have everything needed to consume queue.
	for index, cart in ipairs( self.cl.cartArray ) do
		if cart and cart.cartStorageTag then
			if self.cl.queuedCartEffectCreation[cart.cartStorageTag] then
				self:cl_createCartEffectsAndTriggersAtIndex( index )
				self.cl.queuedCartEffectCreation[cart.cartStorageTag] = nil
			end
		end
	end
end


































function DrillbotManager.sv_e_requestTestSequence( self )
	self:sv_requestSequence( TestSequence )
end

function DrillbotManager.sv_e_breakWagonLocksTest( self )
	self.sv.saved.breakLockSignal = true
end

function DrillbotManager.sv_e_trainFlipTest( self )
	self.sv.saved.trainFlipSignal = true
end

function DrillbotManager.sv_e_endRollercoaster( self )
	self.sv.endRollercoasterSignal = true
end

function DrillbotManager.sv_e_requestRunState( self, state )
	self.sv.requestRunState = state
end

function DrillbotManager.sv_e_exitCinematic( self )
	-- The exit cinematic plays an effect node baked into the final wagon prefab. 
	-- Force-spawn the final wagon if it isn't already present before requesting the sequence as normal.
	local finalCartIndex = FightStageCount + 1
	if self.sv.saved.cartArray[finalCartIndex] == nil or self.sv.saved.cartArray[finalCartIndex] == false then
		self:sv_spawnCart( finalCartIndex )
		sm.storage.save( STORAGE_CHANNEL_DRILLBOT_MANAGER, self.sv.saved )
		self.network:setClientData( self:sv_makeClientData(), 1 )
	end
	self:sv_requestSequence( EndCinematicSequence )
end

function DrillbotManager.Sv_LockDestroyed( world, params )
	if g_drillbotManagerServerWorld[world.id] then
		g_drillbotManagerServerWorld[world.id]:sv_lockDestroyed( params )
	end
end

function DrillbotManager.sv_lockDestroyed( self, params )
	local tsKinematics = TileStorageManager.Sv_GetValue( self.sv.tileStorageKey, DRILLBOT_KINEMATICS_TABLE )
	if not tsKinematics then
		return
	end
	
	tsKinematics.carts[params.cartIndex][params.storageTag] = nil

	TileStorageManager.Sv_SetValue( self.sv.tileStorageKey, DRILLBOT_KINEMATICS_TABLE, tsKinematics )
	TileStorageManager.Sv_Save()

	if self.sv.saved.cartArray[params.cartIndex] and self.sv.saved.cartArray[params.cartIndex].breakLockCounter then
		if self.sv.saved.cartArray[params.cartIndex].breakLockCounter > 0 then
			self.sv.saved.cartArray[params.cartIndex].breakLockCounter = self.sv.saved.cartArray[params.cartIndex].breakLockCounter - 1
			if self.sv.saved.cartArray[params.cartIndex].breakLockCounter == 0 then
				self.sv.saved.breakLockSignal = true
			end
		end
	end

	sm.storage.save( STORAGE_CHANNEL_DRILLBOT_MANAGER, self.sv.saved )	
end


function DrillbotManager.sv_e_requestSideCart( self, params )
	self:sv_spawnSideCart( params.side, params.index )
	sm.storage.save( STORAGE_CHANNEL_DRILLBOT_MANAGER, self.sv.saved )
	self.network:setClientData( self:sv_makeClientData(), 1 )
end

function DrillbotManager.sv_spawnSideCart( self, side, index )
	local prefab = self.sv.sideCartPrefabs[index][side]
	local cartPosition = ( NextWagonOffset * ( self.sv.saved.currentCartIdx - 1 ) )

	if not self.sv.sideCartPrefabs[index] then
		print( "No sidecart prefab found at index", index )
		return
	end

	if not self.sv.sideCartPrefabs[index][side] then
		print( "No sidecart prefab found for", side, "side at index", index )
		return
	end

	local cartKey
	if side == "left" then
		cartKey = "leftSideCart"
	else
		cartKey = "rightSideCart"
	end

	self.sv.saved[cartKey] = self.sv.saved[cartKey] or {}
	local sideCart = self.sv.saved[cartKey]

	if sideCart.rootStorageTag == nil or sm.exists( self.sv.namedKinematics[sideCart.rootStorageTag] ) == false then
		local tsKinematics = TileStorageManager.Sv_GetValue( self.sv.tileStorageKey, DRILLBOT_KINEMATICS_TABLE )
		tsKinematics = tsKinematics or {}
		tsKinematics[cartKey] = tsKinematics[cartKey] or {}

		for kinematicIndex, prefabKinematic in ipairs( prefab.kinematics ) do
			local createdKinematic = sm.harvestable.createHarvestable( prefabKinematic.uuid, cartPosition+prefabKinematic.pos, prefabKinematic.rot )
			if createdKinematic then
				local params = DeepCopy( prefabKinematic.params )
				params.storageTag = cartKey..kinematicIndex

				-- clear KINEMATIC_STORAGE_TABLE of any stale state for the storage tag we are about to reuse.
				TileStorageManager.Sv_SetValueInSubTable( self.sv.tileStorageKey, KINEMATIC_STORAGE_TABLE, params.storageTag, nil )

				createdKinematic:setParams( params )
				
				tsKinematics[cartKey][params.storageTag] = {
					uuid = prefabKinematic.uuid,
					createdPos = cartPosition+prefabKinematic.pos,
					createdRot = prefabKinematic.rot,
					params = params
				}


				if isAnyOf( prefabKinematic.uuid, SideCartRoots) then
					self.sv.saved[cartKey].rootStorageTag = params.storageTag
				end

				self.sv.namedKinematics[params.storageTag] = createdKinematic
			end
		end
		
		local world = sm.world.getCurrentWorld()
		self:sv_registerCartNodes( prefab.nodes, cartPosition, world, sideCart )
		
		for _, value in ipairs( prefab.creations ) do
			-- removing "?JB:"" prefix signifying it is a json blueprint and not a path.
			sm.creation.importFromString( world, string.sub( value.pathOrJson, 5, string.len( value.pathOrJson ) ), value.pos+cartPosition, value.rot )
		end

		TileStorageManager.Sv_SetValue( self.sv.tileStorageKey, DRILLBOT_KINEMATICS_TABLE, tsKinematics )
		TileStorageManager.Sv_Save()
	end
end

function DrillbotManager.Sv_GetFaceHits()
	if g_drillbotManagerServerWorld then
		local world = sm.world.getCurrentWorld()
		if sm.exists( world ) then
			if g_drillbotManagerServerWorld[world.id] then
				return g_drillbotManagerServerWorld[world.id]:sv_getFaceHits()
			end
		end
	end
	return 0
end

function DrillbotManager.sv_getFaceHits( self )
	return self.sv.bossState.faceHits
end

function DrillbotManager.Sv_HitFace( meleeAttack, hitPosition, hitRotation )
	if g_drillbotManagerServerWorld then
		local world = sm.world.getCurrentWorld()
		if sm.exists( world ) then
			if g_drillbotManagerServerWorld[world.id] then
				g_drillbotManagerServerWorld[world.id]:sv_hitFace( meleeAttack, hitPosition, hitRotation )
			end
		end
	end
end

function DrillbotManager.sv_hitFace( self, meleeAttack, hitPosition, hitRotation )
	local hurtEye = false
	if meleeAttack then
		local world = self.scriptableObject:getWorld()
		local trackPieceType = ( world.publicData and world.publicData.piece ) and world.publicData.piece.pieceType or nil
		if trackPieceType == DrillbotTrackTypes.Down then
			if self.sv.bossState.faceHits < DRILLBOT_FACE_HITS then
				self.sv.bossState.faceHits = math.min( self.sv.bossState.faceHits + 1, DRILLBOT_FACE_HITS )
				self.sv.bossStateDirty = true
				hurtEye = true
				if self.sv.bossState.faceHits >= DRILLBOT_FACE_HITS then
					self.sv.saved.trainFlipSignal = true
					sm.storage.save( STORAGE_CHANNEL_DRILLBOT_MANAGER, self.sv.saved )
				end
			end
		end
	end

	--Play hit effect
	if hitPosition then
		local hitEffectName = hurtEye and "Drillbot - eye_destruct" or "Drillbot - empty"
		sm.effect.playEffect( hitEffectName, hitPosition, nil, hitRotation )
	end
end

function DrillbotManager.Sv_RequestStopAttack()
	if g_drillbotManagerServerWorld then
		local world = sm.world.getCurrentWorld()
		if sm.exists( world ) then
			if g_drillbotManagerServerWorld[world.id] then
				g_drillbotManagerServerWorld[world.id]:sv_requestStopAttack()
			end
		end
	end
end

function DrillbotManager.sv_requestStopAttack( self )
	self.sv.requestStopAttack = true
end

function DrillbotManager.Sv_GetBossState()
	if g_drillbotManagerServerWorld then
		local world = sm.world.getCurrentWorld()
		if sm.exists( world ) then
			if g_drillbotManagerServerWorld[world.id] then
				return g_drillbotManagerServerWorld[world.id]:sv_getBossState()
			end
		end
	end
	return nil
end

function DrillbotManager.sv_getBossState( self )
	return self.sv.bossState
end

function DrillbotManager.Sv_SetTargetPlayer( player )
	if g_drillbotManagerServerWorld then
		local world = sm.world.getCurrentWorld()
		if sm.exists( world ) then
			if g_drillbotManagerServerWorld[world.id] then
				g_drillbotManagerServerWorld[world.id]:sv_setTargetPlayer( player )
			end
		end
	end
end

function DrillbotManager.sv_setTargetPlayer( self, player )
	self.sv.bossStateDirty = self.sv.bossState.targetPlayer ~= player or self.sv.bossStateDirty
	self.sv.bossState.targetPlayer = player
end

--[[ Client ]]

function DrillbotManager.cl_init( self )
	self.cl = {}
	self.cl.bossState = {
		faceHits = 0,
		attackStateRevision = 0,
	}
	self.cl.lowerCharacter = nil
	self.cl.upperCharacter = nil

	self.cl.fightCenter = sm.vec3.zero()

	self.cl.sphereJointEffects = {}

	self.cl.initReceived = false

	self.cl.currentCartIdx = 0
	self.cl.cartArray = { false, false, false, false }
	self.cl.queuedCartEffectCreation = {}

	-- if client terrain script finishes before manager create, load prefabs here
	local prefabs = sm.storage.load( STORAGE_CHANNEL_DRILLBOT_PREFABS )
	if prefabs then
		self.cl.bosstrainWagonPrefabs = prefabs.BosstrainPrefabs
	end

	self.scriptableObject.clientPublicData = {}
	self.cl.lastPieceType = nil
	self.cl.namedKinematics = {}
end

function DrillbotManager.client_onCreate( self )
	local worldId = self.scriptableObject:getWorld().id
	g_drillbotManagerClientWorld = g_drillbotManagerClientWorld or {}
	g_drillbotManagerClientWorld[worldId] = self
	
	self:cl_init()
end

function DrillbotManager.cl_n_reset( self )
	self:cl_init()
end

function DrillbotManager.client_onClientDataUpdate( self, clientData, channel )
	if IsEmptyTable( clientData ) then
		return
	end

	if channel == 1 then
		self.cl.outOfArena = false
		if clientData.outOfArenaPlayers then
			local localPlayer = sm.localPlayer.getPlayer()
			local localPlayerId = localPlayer:getId()
			for id, value in pairs( clientData.outOfArenaPlayers ) do
				if id == localPlayerId then
					self.cl.outOfArena = true
					break
				end
			end
		end

		self.cl.currentCartIdx = clientData.currentCartIdx

		if clientData.cartArray and clientData.cartArray[self.cl.currentCartIdx] then
			-- when the last stage is cleared. any player out of the arena will be instantly placed back in the final cart.
			-- this means they don't need a spectate camera.
			if self.cl.currentCartIdx > FightStageCount then
				self.cl.spectate = nil
			else
				local spectate = clientData.cartArray[self.cl.currentCartIdx].camera
				if spectate then
					
					if self.cl.spectate == nil or ( self.cl.spectate.position ~= spectate.position or self.cl.spectate.rotation ~= spectate.rotation ) then
						self.cl.spectate = spectate
						local player = sm.localPlayer.getPlayer()
						local character = player.character
						if character and character:isDowned() and self.cl.outOfArena then
							--if dead, begin interpolation from current camera pos to new spectate pos
							self.cl.cameraBeginPos = sm.camera.getPosition()
							self.cl.cameraBeginRot = sm.camera.getRotation()
							self.cl.cameraMove = 0
							sm.gui.startFadeToBlack( 0.5, 4 )
						end
					end
				end
			end
		end

		for index, cart in ipairs( clientData.cartArray ) do
			if cart then
				if not self.cl.cartArray[index] then
					self.cl.cartArray[index] = {
						cartStorageTag = cart.cartStorageTag,
						scytheTriggers = nil
					}
					
					if self.cl.bosstrainWagonPrefabs then
						if self.cl.queuedCartEffectCreation[cart.cartStorageTag] then
							-- the kinematic exists and was created before this client data update, create the effects for it.
							self:cl_createCartEffectsAndTriggersAtIndex( index )
							self.cl.queuedCartEffectCreation[cart.cartStorageTag] = nil
						else
							-- the kinematic has not been created yet, but it will be, when it is registered it will have effects set up in cl_registerCreatedCart
						end
					else
						-- must wait until terrain completes to consume queued cart creates
					end
				end
			end
		end
		if not self.cl.initReceived then
			self.cl.fightCenter = clientData.fightCenter -- instantly set the center position on init
			if self.scriptableObject.clientPublicData == nil then
				self.scriptableObject.clientPublicData = {}
			end
			self.scriptableObject.clientPublicData.bossfightCenter = self.cl.fightCenter

			self.cl.runningState = clientData.runningState
		else
			self.cl.newFightCenter = clientData.fightCenter -- will interpolate the center position
			self.cl.lerpCenterTimer = 0
			self.cl.oldFightCenter = self.cl.fightCenter

			
			if not self.cl.pendingRunningStateTransition then
				self.cl.pendingRunningStateTransition = clientData.pendingRunningStateTransition
			end
		end

		self.cl.initReceived = true
	elseif channel == 2 then
		self.cl.bossState = clientData
	end
end

function DrillbotManager.Sv_RegisterKinematic( world, kinematic, params )
	if g_drillbotManagerServerWorld and g_drillbotManagerServerWorld[world.id] then
		g_drillbotManagerServerWorld[world.id]:sv_registerKinematic( kinematic, params )
	end
end


function DrillbotManager.sv_registerKinematic( self, kinematic, params )
	self.sv.namedKinematics = self.sv.namedKinematics or {}
	self.sv.namedKinematics[params.storageTag] = kinematic
end

function DrillbotManager.Cl_RegisterCreatedCart( world, cartKinematic, storageTag )
	if g_drillbotManagerClientWorld and g_drillbotManagerClientWorld[world.id] then
		g_drillbotManagerClientWorld[world.id]:cl_registerCreatedCart( cartKinematic, storageTag )
	end
end

function DrillbotManager.cl_registerCreatedCart( self, cartKinematic, storageTag )
	--register
	self.cl.namedKinematics[storageTag] = cartKinematic

	--attempt to create effects for the cart
	for index, cart in ipairs( self.cl.cartArray ) do
		if cart and cart.cartStorageTag == storageTag then
			if self.cl.bosstrainWagonPrefabs then
				-- drillbot manager knows about the cart and has the prefabs, create effects immediately
				self:cl_createCartEffectsAndTriggersAtIndex( index )
			else
				-- drillbot manager does not have the prefab yet, wait until terrain completes
				self.cl.queuedCartEffectCreation[storageTag] = true
			end
		else
			-- drillbot manager does not know the kinematic yet, wait until client data is set
			self.cl.queuedCartEffectCreation[storageTag] = true
		end
	end
end

function DrillbotManager.cl_createCartEffectsAndTriggersAtIndex( self, cartIndex )
	local cart = self.cl.cartArray[cartIndex]
	if not cart then
		return
	end

	local prefab = self.cl.bosstrainWagonPrefabs[FightStageWagonPrefabs[cartIndex]]
	if not prefab then
		print( "failed to create cart effects/triggers, no prefab found for cart at index:", cartIndex )
		return
	end

	local cartPosition = ( NextWagonOffset * ( cartIndex - 1 ) )

	local cartKinematic = self.cl.namedKinematics[cart.cartStorageTag]
	print( "Creating effects and triggers for cart at index:", cartIndex )
	if cartKinematic and sm.exists( cartKinematic ) then
		if ( cart.scytheTriggers == nil or IsEmptyTable( cart.scytheTriggers ) ) then
			-- if this cart doesn't have trigger yet, make them.
			cart.scytheTriggers = {}
		end

		local effect = sm.effect.createEffect( "Drillbot - Countdown01", cartKinematic )
		if not self.cl.countDownEffects then
			self.cl.countDownEffects = {}
		end
		self.cl.countDownEffects[cartIndex] = effect

		if cartKinematic.uuid == sm.uuid.new( "d8b50b83-3b46-4a37-a6b2-3f689524572b" ) then
			if not self.cl.ballTubeEffects then
				self.cl.ballTubeEffects = {}
			end
			if not self.cl.ballTubeEffects[cartIndex] then
				self.cl.ballTubeEffects[cartIndex] = sm.effect.createEffect( "Drillbot - Farmerballs01", cartKinematic )
				self.cl.ballTubeEffects[cartIndex]:setAutoPlay( true )
			end
		end

		local inverseRot = sm.quat.inverse( cartKinematic.initialRotation )

		for _, node in ipairs( prefab.nodes ) do
			if isAnyOf( "EFFECT", node.tags ) then
				if node.params.name == ExitCinematicName then
					-- don't attach cinematic to cart, it will be placed in world and then passed to effectmanager as named cinematic
					-- position the node in tile space
					node.pos = cartPosition + node.pos
					node.position = node.pos
					node.rotation = node.rot
					node.params.effect.autoPlay = false
					
					local cellX = math.floor( node.pos.x / 64 )
					local cellY = math.floor( node.pos.y / 64 )
					EffectManager.Cl_HandleNodesManual( self.scriptableObject:getWorld(), cellX, cellY, { node } )
				else
					-- first transform the node into world space
					local effect = sm.effect.createEffect( node.params.effect.name, cartKinematic )

					local worldPos = cartPosition + node.pos
					effect:setOffsetPosition( inverseRot * ( worldPos - cartKinematic.initialPosition ) )
					effect:setOffsetRotation( inverseRot * node.rot )
					effect:setScale( node.scale )

					if node.params.effect.params then
						for k,v in kvpairs( node.params.effect.params ) do
							effect:setParameter(k, v)
						end
					end
					if node.params.effect.autoPlay == nil or node.params.effect.autoPlay == true then
						effect:setAutoPlay( true )
					end
					if node.params.effect.name == "Bosstrain - Ballburst01" then
						if not self.cl.ballBurstEffects then
							self.cl.ballBurstEffects = {}
						end
						if not self.cl.ballBurstEffects[cartIndex] then
							self.cl.ballBurstEffects[cartIndex] = {}
						end
						table.insert( self.cl.ballBurstEffects[cartIndex], effect )
					elseif node.params.effect.name == "Drillbot - Sliced_wagon" then
						effect:setAutoPlay( false )
						if not self.cl.wagonSlicedEffects then
							self.cl.wagonSlicedEffects = {}
						end
						if not self.cl.wagonSlicedEffects[cartIndex] then
							self.cl.wagonSlicedEffects[cartIndex] = {}
						end
						table.insert( self.cl.wagonSlicedEffects[cartIndex], effect )
					else
						if not self.cl.effects then
							self.cl.effects = {}
						end
						self.cl.effects[#self.cl.effects+1] = effect -- keeping effects here in order to avoid garbage collection.
					end
				end
			end

			if isAnyOf( "VOLUME", node.tags ) and string.sub( node.params.name, 1, 10 ) == "ScytheArea" then
				local inverseRot = sm.quat.inverse( cartKinematic.initialRotation )
				local worldPos = cartPosition + node.pos
				local offsetPosition = inverseRot * ( worldPos - cartKinematic.initialPosition )
				local offsetRotation = inverseRot * node.rot
				local areaTrigger = sm.areaTrigger.createAttachedBox( cartKinematic, node.scale/2, offsetPosition, offsetRotation, sm.areaTrigger.filter.character )
				areaTrigger:setCharacterDetection( true )
				local number = tonumber( string.sub( node.params.name, 11, 11) )
				assert( number, "failed to get scythe area index from name" )
				cart.scytheTriggers[number] = areaTrigger
			end
		end
	end
end

function DrillbotManager.cl_n_startCountDown( self, cartIndex )
	if self.cl.countDownEffects then
		if sm.exists( self.cl.countDownEffects[cartIndex] ) then
			self.cl.countDownEffects[cartIndex]:start()
		end
	end
end

function DrillbotManager.cl_n_startBallBurstEffects( self, cartIndex )
	if self.cl.ballBurstEffects then
		if self.cl.ballBurstEffects[cartIndex] then
			removeFromArray( self.cl.ballBurstEffects[cartIndex], function( effect ) return not sm.exists(effect) end )
			for key, value in pairs( self.cl.ballBurstEffects[cartIndex] ) do
				value:start()
			end
		end
	end

	if self.cl.ballTubeEffects then
		if self.cl.ballTubeEffects[cartIndex] then
			self.cl.animateBallTubes = cartIndex
			self.cl.ballTubeOffset = 0
		end
	end
end

function DrillbotManager.cl_n_startWagonSlicedEffects( self, cartIndex )
	if self.cl.wagonSlicedEffects then
		if self.cl.wagonSlicedEffects[cartIndex] then
			removeFromArray( self.cl.wagonSlicedEffects[cartIndex], function( effect ) return not sm.exists(effect) end )
			for key, value in pairs( self.cl.wagonSlicedEffects[cartIndex] ) do
				value:start()
			end
		end
	end
end

function DrillbotManager.client_onUpdate( self, deltaTime )

	-- Custom camera
	if self.cl.spectate then
		local player = sm.localPlayer.getPlayer()
		local character = player.character
		if character and character:isDowned() and self.cl.outOfArena then
			-- when dead, interpolate camera to spectate position
			if self.cl.cameraBeginPos == nil then
				self.cl.cameraBeginPos = sm.camera.getPosition()
				self.cl.cameraBeginRot = sm.camera.getRotation()
				self.cl.cameraMove = 0
				sm.gui.startFadeToBlack( 0.5, 4 )
			end
			
			self.cl.cameraMove = math.min( self.cl.cameraMove + deltaTime * 1, 1 )

			local customCameraData
			customCameraData = {}
			customCameraData.hideGui = false
			customCameraData.cameraFov = 78
			if self.cl.cameraMove == 1 then
				customCameraData.cameraPosition = self.cl.spectate.position
				customCameraData.cameraRotation = self.cl.spectate.rotation
				sm.gui.endFadeToBlack( 0.5 )
			else
				customCameraData.cameraPosition = sm.vec3.lerp( self.cl.cameraBeginPos, self.cl.spectate.position, self.cl.cameraMove )
				customCameraData.cameraRotation = self.cl.cameraBeginRot
			end
			customCameraData.cameraState = sm.camera.state.cutsceneTP

			customCameraData.lockedControls = false

			player.clientPublicData = player.clientPublicData or {}
			player.clientPublicData.customCameraData = customCameraData
		else
			player.clientPublicData = player.clientPublicData or {}
			player.clientPublicData.customCameraData = nil

			self.cl.cameraBeginPos = nil
			self.cl.cameraBeginRot = nil
		end
	end

	if self.cl.animateBallTubes then
		self.cl.ballTubeOffset = self.cl.ballTubeOffset + TubeEffectEjectSpeed * deltaTime
		if self.cl.ballTubeOffset >= TubeEffectEjectDistance then
			self.cl.ballTubeEffects[self.cl.animateBallTubes]:destroy()
			self.cl.ballTubeEffects[self.cl.animateBallTubes] = nil
			self.cl.animateBallTubes = nil
			self.cl.ballTubeOffset = 0
		else
			self.cl.ballTubeEffects[self.cl.animateBallTubes]:setOffsetPosition( sm.vec3.new( 0 , 0, -self.cl.ballTubeOffset ) )
		end
	end
	
	if self.cl.newFightCenter ~= nil then
		if self.cl.lerpCenterTimer < MoveCenterDuration then
			self.cl.lerpCenterTimer = min( self.cl.lerpCenterTimer + deltaTime, MoveCenterDuration )

			local p = self.cl.lerpCenterTimer / MoveCenterDuration
			self.cl.fightCenter = sm.vec3.lerp( self.cl.oldFightCenter, self.cl.newFightCenter, p )

			self.scriptableObject.clientPublicData.bossfightCenter = self.cl.fightCenter

			if p == 1 then
				self.cl.newFightCenter = nil
			end
		end
	end

	self.cl.lowerCharacter = sm.exists( self.cl.lowerCharacter ) and self.cl.lowerCharacter or nil
	self.cl.upperCharacter = sm.exists( self.cl.upperCharacter ) and self.cl.upperCharacter or nil

	if self.cl.upperCharacter and self.cl.lowerCharacter and self.cl.upperCharacter:hasGraphics() and self.cl.lowerCharacter:hasGraphics() then
		DrillbotManager.Cl_UpdateSphereJointEffects( self.cl.upperCharacter, self.cl.lowerCharacter, self.cl.sphereJointEffects )		
	end
end

--[[ Manager ]]
function DrillbotManager.Cl_RegisterLowerCharacter( character )
	if g_drillbotManagerClientWorld then
		local world = sm.world.getCurrentWorld()
		if sm.exists( world ) then
			if g_drillbotManagerClientWorld[world.id] then
				g_drillbotManagerClientWorld[world.id]:cl_registerLowerCharacter( character )
			end
		end
	end
end

function DrillbotManager.cl_registerLowerCharacter( self, character )
	self.cl.lowerCharacter = character
end

function DrillbotManager.Cl_RegisterUpperCharacter( character )
	if g_drillbotManagerClientWorld then
		local world = sm.world.getCurrentWorld()
		if sm.exists( world ) then
			if g_drillbotManagerClientWorld[world.id] then
				g_drillbotManagerClientWorld[world.id]:cl_registerUpperCharacter( character )
			end
		end
	end
end

function DrillbotManager.cl_registerUpperCharacter( self, character )
	self.cl.upperCharacter = character
end

function DrillbotManager.Cl_GetUpperCharacter()
	if g_drillbotManagerClientWorld then
		local world = sm.world.getCurrentWorld()
		if sm.exists( world ) then
			if g_drillbotManagerClientWorld[world.id] then
				return g_drillbotManagerClientWorld[world.id]:cl_getUpperCharacter()
			end
		end
	end
	return nil
end

function DrillbotManager.cl_getUpperCharacter( self )
	return self.cl.upperCharacter
end

function DrillbotManager.Cl_GetTrackData()
	if g_drillbotManagerClientWorld then
		local world = sm.world.getCurrentWorld()
		if sm.exists( world ) then
			if g_drillbotManagerClientWorld[world.id] then
				return g_drillbotManagerClientWorld[world.id]:cl_getTrackData()
			end
		end
	end
	return nil
end

function DrillbotManager.cl_getTrackData( self )
	local world = self.scriptableObject:getWorld()
	local trackPiece = world.clientPublicData and world.clientPublicData.currentPiece or nil
	local trackProgress = world.clientPublicData and world.clientPublicData.currentTrackPieceProgression or nil
	local instanceId = world.clientPublicData and world.clientPublicData.instanceId or nil

	if trackPiece and trackProgress then
		local trackData = {}
		if self.cl.lastPieceType ~= trackPiece.pieceType then
			sm.audio.setGlobalParameter("combat", trackPiece.pieceType == DrillbotTrackTypes.Combat and 1 or 0)
			self.cl.lastPieceType = trackPiece.pieceType
		end
		
		local legsAnimation = nil
		local bodyAnimation = nil
		if self.cl.pendingRunningStateTransition and instanceId > self.cl.pendingRunningStateTransition.instanceId then
			-- transition done
			self.cl.runningState = self.cl.pendingRunningStateTransition.state
			self.cl.pendingRunningStateTransition = nil
			
			legsAnimation = trackPiece.legsAnimation[self.cl.runningState]
		elseif self.cl.pendingRunningStateTransition and instanceId == self.cl.pendingRunningStateTransition.instanceId then
			-- mid transition
			if self.cl.runningState == "left" and self.cl.pendingRunningStateTransition.state == "center" then
				legsAnimation = trackPiece.legsAnimation.leftOut
				bodyAnimation = trackPiece.bodyAnimation.leftOut
			elseif self.cl.runningState == "right" and self.cl.pendingRunningStateTransition.state == "center" then
				legsAnimation = trackPiece.legsAnimation.rightOut
				bodyAnimation = trackPiece.bodyAnimation.rightOut
			elseif self.cl.runningState == "center" then
				if self.cl.pendingRunningStateTransition.state == "right" then
					legsAnimation = trackPiece.legsAnimation.rightIn
					bodyAnimation = trackPiece.bodyAnimation.rightIn
				elseif self.cl.pendingRunningStateTransition.state == "left" then
					legsAnimation = trackPiece.legsAnimation.leftIn
					bodyAnimation = trackPiece.bodyAnimation.leftIn
				end
			end
		else
			legsAnimation = trackPiece.legsAnimation[self.cl.runningState or "center"]
			bodyAnimation = trackPiece.bodyAnimation[self.cl.runningState or "center"]
		end

		-- fallback to center
		if not legsAnimation then
			legsAnimation = trackPiece.legsAnimation.center
		end
		if not bodyAnimation then
			bodyAnimation = trackPiece.bodyAnimation.center
		end
		
		trackData.bodyAnimationName = bodyAnimation
		trackData.legsAnimationName = legsAnimation
		trackData.trackProgress = trackProgress
		return trackData
	end
	return nil
end

function DrillbotManager.Cl_GetFaceHits()
	if g_drillbotManagerClientWorld then
		local world = sm.world.getCurrentWorld()
		if sm.exists( world ) then
			if g_drillbotManagerClientWorld[world.id] then
				return g_drillbotManagerClientWorld[world.id]:cl_getFaceHits()
			end
		end
	end
	return 0
end

function DrillbotManager.cl_getFaceHits( self )
	return self.cl.bossState.faceHits
end

function DrillbotManager.Cl_GetBossState()
	if g_drillbotManagerClientWorld then
		local world = sm.world.getCurrentWorld()
		if sm.exists( world ) then
			if g_drillbotManagerClientWorld[world.id] then
				return g_drillbotManagerClientWorld[world.id]:cl_getBossState()
			end
		end
	end
	return nil
end

function DrillbotManager.cl_getBossState( self )
	return self.cl.bossState
end

function DrillbotManager.Cl_GetFightCenter()
	if g_drillbotManagerClientWorld then
		local world = sm.world.getCurrentWorld()
		if sm.exists( world ) then
			if g_drillbotManagerClientWorld[world.id] then
				return g_drillbotManagerClientWorld[world.id]:cl_getFightCenter()
			end
		end
	end
	return nil
end

function DrillbotManager.cl_getFightCenter( self )
	return self.cl.fightCenter
end

function DrillbotManager.Cl_GetCurrentCart()
	if g_drillbotManagerClientWorld then
		local world = sm.world.getCurrentWorld()
		if sm.exists( world ) then
			if g_drillbotManagerClientWorld[world.id] then
				return g_drillbotManagerClientWorld[world.id]:cl_getCurrentCart()
			end
		end
	end
	return nil
end

function DrillbotManager.cl_getCurrentCart( self )
	return self.cl.cartArray[self.cl.currentCartIdx]
end

function DrillbotManager.sv_e_playerExitedArena( self, player )
	if self.sv.saved.activated == false then
		return
	end






	-- this out of arena status will give you the spectate camera. you are considered out of arena until the fight advances to the next cart where you will placed awaiting revival.
	self.sv.saved.outOfArenaPlayers[player.id] = { timer = 4, player = player, cartIndex = self.sv.saved.currentCartIdx }
	
	sm.storage.save( STORAGE_CHANNEL_DRILLBOT_MANAGER, self.sv.saved )
	self.network:setClientData( self:sv_makeClientData(), 1 )

end
