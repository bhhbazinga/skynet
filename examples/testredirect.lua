--[[
FileName: testredirect.lua
Module: 
Author: turbobhh
Mail: turbobhh@gmail.com
CreatedTime: Thu 11 May 2017 03:22:04 PM CST
]]

local skynet = require "skynet"
	       require "skynet.manager"
local num = 10
local mode = ...
if mode == "agent" then
skynet.register_protocol {
	name = "test",
	id = 100,
	unpack = skynet.unpack,
}
skynet.start(function()
	skynet.dispatch("test", function(_, _, ...)
		skynet.ret(skynet.pack("aa", "bb", "cc"))
	end)
end)

else

skynet.register_protocol {
	name = "test",
	id = 100,
	unpack = function(msg, sz) return msg, sz end,
}
--[[
skynet.start(function()
	local agent = skynet.newservice("testredirect", "agent")
	skynet.dispatch("test", function(id, s, msg, sz)
		print(skynet.unpack(msg, sz))
		skynet.redirect(agent, s, "test", 0, msg, sz)
	end)
end)
]]

skynet.forward_type({[100] = 100}, function()
	local agent = skynet.newservice("testredirect", "agent")
	skynet.dispatch("test", function(id, s, msg, sz)
		skynet.redirect(agent, s, "test", s, msg, sz)
	end)
end)
end


