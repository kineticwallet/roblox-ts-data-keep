--!nocheck
--!optimize 2

local TS = _G[script.Parent]
local LemonSignal = TS.import(script, TS.getModule(script, "@rbxts", "lemon-signal").dist).Signal
return LemonSignal
