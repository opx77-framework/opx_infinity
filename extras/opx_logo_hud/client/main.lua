-- The OPX badge: one passive hud-layer page, created when this resource starts
-- on the player's machine and dropped with it. The page is static (a picture
-- on a plate), so nothing is ever sent to it.

local page = nil

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    local created, failure = WebUI.create({
        entry = "web/index.html",
        layer = "hud",
        width = 1920,
        height = 1080,
        fps = 10,
        -- Under opx_infinity's own surface (700), so the chat and every menu
        -- draw over the badge; over the game's own HUD.
        zIndex = 650,
        transparent = true,
        visible = true,
    })
    if created == nil then
        print("[opx_logo_hud] the badge could not be drawn: " .. tostring(failure))
        return
    end
    page = created
    print("[opx_logo_hud] the OPX badge is up at the top of the screen")
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    page = nil
end)
