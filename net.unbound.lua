-- libunbound based net.adns replacement for Prosody IM
-- Copyright (C) 2013-2014 Kim Alvefur
--
-- This file is MIT/X11 licensed.

local setmetatable = setmetatable;
local tostring = tostring;
local t_insert = table.insert;
local t_remove = table.remove;
local t_concat = table.concat;
local s_format = string.format;
local s_lower = string.lower;
local s_upper = string.upper;
local noop = function() end;
local zero = function() return 0 end;
local truop = function() return true; end;

local log = require "util.logger".init("unbound");
local config = require "core.configmanager";
local server = require "net.server";
local libunbound = require"util.lunbound";

local gettime = require"socket".gettime;
local dns_utils = require"util.dns";
local classes, types, errors = dns_utils.classes, dns_utils.types, dns_utils.errors;
local parsers = dns_utils.parsers;

local unbound_config = {
	-- https://data.iana.org/root-anchors/root-anchors.xml
	trusted = config.get("*", "unbound_ta") or
		{ [[. IN DS 19036 8 2 49AAC11D7B6F6446702E54A1607371607A1A41855200FD2CE1CDDE32F24E8FB5]] };
	resolvconf = config.get("*", "resolvconf");
	hoststxt = config.get("*", "hoststxt");
	async = true;
};
-- Note: libunbound will default to using root hints if resolvconf is unset

local unbound = libunbound.new(unbound_config);

local function connect_server(unbound, server)
	if server.event and server.addevent then
		local EV_READ = server.event.EV_READ;
		local function event_callback()
			unbound:process();
			return EV_READ;
		end
		return server.addevent(unbound:getfd(), EV_READ, event_callback)
	elseif server.wrapclient then
		local conn = {
			getfd = function()
				return unbound:getfd();
			end,

			send = zero,
			receive = noop,
			settimeout = noop,
		}

		local function process()
			unbound:process();
		end
		local listener = {
			onincoming = process,

			onconnect = noop,
			ondisconnect = noop,
			onreadtimeout = truop,
		};
		return server.wrapclient(conn, "dns", 0, listener, "*a" );
	end
end

local server_conn = connect_server(unbound, server);

local answer_mt = {
	__tostring = function(self)
		if self._string then return self._string end
		local h = s_format("Status: %s", errors[self.status]);
		if self.secure then
			h =  h .. ", Secure";
		elseif self.bogus then
			h = h .. s_format(", Bogus: %s", self.bogus);
		end
		local t = { h };
		for i=1,#self do
			t[i+1]=self.qname.."\t"..classes[self.qclass].."\t"..types[self.qtype].."\t"..tostring(self[i]);
		end
		local _string = t_concat(t, "\n");
		self._string = _string;
		return _string;
	end,
};

local callbacks = setmetatable({}, {
	__index = function(t, n)
		local nt = {};
		t[n] = nt;
		return nt;
	end
});

local function prep_answer(a)
	local status = errors[a.rcode];
	local qclass = classes[a.qclass];
	local qtype = types[a.qtype];
	a.status, a.class, a.type = status, qclass, qtype;

	local t = s_lower(qtype);
	local rr_mt = { __index = a, __tostring = function(self) return tostring(self[t]) end };
	local parser = parsers[qtype];
	for i=1, #a do
		if a.bogus then
			-- Discard bogus data
			a[i] = nil;
		else
			a[i] = setmetatable({
				[t] = parser(a[i]);
			}, rr_mt);
		end
	end
	return setmetatable(a, answer_mt);
end

local function ub_callback(a)
	local gotdataat = gettime();
	prep_answer(a);
	local q = a.qname .. " " .. a.class .. " " .. a.type;

	local cbs;
	cbs, callbacks[q] = callbacks[q], nil;

	log("debug", "Results for %s: %s (%s, %f sec)", q, a.rcode == 0 and (#a .. " items") or a.status,
		a.secure and "Secure" or a.bogus or "Insecure", gotdataat - cbs.t); -- Insecure as in unsigned

	--[[
	if #a == 0 then
		a=nil -- COMPAT Older prosody expected nil instead of table with error
	end
	--]]
	for i = 1, #cbs do
		cbs[i](a);
	end
end

local function lookup(callback, qname, qtype, qclass)
	qtype = qtype and s_upper(qtype) or "A";
	qclass = qclass and s_upper(qclass) or "IN";
	local ntype, nclass = types[qtype], classes[qclass];
	if not ntype or not nclass then
		return nil, "Invalid type or class"
	end
	if not qname or #qname <= 1 or qname:find("..", 1, true) then
		callback();
		return nil, "invalid qname";
	end
	local q = qname.." "..qclass.." "..qtype;
	local qcb = callbacks[q];
	qcb.t = qcb.t or gettime();
	local n = #qcb;
	t_insert(qcb, callback);
	if n == 0 then
		log("debug", "Resolve %s", q);
		local ok, err = unbound:resolve_async(ub_callback, qname, ntype, nclass);
		if not ok then
			log("warn", "Something went wrong, %s", err);
		end
		qcb.q = ok;
	else
		log("debug", "Already %d waiting callbacks for %s", n, q);
	end
	return {
		cb = callback,
		qname = qname,
		qtype = qtype,
		qclass = qclass,
		q = q,
		qcb = qcb,
		n = n +1;
	};
end

-- Reinitiate libunbound context, drops cache
local function purge()
	if server_conn then
		server_conn:close();
	end
	unbound = libunbound.new(unbound_config);
	server_conn = connect_server(unbound, server);
	local oldcb = callbacks;
	callbacks = setmetatable({}, getmetatable(oldcb));
	setmetatable(oldcb, nil);
	for q, cbs in pairs(oldcb) do
		for i = 1, #cbs do
			cbs[i]();
		end
	end
	return true;
end

local function cancel(query)
	local qcb, n = query.qcb, query.n;
	local ok = t_remove(qcb, n);
	if not ok then return false end
	if #qcb == 0 then
		unbound:cancel(query.q);
	end
	return true;
end

local function not_implemented()
	error "not implemented";
end
-- Public API
return {
	lookup = lookup,
	cancel = cancel;
	new_async_socket = not_implemented;
	dns = {
		cancel = cancel;
		cache = noop;
		socket_wrapper_set = noop;
		settimeout = noop;
		query = noop;
		purge = purge;
		random = noop;
		peek = noop;

		types = types;
		classes = classes;
	};
};

