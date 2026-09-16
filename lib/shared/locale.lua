--- Locale catalogues, lookup with fallback and the global locale shorthand.
-- @author dop42

-- Language code, then key, then text.
local catalogs = {}

local active = 'en'

-- Every lookup falls back here, so an untranslated key still reads as words.
local FALLBACK = 'en'

OPX.Locale = {}
local Locale = OPX.Locale

--- Merges a language's strings into its catalogue, replacing only the keys given.
-- @author dop42
-- @param code string
-- @param strings table<string, string>
function OPX.Locale.Register(code, strings)
	local catalog = catalogs[code]
	if not catalog then
		catalog = {}
		catalogs[code] = catalog
	end
	for key, text in pairs(strings) do catalog[key] = text end
end

--- @author dop42
-- @param code string
-- @return boolean
function OPX.Locale.Set(code)
	if type(code) ~= 'string' or code == '' then return false end
	active = code
	return true
end

--- @author dop42
-- @return string
function OPX.Locale.Current()
	return active
end

--- Whether the active or fallback catalogue carries a key.
-- @author dop42
-- @param key string
-- @return boolean
function OPX.Locale.Exists(key)
	return (catalogs[active] and catalogs[active][key] ~= nil)
		or (catalogs[FALLBACK] and catalogs[FALLBACK][key] ~= nil)
end

--- Resolves a key through the active catalogue, the fallback, then itself.
-- Answering the key itself rather than nil means a missing string shows up on
-- screen as the key that is missing, and never as a concatenation error.
-- @author dop42
-- @param key string
-- @param params table<string, string|number>|nil
-- @return string
function OPX.Locale.Text(key, params)
	local catalog = catalogs[active]
	local text = (catalog and catalog[key])
		or (catalogs[FALLBACK] and catalogs[FALLBACK][key])
		or key
	return OPX.String.Interpolate(text, params)
end

-- The global shorthand every gameplay file calls.
locale = Locale.Text

Locale.Set(OPX.Config.SHARED and OPX.Config.SHARED.LOCALE)
