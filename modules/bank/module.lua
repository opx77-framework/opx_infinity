--- Bank branches: a marker, a key, and a menu that moves money between the
--- account a paycheck lands in and the cash in hand.
-- @author XEROX710
--
-- A place-shaped module like `clothing`, `garages` and `dealership`, sharing
-- their spot vocabulary (`OPX.Spots`) and their capture commands. The client
-- draws one marker per branch in the player's own routing bucket, posts a row
-- while the player stands on one, and opens the branch's menu when the key is
-- pressed; the server owns the list and every eddie that moves.
--
-- `character` is what the SERVER needs and only the server: a transaction is
-- two money writes on a loaded character, and a bank with no character contract
-- can do nothing. It is declared OPTIONAL, as `avdoor` declares it, and the
-- refusal is made at run time instead of at load: without the contract `Start`
-- logs one warning and every ask is answered `no_character`. `menu`, `form` and
-- `prompts` are optional client surfaces: without the strip the key still
-- works, and without a menu the key says so out loud.

local M = OPX.Modules.Declare{
	id = 'bank',
	side = 'both',
	fatal = false,
	optional = { 'character', 'menu', 'form', 'prompts' },
}

local NET = OPX.Channel.NET
local LOCAL = OPX.Channel.LOCAL

--- Every event name this module raises, built once so both halves agree.
M.Event = {
	-- Client to server: the branch list of this player's bucket, please.
	-- Carries nothing.
	ASK = OPX.Event(NET, 'bank', 'ask'),
	-- Server to client: the branches of this player's own routing bucket.
	SYNC = OPX.Event(NET, 'bank', 'sync'),
	-- Client to server: "I pressed the key at a branch". Carries nothing: the
	-- server reads the position off the connection and finds the branch itself.
	OPEN = OPX.Event(NET, 'bank', 'open'),
	-- Server to client: the branch and both balances, or the refusal.
	STATE = OPX.Event(NET, 'bank', 'state'),
	-- Client to server: `{ kind = 'withdraw'|'deposit', amount = n }` or
	-- `{ kind, all = true }`. Judged again from scratch.
	MOVE = OPX.Event(NET, 'bank', 'move'),
	-- Server to client: what the move came to, with both balances after it.
	RESULT = OPX.Event(NET, 'bank', 'result'),
	-- The client's own bus: every verdict, local refusals included.
	ON_DECISION = OPX.Event(LOCAL, 'bank', 'decision'),
}

--- The two directions money moves in.
M.KINDS = { withdraw = true, deposit = true }

--- Every refusal the server can name, as the sentence a player reads.
M.Refusal = {
	no_character = 'bank.refused.noCharacter',
	not_at_branch = 'bank.refused.notAtBranch',
	bad_kind = 'bank.refused.badAmount',
	bad_amount = 'bank.refused.badAmount',
	too_much = 'bank.refused.tooMuch',
	insufficient = 'bank.refused.insufficient',
	nothing = 'bank.refused.nothing',
	busy = 'bank.refused.busy',
	failed = 'bank.refused.failed',
}

--- A whole, positive amount of eddies no larger than the ceiling, or nil.
-- @param value any
-- @param ceiling number
-- @return integer|nil
function M.Amount(value, ceiling)
	local number = tonumber(value)
	if number == nil or number ~= number or number == math.huge or number == -math.huge then return nil end
	if number % 1 ~= 0 or number < 1 then return nil end
	if ceiling ~= nil and number > ceiling then return nil end
	return math.floor(number)
end
