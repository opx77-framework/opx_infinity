--- The ripperdoc's view seam: the one file here that knows the other end is a
-- CEF surface (README: the view seam).
-- @author XEROX710
--
-- A TRANSLATOR THAT ALSO LAYS OUT THE BODY. The server's frame says what the
-- patient has fitted and what the chair is doing; the TRAY -- a hundred-odd
-- pieces, five tiers each -- is shared config both runtimes already hold, so it
-- never crosses the wire. This file joins the two into ONE PAGE OF FACTS for
-- the page: the body systems with their slots, the pieces of the system being
-- browsed, and the one piece opened in full. Browsing is local -- a click on a
-- system or a piece redraws from the last frame, no round trip -- and every
-- press that changes chrome goes to the server, which decides it.
--
-- ONE CHANNEL OUT, KIND-DISCRIMINATED (`ripperdoc:view`); the page's intents
-- in, one channel each (`ripperdoc:offer`, `:answer`, `:invite`, `:stand`,
-- `:close`, `:browse`).

local M = OPX.Modules.Get('ripperdoc')

local SURFACE = 'interactive'
local CHANNEL = 'ripperdoc:view'

--- What this module answers for on `focus:set`, and what it asks for when it
--- does. `keyboard = false`: the clinic is a menu to read and click, and the
--- game keeps the movement keys and the E that works the chair.
local FOCUS = {
	['ripperdoc.panel'] = { keyboard = false, cursor = true },
}

-- The last frame the server sent, and what the patient is looking at.
local frame = nil
local browsing = { system = nil, piece = nil }

-- What the page has up: a sitter's or a desk's screen, an invitation, or
-- nothing ('sitter', 'desk', 'invite' or nil). Escape is the clinic's only
-- while one is.
local showing = nil

-- The page's ceilings, stated once: a system's piece list and a piece's
-- grades. The largest base-game system holds 17 pieces.
local MAX_PIECES = 24
local MAX_GRADES = 8

--- Answers the surface-wide focus broadcast for this module's own owners.
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

--- Gives up every focus this module took. `Stop` calls it -- a menu put away
--- must hand the cursor back.
function M.RipperView.Release()
	for name in pairs(FOCUS) do OPX.UI.ReleaseFocus(name) end
end

--- Publishes one message to the page. Both answers of `OPX.UI.Send` are read:
--- the host refuses an oversized payload whole, and a frame lost that way is a
--- menu that silently never opens -- named here so it cannot pass for a quiet one.
-- @param payload table
local function toPage(payload)
	local sent, refused = OPX.UI.Send(SURFACE, CHANNEL, payload)
	if not sent or refused then
		Open77.log.warn('[ripperdoc] the frame did not reach the page: '
			.. (refused and 'the host refused the payload' or 'no surface'))
	end
end

-- ── the page's facts ────────────────────────────────────────────────────────

-- The numbers a grade shows, per kind of power, in the order they read.
local STATS = {
	arms = { 'normalDamage', 'chargedDamage', 'knockbackMeters', 'cooldownMs' },
	legs = { 'jumpStaminaCost', 'cooldownMs', 'maxAirborneMs' },
	hacking = { 'damage', 'range', 'uploadMs', 'cooldownMs' },
	ice = { 'charges', 'rechargeMs' },
	dash = { 'staminaCost', 'cooldownMs', 'maxCharges' },
	reflex = { 'durationMs', 'cooldownMs', 'staminaCost' },
	ability = { 'damage', 'radius', 'cooldownMs', 'staminaCost' },
}
local EFFECT_ORDER = { 'armor', 'healthMax', 'healthRegen', 'staminaMax', 'staminaRegen',
	'noFall', 'capacity' }

--- The stat run one grade shows.
-- @param entry table
-- @param grade table
-- @return table array of { key, value }
local function statsOf(entry, grade)
	local kind = M.Ripper.GrantKind(entry)
	local source, order = grade.VALUE, nil
	if M.Ripper.KindOf(entry) == 'ice' then
		source, order = grade.ICE, STATS.ice
	elseif kind == 'hacking' then
		source, order = grade.HACK, STATS.hacking
	elseif kind ~= nil then
		order = STATS[kind]
	elseif entry.SLOT == 'arms' or entry.SLOT == 'legs' then
		order = STATS[entry.SLOT]
	end
	local out = {}
	if type(source) ~= 'table' or order == nil then return out end
	for _, key in ipairs(order) do
		local value = tonumber(source[key])
		if value ~= nil and value ~= 0 then out[#out + 1] = { key = key, value = value } end
	end
	return out
end

--- The effect run one grade shows.
-- @param grade table
-- @return table array of { key, value }
local function effectsOf(grade)
	local out = {}
	local effects = type(grade.EFFECTS) == 'table' and grade.EFFECTS or {}
	for _, key in ipairs(EFFECT_ORDER) do
		local value = effects[key]
		if value == true then
			out[#out + 1] = { key = key, value = 1 }
		elseif tonumber(value) ~= nil and tonumber(value) ~= 0 then
			out[#out + 1] = { key = key, value = tonumber(value) }
		end
	end
	return out
end

--- The patient's fitted pieces by id, out of the frame.
-- @param chrome table|nil
-- @return table
local function fittedOf(chrome)
	local out = {}
	local rows = type(chrome) == 'table' and type(chrome.fitted) == 'table' and chrome.fitted or {}
	for _, row in ipairs(rows) do
		if type(row) == 'table' and type(row.id) == 'string' then out[row.id] = row end
	end
	return out
end

-- What the game itself calls a record, read once from the live TweakDB
-- (`Open77.data`, in the player's own language) and kept: a detail pane is
-- redrawn on every frame, the answer never changes.
local gameNames = {}

--- The base game's own name for one record, or ''.
-- @param record string|nil
-- @return string
local function gameName(record)
	if type(record) ~= 'string' or record == '' then return '' end
	local known = gameNames[record]
	if known ~= nil then return known end
	local name = ''
	local api = type(Open77) == 'table' and Open77.data or nil
	if type(api) == 'table' then
		for _, reader in ipairs({ api.item, api.weapon }) do
			if type(reader) == 'function' then
				local ran, value = pcall(reader, record)
				if ran and type(value) == 'table' and type(value.displayName) == 'string'
					and value.displayName ~= '' then
					name = value.displayName
					break
				end
			end
		end
	end
	if #name > 80 then name = name:sub(1, 80) end
	gameNames[record] = name
	return name
end

--- One piece as a row of the list.
-- @param entry table
-- @param fitted table|nil
-- @return table
local function rowOf(entry, fitted)
	local grades = type(entry.GRADES) == 'table' and entry.GRADES or {}
	local first, last = grades[1], grades[#grades]
	-- LEAN ON PURPOSE: a system is up to seventeen of these in one payload
	-- beside the body (every system with its filled slots) and the piece, under
	-- the host's node ceiling. A field that would say "no" is left out and the
	-- page reads the absence as the no.
	local row = {
		id = entry.id,
		name = entry.NAME,
		kind = entry.KIND,
		tierFrom = first ~= nil and first.TIER or 1,
		priceFrom = first ~= nil and first.PRICE or 0,
		-- The base game's own picture of the piece: the file it ships as
		-- (`M.Cyber.PictureFor`, eight hex characters).
		icon = M.Cyber.PictureFor(entry),
	}
	if last ~= nil and last ~= first then row.tierTo = last.TIER end
	if entry.ICONIC == true then row.iconic = true end
	if fitted ~= nil then
		row.fitted, row.points, row.state = fitted.grade, fitted.points, fitted.state
		-- The worn grade's tier: the colour the piece wears in the grid.
		local worn = M.Ripper.Grade(entry, fitted.grade)
		if worn ~= nil and worn.TIER ~= row.tierFrom then row.tier = worn.TIER end
		if fitted.broken == true then row.broken = true end
	end
	return row
end

--- The one piece the patient opened, in full.
-- @param entry table
-- @param fitted table|nil
-- @return table
local function detailOf(entry, fitted)
	local grades = {}
	-- What the fitted grade trades in for: an upgrade is priced the way the
	-- server's rule book prices it, so the button says what the offer will.
	-- A broken piece is scrap and credits nothing (the same rule).
	local worn = fitted ~= nil and fitted.broken ~= true and M.Ripper.Grade(entry, fitted.grade) or nil
	local credit = worn ~= nil and math.floor((worn.PRICE or 0) * M.Ripper.TradeIn()) or 0
	for index, grade in ipairs(type(entry.GRADES) == 'table' and entry.GRADES or {}) do
		if index > MAX_GRADES then break end
		local owned = fitted ~= nil and fitted.grade == grade.id
		local upgrade = fitted ~= nil and not owned
		local row = {
			id = grade.id, name = grade.NAME, tier = grade.TIER, price = grade.PRICE,
			capacity = grade.CAPACITY,
			hack = type(grade.HACK) == 'table' and grade.HACK.kind or nil,
		}
		-- What the base game itself calls the item the grade is (its record's
		-- display name, in the player's language); the record id stays here.
		local game = grade.RECORD ~= nil and gameName(grade.RECORD) or ''
		if game ~= '' then row.game = game end
		if upgrade then
			row.upgrade, row.cost = true, math.max(0, (grade.PRICE or 0) - credit)
		end
		if owned then row.owned = true end
		local effects, stats = effectsOf(grade), statsOf(entry, grade)
		if #effects > 0 then row.effects = effects end
		if #stats > 0 then row.stats = stats end
		grades[#grades + 1] = row
	end
	return {
		id = entry.id,
		name = entry.NAME,
		desc = entry.DESC,
		icon = M.Cyber.PictureFor(entry),
		kind = entry.KIND,
		system = entry.SYSTEM,
		power = M.Ripper.GrantKind(entry),
		iconic = entry.ICONIC == true,
		remove = entry.REMOVE,
		unsold = entry.HIDDEN == true or nil,
		-- The two yes-or-no facts ride only when they are yes: `pulled` is a
		-- broken implant the platform took out of the body. `left` is how long
		-- the piece has before it breaks at the rate the calendar wears it now,
		-- `wear` / `wearCap` its hard-use allowance spent and whole -- seconds of
		-- its life, absent on a broken piece or with durability off.
		fitted = fitted ~= nil and {
			grade = fitted.grade, points = fitted.points, state = fitted.state,
			broken = fitted.broken == true or nil, pulled = fitted.inBody == false or nil,
			repair = fitted.repair,
			left = fitted.left, wear = fitted.left ~= nil and fitted.wear or nil,
			wearCap = fitted.left ~= nil and fitted.wearCap or nil,
		} or nil,
		grades = grades,
	}
end

--- One fitted piece as a filled slot on the body: what the base game's slot
--- shows -- the picture, the tier's colour -- and the condition beside it.
-- @param row table the frame's fitted row
-- @param entry table
-- @return table
local function slotOf(row, entry)
	local grade = M.Ripper.Grade(entry, row.grade)
	local slot = {
		id = row.id,
		name = entry.NAME,
		icon = M.Cyber.PictureFor(entry),
		tier = grade ~= nil and grade.TIER or 1,
		state = row.broken == true and 'broken' or row.state,
		points = row.points,
	}
	if entry.ICONIC == true then slot.iconic = true end
	return slot
end

--- The body systems with their slots and what fills them, and the one being
--- browsed. A fitted piece sits in its own system, in the order the frame
--- lists it; a broken implant the platform pulled still holds its slot.
-- @param chrome table|nil
-- @return table
local function systemsOf(chrome)
	local used = {}
	local rows = type(chrome) == 'table' and type(chrome.systems) == 'table' and chrome.systems or {}
	for _, row in ipairs(rows) do
		if type(row) == 'table' then used[row.id] = row end
	end
	local worn = {}
	local fitted = type(chrome) == 'table' and type(chrome.fitted) == 'table' and chrome.fitted or {}
	for _, row in ipairs(fitted) do
		local entry = type(row) == 'table' and M.Ripper.Entry(row.id) or nil
		if entry ~= nil and type(entry.SYSTEM) == 'string' then
			local list = worn[entry.SYSTEM] or {}
			worn[entry.SYSTEM] = list
			list[#list + 1] = slotOf(row, entry)
		end
	end
	local out = {}
	for _, system in ipairs(M.Ripper.Systems()) do
		local seen = used[system.id]
		out[#out + 1] = { id = system.id, used = seen ~= nil and seen.used or 0,
			slots = seen ~= nil and seen.slots or system.SLOTS, worn = worn[system.id] or {} }
	end
	return out
end

--- The body family the paperdoll draws: the appearance module's answer for
--- this client's character, 'female' or 'male', or nil when it has none.
-- Read once per opening; the family does not change under a sitting patient.
local family = nil

--- @return string|nil
local function familyOf()
	if family ~= nil then return family end
	local appearance = OPX.Api.Get('appearance')
	if appearance == nil or type(appearance.GetFamily) ~= 'function' then return nil end
	local ran, result = pcall(appearance.GetFamily)
	local value = ran and type(result) == 'table' and result.ok == true and type(result.value) == 'table'
		and result.value.family or nil
	if value == 'female' or value == 'male' then family = value end
	return family
end

--- The plating the patient's chrome adds up to, the way the server composes
--- it (`server/effects.lua` `Totals`): every fitted grade's armor at the
--- condition's factor, capped at `EFFECTS.ARMOR_CAP` -- the armor meter's
--- reading and its top.
-- @param chrome table
-- @return table { now, max }
local function armorOf(chrome)
	local block = type(M.Settings.EFFECTS) == 'table' and M.Settings.EFFECTS or {}
	local cap = OPX.Math.Finite(block.ARMOR_CAP)
	if cap == nil or cap < 0 then cap = 80 end
	local total = 0
	for _, row in ipairs(type(chrome.fitted) == 'table' and chrome.fitted or {}) do
		local entry = type(row) == 'table' and M.Ripper.Entry(row.id) or nil
		local grade = entry ~= nil and M.Ripper.Grade(entry, row.grade) or nil
		local effects = grade ~= nil and grade.EFFECTS or nil
		local armor = type(effects) == 'table' and tonumber(effects.armor) or nil
		if armor ~= nil then total = total + armor * M.Ripper.EffectFactor(row.points, row.broken) end
	end
	return { now = math.floor(math.min(total, cap)), max = math.floor(cap) }
end

--- The page payload for a sitter or a desk frame: the frame's own fields plus
--- the body laid out for the system and the piece being browsed.
-- @param source table the server's frame
-- @return table
local function compose(source)
	local out = {}
	for key, value in pairs(source) do
		if key ~= 'chrome' then out[key] = value end
	end
	local chrome = source.chrome
	if type(chrome) ~= 'table' then
		out.systems, out.pieces, out.detail = {}, {}, nil
		return out
	end
	local fitted = fittedOf(chrome)
	local systems = systemsOf(chrome)

	-- The system browsed: the one asked for, else the first system that holds
	-- something, else the first.
	local system = browsing.system
	local known = false
	for _, row in ipairs(systems) do if row.id == system then known = true end end
	if not known then
		system = nil
		for _, row in ipairs(systems) do
			if system == nil and row.used > 0 then system = row.id end
		end
		system = system or (systems[1] ~= nil and systems[1].id or nil)
		browsing.system = system
	end

	local pieces, selected = {}, nil
	for _, entry in ipairs(M.Ripper.Catalog()) do
		-- Off the shelf (`VANILLA.SELL_RP`): shown only to a patient who
		-- already wears one, so it can still be pulled or mended.
		local shown = entry.HIDDEN ~= true or fitted[entry.id] ~= nil
		if shown and entry.SYSTEM == system and #pieces < MAX_PIECES then
			pieces[#pieces + 1] = rowOf(entry, fitted[entry.id])
			if entry.id == browsing.piece then selected = entry end
		end
	end
	-- Fitted first, then by tier, then by name key: what the patient wears
	-- reads at the top of its system.
	table.sort(pieces, function(a, b)
		if (a.fitted ~= nil) ~= (b.fitted ~= nil) then return a.fitted ~= nil end
		if a.tierFrom ~= b.tierFrom then return a.tierFrom < b.tierFrom end
		return a.id < b.id
	end)
	if selected == nil and pieces[1] ~= nil then
		selected = M.Ripper.Entry(pieces[1].id)
		browsing.piece = pieces[1].id
	end

	out.ready = chrome.ready == true
	out.capacity = chrome.capacity
	out.armor = armorOf(chrome)
	out.systems = systems
	out.system = system
	out.pieces = pieces
	out.detail = selected ~= nil and detailOf(selected, fitted[selected.id]) or nil
	-- The paperdoll's body: the patient's own on a sitter's page. The desk
	-- cannot read another player's family, and draws the default body.
	if source.mode == 'sitter' then out.family = familyOf() end
	-- The one offer's piece as the confirmation draws it, the way the game's
	-- purchase popup does: its picture and the colour of the tier offered.
	local offer = source.offer
	local offered = type(offer) == 'table' and M.Ripper.Entry(tostring(offer.entry or '')) or nil
	if offered ~= nil then
		local copy = {}
		for key, value in pairs(offer) do copy[key] = value end
		local grade = M.Ripper.Grade(offered, offer.grade)
		copy.icon = M.Cyber.PictureFor(offered)
		copy.tier = grade ~= nil and grade.TIER or 1
		if offered.ICONIC == true then copy.iconic = true end
		out.offer = copy
	end
	return out
end

-- Whether a thread is already building the tray for a frame that arrived
-- before it was ready.
local warming = false

--- Sends the last frame, laid out -- at once when the tray is built, or once
--- the tray has been built a few rows per resume (`M.Ripper.WarmCatalog`).
local function draw()
	if frame == nil then return end
	if M.Ripper.CatalogReady() then return toPage(compose(frame)) end
	if warming then return end
	warming = true
	CreateThread(function()
		M.Ripper.WarmCatalog(3)
		warming = false
		Wait(0)
		if frame ~= nil then toPage(compose(frame)) end
	end)
end

--- One frame from the state half, laid out and sent.
-- @param payload table
local function onFrame(payload)
	if type(payload) ~= 'table' then return end
	local mode = payload.mode
	if mode == 'sitter' or mode == 'desk' then
		frame = payload
		showing = mode
		return draw()
	end
	if mode == 'invite' then showing = mode end
	if mode == 'closed' then
		frame = nil
		showing = nil
		browsing.system, browsing.piece = nil, nil
		family = nil
	end
	toPage(payload)
end

--- ESCAPE, THE PLATFORM'S WAY. The pause plugin swallows the key before any
--- page sees it and raises `open77:pauseKey` instead, and the pause menu
--- stands back while a surface holds the input -- which the clinic's page does
--- (it takes the cursor). So the clinic answers the key itself: the page steps
--- back the way its ESC hint says -- out of a system to the body, then out of
--- the chair, away from the desk, or declining an invitation. With nothing up,
--- the key is left to the pause menu.
local function onPauseKey()
	if showing ~= nil then toPage({ mode = 'escape' }) end
end

--- The page asked to look at another system or piece: redrawn from the last
--- frame, with nothing asked of the server.
-- @param system any
-- @param piece any
function M.RipperView.Browse(system, piece)
	if type(system) == 'string' and system ~= browsing.system then
		browsing.system = system
		browsing.piece = nil
	end
	if type(piece) == 'string' then
		local entry = M.Ripper.Entry(piece)
		if entry ~= nil then
			browsing.piece = piece
			browsing.system = entry.SYSTEM
		end
	end
	draw()
end

--- Wires the state half to the page and the page's intents back.
function M.RipperView.Start()
	-- Before the intents: the page announces its focus during the same burst
	-- that opens the panel, and an announcement with no handler is dropped.
	OPX.UI.On(SURFACE, 'focus:set', onFocus)

	for _, verb in ipairs({ 'offer', 'answer', 'invite', 'stand', 'close', 'browse' }) do
		OPX.UI.On(SURFACE, 'ripperdoc:' .. verb, function(payload)
			M.Ripper.FromView(verb, payload)
		end)
	end

	AddEventHandler(M.Event.VIEW, onFrame)
	AddEventHandler(M.Host.PAUSE_KEY, onPauseKey)
end

--- Takes the seam down and gives up anything the page still holds.
function M.RipperView.Stop()
	M.RipperView.Release()
	frame = nil
	showing = nil
	browsing.system, browsing.piece = nil, nil
	family = nil
	toPage({ mode = 'closed', why = 'stop' })
end
