local skynet       = require "skynet"
local crypt        = require "skynet.crypt"
local socket       = require "skynet.socket"
local sockethelper = require "http.sockethelper"
local httpd        = require "http.httpd"
local urllib       = require "http.url"
local string       = string

local ws = {}
local ws_mt = { __index = ws }

local function response(id, ...)
	return httpd.write_response(sockethelper.writefunc(id), ...)
end

local function write(id, data)
	socket.write(id, data)
end

local function read(id, sz)
	return socket.read(id, sz)
end

local function challenge_response(key, protocol)
	protocol = protocol or ""
	if protocol ~= "" then
		protocol = protocol .. "\r\n"
	end

	local accept = crypt.base64encode(crypt.sha1(key .. "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
	return string.format("HTTP/1.1 101 Switching Protocols\r\n" ..
	"Upgrade: websocket\r\n" ..
	"Connection: Upgrade\r\n" ..
	"Sec-WebSocket-Accept: %s\r\n" ..
	"%s\r\n", accept, protocol)

end

local function accept_connection(header, check_origin, check_origin_ok)
	-- Upgrade header should be present and should be equal to WebSocket
	if not header["upgrade"] or header["upgrade"]:lower() ~= "websocket" then
		return 400, "Can \"Upgrade\" only to \"WebSocket\"."
	end

	-- Connection header should be upgrade. Some proxy servers/load balancers
	-- might mess with it.
	if not header["connection"] or not header["connection"]:lower():find("upgrade", 1,true) then
		return 400, "\"Connection\" must be \"Upgrade\"."
	end

	-- Handle WebSocket Origin naming convention differences
	-- The difference between version 8 and 13 is that in 8 the
	-- client sends a "Sec-Websocket-Origin" header and in 13 it's
	-- simply "Origin".
	local origin = header["origin"] or header["sec-websocket-origin"]
	if origin and check_origin and not check_origin_ok(origin, header["host"]) then
		return 403, "Cross origin websockets not allowed"
	end

	if not header["sec-websocket-version"] or header["sec-websocket-version"] ~= "13" then
		return 400, "HTTP/1.1 Upgrade Required\r\nSec-WebSocket-Version: 13\r\n\r\n"
	end

	local key = header["sec-websocket-key"]
	if not key then
		return 400, "\"Sec-WebSocket-Key\" must not be  nil."
	end

	local protocol = header["sec-websocket-protocol"] 
	if protocol then
		local i = protocol:find(",", 1, true)
		protocol = "Sec-WebSocket-Protocol: " .. protocol:sub(1, i and i-1)
	end

	return nil, challenge_response(key, protocol)
end

local H = {}

function H.check_origin_ok(origin, host)
	return urllib.parse(origin) == host
end

function H.on_open(ws)

end

function H.on_message(ws, message)

end

function H.on_close(ws, code, reason)

end

function H.on_pong(ws, data)
	-- Invoked when the response to a ping frame is received.

end

function ws.new(id, header, handler, conf)
	local conf = conf or {}
	local handler = handler or {}

	setmetatable(handler, { __index = H })

	local code, result = accept_connection(header, conf.check_origin, handler.check_origin_ok)

	if code then
		response(id, code, result)
		socket.close(id)
	else
		write(id, result)
	end

	local self = {
		id = id,
		handler = handler,
		mask_outgoing = conf.mask_outgoing,
		check_origin = conf.check_origin
	}

	self.handler.on_open(self)

	return setmetatable(self, ws_mt)
end

function ws:send_frame(fin, opcode, data)
	local finbit = fin and 0x80 or 0
	local mask_bit = self.mask_outgoing and 0x80 or 0

	local frame = string.pack("B", finbit | opcode)
	local l = #data

	if l < 126 then
		frame = frame .. string.pack("B", l | mask_bit)
	elseif l < 0xFFFF then
		frame = frame .. string.pack(">BH", 126 | mask_bit, l)
	else
		frame = frame .. string.pack(">BL", 127 | mask_bit, l)
	end

--	if self.mask_outgoing then
--	end

	frame = frame .. data
	write(self.id, frame)
end

function ws:send_text(data)
	self:send_frame(true, 0x1, data)
end

function ws:send_binary(data)
	self:send_frame(true, 0x2, data)
end

function ws:send_ping(data)
	self:send_frame(true, 0x9, data)
end

function ws:send_pong(data)
	self:send_frame(true, 0xA, data)
end

function ws:close(code, reason)
	-- 1000 "normal close" status code
	if self._closed then
		return
	end

	code = code or 1000
	reason = reason or "normal close"
	local data = string.pack(">H", code) .. reason
	self:send_frame(true, 0x8, data)
	self.server_terminated = true

	socket.close(self.id)
	self.handler.on_close(self, code, reason)
	self._closed = true
end

local function websocket_mask(mask, data, length)
	local umasked = {}
	for i = 1, length do
		umasked[i] = string.char(string.byte(data, i) ~ string.byte(mask, (i-1)%4 + 1))
	end
	return table.concat(umasked)
end

function ws:recv_frame()
	local data, err = read(self.id, 2)
	if not data then
		return false, nil, "Read first 2 byte error: " .. err
	end

	local header, payloadlen = string.unpack("BB", data)
	local final_frame = header & 0x80 ~= 0
	local reserved_bits = header & 0x70 ~= 0
	local frame_opcode = header & 0xf
	local frame_opcode_is_control = frame_opcode & 0x8 ~= 0

	if reserved_bits then
		-- client is using as-yet-undefined extensions
		return false, nil, "Reserved_bits show using undefined extensions"
	end

	local mask_frame = payloadlen & 0x80 ~= 0
	payloadlen = payloadlen & 0x7f

	if frame_opcode_is_control and payloadlen >= 126 then
		-- control frames must have payload < 126
		local err = "[websocket]Control frame payload overload"
		skynet.error(err)
		return false, nil, err
	end

	if frame_opcode_is_control and not final_frame then
		local err = "Control frame must not be fragmented"
		skynet.error(err)
		return false, nil, err
	end

	local frame_length, frame_mask

	if payloadlen < 126 then
		frame_length = payloadlen
	elseif payloadlen == 126 then
		local h_data, err = read(self.id, 2)
		if not h_data then
			return false, nil, "Payloadlen 126 read true length error:" .. err
		end
		frame_length = string.unpack(">H", h_data)
	else --payloadlen == 127
		local l_data, err = read(self.id, 8)
		if not l_data then
			return false, nil, "Payloadlen 127 read true length error:" .. err
		end
		frame_length = string.unpack(">L", l_data)
	end

	if mask_frame then
		local mask, err = read(self.id, 4)
		if not mask then
			return false, nil, "Masking Key read error:" .. err
		end
		frame_mask = mask
	end

	local frame_data = ""
	if frame_length > 0 then
		local fdata, err = read(self.id, frame_length)
		if not fdata then
			return false, nil, "Payload data read error:" .. err
		end
		frame_data = fdata
	end

	if mask_frame and frame_length > 0 then
		frame_data = websocket_mask(frame_mask, frame_data, frame_length)
	end

	if not final_frame then
		return true, false, frame_data
	else
		if frame_opcode == 0x1 then -- text
			return true, true, frame_data
		elseif frame_opcode == 0x2 then -- binary
			return true, true, frame_data
		elseif frame_opcode == 0x8 then -- close
			local code, reason
			if #frame_data >= 2 then
				code = string.unpack(">H", frame_data:sub(1,2))
			end
			if #frame_data > 2 then
				reason = frame_data:sub(3)
			end
			self:close(code, reason)
			return false, true, nil
		elseif frame_opcode == 0x9 then --Ping
			self:send_pong()
		elseif frame_opcode == 0xA then -- Pong
			self.handler.on_pong(self, frame_data)
		end

		return true, true, nil
	end
end

function ws:start()
	local frame = ""
	while not self._closed do
		local success, packend, frame_segment = self:recv_frame()
		if not success then
			break
		end
		frame = frame .. frame_segment
		if packend then
			self.handler.on_message(self, frame)
			frame = ""
		end
	end
end

return ws
