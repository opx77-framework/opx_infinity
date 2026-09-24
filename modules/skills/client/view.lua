--- The skill tree's view seam: the one file here that knows the other end is a
-- CEF surface (README: the view seam).
-- @author XEROX710
--
-- A TRANSLATOR AND NOTHING ELSE. The state half publishes what the page draws
-- on `M.Event.SKILL_VIEW`; this file turns those into one page channel and
-- turns the page's two intents back into `M.Skill.FromView` calls. It owns no
-- state and makes no decision -- the moment it does either, the state half is
-- no longer the only answer to "is the tree open".
--
-- ONE CHANNEL OUT, KIND-DISCRIMINATED (`skills:view`); two channels in
-- (`skills:spend`, `skills:close`), one per intent -- the scanner's own shape,
-- which the page's `useBridge` already speaks.

local M = OPX.Modules.Get('skills')

local SURFACE = 'interactive'
local CHANNEL = 'skills:view'

--- What this module answers for on `focus:set`, and what it asks for when it
-- does.
--
-- THE KEYBOARD IS NOT HANDED OVER BY ASKING THE PAGE. `focus:set` is a
-- BROADCAST: the page announces that its own stack changed, and every view
-- module on this surface answers for ITS OWN owner by calling
-- `OPX.UI.AcquireFocus`. Nothing else calls it, so an owner no module claims is
-- an owner nobody acquires -- and the game keeps the keyboard.
--
-- `keyboard = false`, like the scanner and the cursor-mode menus: the tree is a
-- chart to read and press, not a dialog -- the game keeps the movement keys and
-- the F3 that stows it, and nodes are chosen by clicking them.
local FOCUS = {
	['skills.tree'] = { keyboard = false, cursor = true },
}

--- Answers the surface-wide focus broadcast for this module's own owners.
-- Release every owner of mine that is not the announced one, then acquire the
-- announced one if it is mine (the scanner's own rule, for the same reason).
-- @param payload table|nil
local function onFocus(payload)
	if type(payload) ~= 'table' then return end
	local owner = payload.owner
	local held = (payload.focus == true and type(owner) == 'string') and owner or nil
	for name in pairs(FOCUS) do
		if name ~= held then OPX.UI.ReleaseFocus(name) end
	end
	local wants = held ~= nil and FOCUS[held] or nil
	if wants == nil then return end
	OPX.UI.AcquireFocus(held, wants)
end

--- Gives up every focus this module took. The stow path calls it (a tree put
-- away must hand the cursor back), and `Stop` says it the same way.
function M.SkillView.Release()
	for name in pairs(FOCUS) do OPX.UI.ReleaseFocus(name) end
end

--- Publishes one message to the page. Both answers of `OPX.UI.Send` are read:
-- the host bounds a WebUI payload and refuses an oversized one whole, and a
-- frame lost that way is a tree that silently never opens -- named here so it
-- cannot pass for a quiet one.
-- @param payload table
local function toPage(payload)
	local sent, refused = OPX.UI.Send(SURFACE, CHANNEL, payload)
	if not sent or refused then
		Open77.log.warn('[skills] the tree frame did not reach the page: '
			.. (refused and 'the host refused the payload' or 'no surface'))
	end
end

--- Wires the state half to the page and the page's intents back.
function M.SkillView.Start()
	-- Before the intents: the page announces its focus during the same burst
	-- that opens the panel, and an announcement with no handler is dropped.
	OPX.UI.On(SURFACE, 'focus:set', onFocus)

	OPX.UI.On(SURFACE, 'skills:spend', function(payload)
		M.Skill.FromView('spend', payload)
	end)
	OPX.UI.On(SURFACE, 'skills:close', function(payload)
		M.Skill.FromView('close', payload)
	end)

	AddEventHandler(M.Event.SKILL_VIEW, toPage)
end

--- Takes the seam down and gives up anything the page still holds.
function M.SkillView.Stop()
	M.SkillView.Release()
	toPage({ kind = 'close', why = 'stop' })
end
