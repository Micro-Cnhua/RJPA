-- 锐捷校园网认证客户端 —— LuCI (Lua) 控制器
--
-- 依赖:
--   luci-compat       提供 luci.cbi / view/cbi/header|footer 模板
--   luci-lua-runtime  提供 luci.http / luci.sys / luci.template / nixio
--
-- 界面只有一页「基本设置」: 认证参数 + 运行状态 + 连接日志。
-- 服务类型不预置候选值，而是跑 `ruijie -l` 实际检测后缓存，
-- 由 CBI 模型读缓存填进下拉框（见 model/cbi/ruijie/config.lua）。

module("luci.controller.ruijie", package.seeall)

local fs = require "nixio.fs"

local CONFIG      = "ruijie"
local SECTION     = "main"
local DEFAULT_LOG = "/var/log/ruijie.log"

-- 服务类型检测的中间文件，都放内存盘，重启即清
local SVC_RAW     = "/tmp/ruijie-svclist.raw"
local SVC_CACHE   = "/tmp/ruijie-services.cache"
local SVC_DONE    = "===DONE==="


local function log_file()
	local uci = require("luci.model.uci").cursor()
	return uci:get(CONFIG, SECTION, "log_file") or DEFAULT_LOG
end


local function split_lines(data)
	local t = {}
	data = data:gsub("\r\n", "\n"):gsub("\n+$", "")
	if data == "" then
		return t
	end
	for line in (data .. "\n"):gmatch("(.-)\n") do
		t[#t + 1] = line
	end
	return t
end


local function json_escape(s)
	s = tostring(s or "")
	return (s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\r", "")
	         :gsub("\n", "\\n"):gsub("\t", "\\t"))
end


-- 解析 `ruijie -l` 的输出。程序打印的格式是:
--   认证页面提供的可选服务类型:
--     default              学校_学生
--     Teacher              学校_教师
-- 只取表头之后、符合「缩进 + 值 + 标签」的行。
local function parse_services(text)
	local list, seen, started = {}, {}, false

	for _, line in ipairs(split_lines(text)) do
		if not started then
			if line:find("认证页面提供的可选服务类型", 1, true) then
				started = true
			end
		else
			local v, label = line:match("^%s+(%S+)%s*(.*)$")
			if v and v ~= SVC_DONE and not seen[v] then
				seen[v] = true
				list[#list + 1] = { value = v, label = (label:gsub("%s+$", "")) }
			end
		end
	end

	return list
end


-- 读缓存。第二个返回值区分「检测过但没有结果」和「从来没检测过」
local function read_service_cache()
	local list = {}

	if not fs.access(SVC_CACHE) then
		return list, false
	end

	for _, line in ipairs(split_lines(fs.readfile(SVC_CACHE) or "")) do
		local v, label = line:match("^([^\t]*)\t(.*)$")
		if v and v ~= "" then
			list[#list + 1] = { value = v, label = label or "" }
		end
	end

	return list, true
end


local function write_service_cache(list)
	local buf = {}
	for _, sv in ipairs(list) do
		buf[#buf + 1] = sv.value .. "\t" .. (sv.label or "")
	end
	-- 即使一个都没检测到也要写出文件，这样能区分「检测过但是空」和「没检测过」
	fs.writefile(SVC_CACHE, table.concat(buf, "\n") .. "\n")
end


local function services_to_json(list)
	local buf = {}
	for _, sv in ipairs(list) do
		buf[#buf + 1] = string.format('{"value":"%s","label":"%s"}',
			json_escape(sv.value), json_escape(sv.label or ""))
	end
	return "[" .. table.concat(buf, ",") .. "]"
end


function index()
	entry({"admin", "network", "ruijie"},
		alias("admin", "network", "ruijie", "config"),
		_("锐捷认证"), 60)

	entry({"admin", "network", "ruijie", "config"},
		cbi("ruijie/config"), _("基本设置"), 10)

	-- 下面是给页面里 AJAX 调用的接口，leaf = true 表示不在菜单里显示
	entry({"admin", "network", "ruijie", "logdata"},
		call("action_logdata")).leaf = true

	entry({"admin", "network", "ruijie", "logclear"},
		call("action_logclear")).leaf = true

	entry({"admin", "network", "ruijie", "svcstart"},
		call("action_svcstart")).leaf = true

	entry({"admin", "network", "ruijie", "svcdata"},
		call("action_svcdata")).leaf = true
end


-- 读取日志尾部，返回纯文本，供页面里的日志框显示
function action_logdata()
	local http = require "luci.http"
	local path = log_file()

	http.prepare_content("text/plain; charset=utf-8")

	if not fs.access(path) then
		http.write("")
		return
	end

	local lines = tonumber(http.formvalue("lines")) or 200
	if lines < 10 then lines = 10 end
	if lines > 3000 then lines = 3000 end

	local kw = http.formvalue("filter") or ""

	local data = fs.readfile(path) or ""

	-- 日志异常膨胀时兜底，避免把路由器内存吃光
	if #data > 1024 * 1024 then
		data = data:sub(-(1024 * 1024))
	end

	local all = split_lines(data)
	local picked

	if kw ~= "" then
		picked = {}
		for i = 1, #all do
			if all[i]:find(kw, 1, true) then
				picked[#picked + 1] = all[i]
			end
		end
	else
		picked = all
	end

	local start = #picked - lines + 1
	if start < 1 then start = 1 end

	local buf = {}
	for i = start, #picked do
		buf[#buf + 1] = picked[i]
	end

	http.write(table.concat(buf, "\n"))
end


function action_logclear()
	local http = require "luci.http"

	fs.writefile(log_file(), "")

	http.prepare_content("application/json")
	http.write('{"ok":true}')
end


-- 启动 `ruijie -l`。它要先探测网关，最坏几十秒，所以放后台跑，
-- 页面再轮询 svcdata 取结果，避免 HTTP 请求被卡到超时。
function action_svcstart()
	local http = require "luci.http"
	local sys  = require "luci.sys"

	os.remove(SVC_RAW)
	os.remove(SVC_CACHE)

	sys.call("( /usr/bin/ruijie -l >" .. SVC_RAW .. " 2>&1; echo " ..
		SVC_DONE .. " >>" .. SVC_RAW .. " ) >/dev/null 2>&1 &")

	http.prepare_content("application/json")
	http.write('{"ok":true}')
end


-- 轮询检测进度。跑完就解析并写缓存，前端拿到 services 后重建下拉框。
function action_svcdata()
	local http = require "luci.http"

	local raw = ""
	if fs.access(SVC_RAW) then
		raw = fs.readfile(SVC_RAW) or ""
	end

	local done = raw:find(SVC_DONE, 1, true) ~= nil
	local services, detected

	if done then
		raw = raw:gsub(SVC_DONE, "")
		services = parse_services(raw)
		detected = true
		write_service_cache(services)
	else
		services, detected = read_service_cache()
	end

	http.prepare_content("application/json")
	http.write(string.format(
		'{"done":%s,"detected":%s,"text":"%s","services":%s}',
		done and "true" or "false",
		detected and "true" or "false",
		json_escape(raw),
		services_to_json(services)))
end
