--- The staff door onto a character's PURSE: give eddies, or take them back.
-- @author dop42
--
-- WHY A SECOND MONEY COMMAND. `opx.money` is the platform's own line and it is
-- the right one for an operator who already knows the citizen id they want. This
-- is the menu's door, and it is what the Recovery screen drives, so a row can be
-- pressed without typing anything on a chat line -- and the two do not have to
-- share a grant: a server may trust an operator to hand money out and not to
-- reach the whole character screen. Like `characters.lua` this file OWNS NO
-- MONEY. Every call here is one call into the `character` contract, which owns
-- the balance, the hook that can veto it, and the audit row it writes.
--
-- IT RESOLVES `me`, WHICH THE TYPED LINE DOES NOT. `opx.money` takes a player id
-- or a citizen id, and neither is any use to a row that says "give myself": the
-- id of the player holding the keyboard is not something a client should be
-- asked for, and `Server.Target` answers it from `source`, which cannot be
-- forged. `me` is the vocabulary the rest of this module's commands already
-- speak, so the row and the typed line name the same thing.
--
-- AN AMOUNT MAY BE NEGATIVE, exactly as the typed line and the money form on a
-- player's own screen already allow: one field that can take money back is worth
-- more than a second screen, and both directions are audited under this
-- command's own name with the operator's id on the row.
--
-- IT DOES NOT YIELD, and that is deliberate. `AddMoney` and `RemoveMoney` touch
-- the loaded PlayerData and the roster, never the database -- a balance reaches
-- its row on the next save -- so there is no thread here and no window in which
-- the operator's balance and the answer disagree.

local M = OPX.Modules.Get('admin')

local Server = M.Server
local Command = M.Command
local Text = OPX.Text

local answer, refuse, audit = Server.Answer, Server.Refuse, Server.Audit

M.Recovery = {}
local Recovery = M.Recovery

-- The contract's refusal codes in this module's own words. A code that is not
-- here reads as a plain refusal and the original is kept in the audit.
local CODES = {
	['error.notLoggedIn'] = 'not_connected',
	['money.offline'] = 'not_connected',
	['money.badType'] = 'bad_type',
	['money.badAmount'] = 'bad_amount',
	['money.insufficient'] = 'not_enough',
	['money.negative'] = 'not_enough',
	['money.vetoed'] = 'vetoed',
}

-- THE MOST THIS DOOR WILL CARRY, in either direction: ten digits, which is what
-- the amount field beside it accepts. Past that an amount is a paste or a slip,
-- and the next thing to see it is a client formatting it into a toast.
local CEILING = 9999999999

--- This module's word for a contract refusal.
local function codeOf(error)
	return CODES[tostring(error)] or 'refused'
end

--- Registers the recovery command. Called from the server's start list.
-- @author dop42
function Recovery.Register()
	Server.Command(Command.RECOVERY_MONEY, {
		help = 'admin.help.recoveryMoney',
		params = { { name = 'playerId|me', help = 'admin.help.playerOrMe' },
			{ name = 'TYPE', help = 'admin.help.moneyType' },
			{ name = 'amount', help = 'admin.help.moneyAmount' } },
		inGame = true,
		handler = function(source, args, raw)
			-- EVERY ARGUMENT BEFORE THE TARGET, so a malformed amount is refused
			-- without the operator having to wonder which half was wrong.
			local amount = Text.Integer(args[3])
			if amount == nil or amount == 0 or math.abs(amount) > CEILING then
				return refuse(source, raw, 'bad_amount')
			end

			local moneyType = M.Trimmed(args[2], 16)
			if moneyType == nil then return refuse(source, raw, 'bad_type') end
			moneyType = moneyType:upper()

			local contract = Server.Contract('character')
			if contract == nil then return refuse(source, raw, 'characters_unavailable') end
			-- Through the contract's own rule and not this file's idea of one: a
			-- money type is whatever the server is configured to have.
			if contract.IsMoneyType(moneyType) ~= true then return refuse(source, raw, 'bad_type') end

			local playerId = Server.Target(source, raw, args[1])
			if playerId == nil then return end

			local reason = ('recovery by %s'):format(tostring(source))

			-- A real if/else. `amount > 0 and Add() or Remove()` would run Remove
			-- as well whenever Add answered false.
			local called, done, why
			if amount > 0 then
				called, done, why = pcall(contract.AddMoney, playerId, moneyType, amount, reason)
			else
				called, done, why = pcall(contract.RemoveMoney, playerId, moneyType, -amount, reason)
			end

			-- A RAISE AND A REFUSAL ARE TOLD APART. The mutators answer `(ok, why)`
			-- rather than a Result, so a call that threw arrives as `called` being
			-- false and the message sitting in `done` -- and a command that answered
			-- nothing at all would read to the operator as a row that did nothing.
			if not called then
				audit(source, 'admin.recovery.money', false, playerId,
					('%s %s: %s'):format(moneyType, amount, tostring(done)))
				return refuse(source, raw, 'failed')
			end

			if done ~= true then
				audit(source, 'admin.recovery.money', false, playerId,
					('%s %s: %s'):format(moneyType, amount, tostring(why)))
				return refuse(source, raw, codeOf(why))
			end

			-- Read AFTER the mutation, so the number in the operator's toast is the
			-- balance the character actually holds now and not one this file
			-- worked out for itself.
			local balance = contract.GetMoney(playerId, moneyType)
			local formatted = contract.FormatMoney(balance or 0, moneyType)
			local who = Server.LabelOf(playerId) or tostring(playerId)

			audit(source, 'admin.recovery.money', true, playerId,
				('%s %+d -> %s'):format(moneyType, amount, tostring(balance)))

			answer(source, raw, true,
				amount > 0 and 'admin.done.recoveryGave' or 'admin.done.recoveryTook',
				{ name = who, id = playerId, amount = contract.FormatMoney(math.abs(amount), moneyType),
					balance = formatted, type = moneyType })
		end,
	})
end
