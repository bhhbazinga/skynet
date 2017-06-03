local skynet = require "skynet"
--local sprotoloader = require "sprotoloader"

local max_client = 64
skynet.register_protocol {
	name = "test",
	id = 100,
	pack = skynet.pack,
	unpack = skynet.unpack,
}

skynet.start(function()
	--[[
	skynet.error("Server start")
	skynet.uniqueservice("protoloader")
	if not skynet.getenv "daemon" then
		local console = skynet.newservice("console")
	end
	skynet.newservice("debug_console",8000)
	skynet.newservice("simpledb")
	local watchdog = skynet.newservice("watchdog")
	skynet.call(watchdog, "lua", "start", {
		port = 8888,
		maxclient = max_client,
		nodelay = true,
	})
	skynet.error("Watchdog listen on", 8888)
	]]
--	local add = skynet.newservice("testredirect")
--	print(skynet.call(add, "test", "asdasdasdasdasd"))
--	print("*******")
--	print(skynet.call(add, "test", 1, 2,3))
--	skynet.exit()
	for i = 1, 10000 do
		skynet.newservice("test_srv")
	end
end)
