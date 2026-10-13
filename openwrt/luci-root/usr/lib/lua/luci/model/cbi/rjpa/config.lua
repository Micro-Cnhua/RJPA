-- 锐捷校园网认证客户端 —— LuCI CBI 配置模型
--
-- 对应 /etc/config/rjpa 里的 config rjpa 'main'
--
-- 页面结构（从上到下）:
--   1. SimpleSection → view/rjpa/status.htm   运行状态 + 服务类型检测
--   2. TypedSection  → 认证 / 日志各项参数
--   3. SimpleSection → view/rjpa/log.htm      连接日志框
--
-- 服务类型的候选值不预置，只列出 `rjpa -l` 实际检测到的结果
-- （检测结果缓存在 /tmp/rjpa-services.cache，由控制器写入）。

local translate = require("luci.i18n").translate
local fs        = require "nixio.fs"
local uci       = require("luci.model.uci").cursor()

local SVC_CACHE = "/tmp/rjpa-services.cache"

-- 读控制器写下的检测缓存。第二个返回值区分
-- 「检测过但没有结果」和「从来没检测过」。
local function read_services()
	local list = {}

	if not fs.access(SVC_CACHE) then
		return list, false
	end

	local data = (fs.readfile(SVC_CACHE) or ""):gsub("\r\n", "\n")
	for line in (data .. "\n"):gmatch("(.-)\n") do
		local v, label = line:match("^([^\t]*)\t(.*)$")
		if v and v ~= "" then
			list[#list + 1] = { value = v, label = label or "" }
		end
	end

	return list, true
end


local m, s, o

m = Map("rjpa", translate("锐捷校园网认证"),
	translate("在路由器上自动完成校园网 eportal 认证。修改后请点击“保存并应用”，服务会立即重启。"))

-- 顶部：运行状态 + 服务类型检测
m:section(SimpleSection).template = "rjpa/status"


s = m:section(TypedSection, "rjpa", translate("认证设置"))
s.anonymous = true
s.addremove = false

o = s:option(Flag, "enabled", translate("启用认证"),
	translate("勾选并保存后，开机自动启动认证服务"))
o.default = "0"
o.rmempty = false

o = s:option(Value, "username", translate("用户名"),
	translate("校园网账号，一般就是学号"))
o.datatype = "string"
o.rmempty = false

o = s:option(Value, "password", translate("密码"))
o.password = true
o.datatype = "string"
o.rmempty = false


-- ---------------------------------------------------------------- 服务类型
-- 只列出真实检测到的值；没检测过就只有一个「自动检测」，
-- 并提示用户先去上面点「检测服务类型」。
local services, detected = read_services()
local current = uci:get("rjpa", "main", "service") or "auto"

if detected then
	o = s:option(ListValue, "service", translate("服务类型"),
		translate("下面是客户端从认证页面上实际检测到的可选值。选“自动检测”则由程序自己挑第一个。"))
else
	o = s:option(ListValue, "service", translate("服务类型"),
		translate("还没检测过。请点页面上方的“检测服务类型”，检测完成后这里会列出真实可选值。"))
end

o:value("auto", translate("自动检测（用检测到的第一个）"))

local listed = { auto = true }

for _, sv in ipairs(services) do
	local label = sv.value
	if sv.label ~= "" then
		label = sv.value .. "（" .. sv.label .. "）"
	end
	o:value(sv.value, label)
	listed[sv.value] = true
end

-- 已经保存过的值必须出现在候选里，否则 CBI 会认为当前值非法。
-- 典型场景: 路由器重启后 /tmp 缓存没了，但 UCI 里还存着上次选的服务类型。
if current ~= "" and not listed[current] then
	o:value(current, current .. translate("（当前已保存）"))
end

o.default = "auto"
o.rmempty = false


-- ---------------------------------------------------------------- 其余参数
o = s:option(Value, "manual_url", translate("手动认证地址"),
	translate("留空表示自动探测。只有自动获取失败时才需要填完整地址"))
o.datatype = "string"
o.rmempty = true

o = s:option(Flag, "persistent", translate("持久化在线"),
	translate("断网后每 10 秒自动重连。强烈建议开启，否则掉线后不会自动恢复"))
o.default = "1"
o.rmempty = false

o = s:option(Value, "log_file", translate("日志文件"),
	translate("默认 /var/log/rjpa.log（内存盘，重启清空，不磨损 flash）。想重启后保留可改成 /etc/rjpa.log"))
o.default = "/var/log/rjpa.log"
o.datatype = "string"
o.rmempty = false

o = s:option(Value, "log_max_kb", translate("日志上限 (KB)"),
	translate("超过该大小后自动只保留最后 2000 行，避免“网络连接正常”刷满内存。填 0 表示不限制"))
o.default = "256"
o.datatype = "uinteger"
o.rmempty = false


-- 底部：连接日志
m:section(SimpleSection).template = "rjpa/log"

return m
