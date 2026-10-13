#
# 锐捷校园网认证客户端 (rjpa) + LuCI (Lua) 应用
#
# 目标系统: ImmortalWrt 24.10 / OpenWrt 24.10  (opkg + .ipk)
#
# 设计说明:
#   Go 二进制在 SDK 之外交叉编译好，放到 prebuilt/ 目录，
#   本 Makefile 只负责安装文件并打成 .ipk。
#   这样可以完全避开 "在 SDK 里装 golang feed / 编译 Go 工具链" 的麻烦。
#

include $(TOPDIR)/rules.mk

PKG_NAME:=rjpa
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_LICENSE:=MIT
PKG_MAINTAINER:=Your Name <you@example.com>

include $(INCLUDE_DIR)/package.mk

# ---------------------------------------------------------------------------
# OpenWrt $(ARCH) -> Go 交叉编译目标
#
# prebuilt/ 目录里的文件名必须和这里算出来的 $(RJPA_BIN) 一致。
# build-go.ps1 使用完全相同的命名规则。
# ---------------------------------------------------------------------------
GO_TARGET_ARCH :=
GO_TARGET_MIPS :=
GO_TARGET_ARM  :=

ifeq ($(ARCH),i386)
  GO_TARGET_ARCH := 386
else ifeq ($(ARCH),x86_64)
  GO_TARGET_ARCH := amd64
else ifeq ($(ARCH),mips)
  GO_TARGET_ARCH := mips
  GO_TARGET_MIPS := softfloat
else ifeq ($(ARCH),mipsel)
  GO_TARGET_ARCH := mipsle
  GO_TARGET_MIPS := softfloat
else ifeq ($(ARCH),mips64)
  GO_TARGET_ARCH := mips64
  GO_TARGET_MIPS := softfloat
else ifeq ($(ARCH),mips64el)
  GO_TARGET_ARCH := mips64le
  GO_TARGET_MIPS := softfloat
else ifeq ($(ARCH),aarch64)
  GO_TARGET_ARCH := arm64
else ifeq ($(ARCH),riscv64)
  GO_TARGET_ARCH := riscv64
else ifeq ($(ARCH),arm)
  # 少数 armv6/armv5 设备需要用 RJPA_GOARM=6 / 5 覆盖
  GO_TARGET_ARCH := arm
  GO_TARGET_ARM  := $(if $(RJPA_GOARM),$(RJPA_GOARM),7)
endif

GO_SUFFIX := $(GO_TARGET_ARCH)
ifneq ($(GO_TARGET_MIPS),)
  GO_SUFFIX := $(GO_SUFFIX)-$(GO_TARGET_MIPS)
endif
ifneq ($(GO_TARGET_ARM),)
  GO_SUFFIX := $(GO_SUFFIX)-v$(GO_TARGET_ARM)
endif

RJPA_BIN ?= $(CURDIR)/prebuilt/rjpa-$(GO_SUFFIX)

# ---------------------------------------------------------------------------
# 这个包没有源码要编译：Go 二进制是提前交叉编译好、放进 prebuilt/ 的。
#
# 必须显式覆盖 Build/Compile。package.mk 的默认规则会去 $(PKG_BUILD_DIR)
# 里执行 `make`，而那个目录是空的，于是报：
#   make[3]: *** No targets specified and no makefile found.  Stop.
# ---------------------------------------------------------------------------
define Build/Compile
	true
endef

# 调试用: make -C package/... print-target 会打印期望的文件名
print-target:
	@echo "OpenWrt ARCH = $(ARCH)"
	@echo "Go 目标      = $(GO_SUFFIX)"
	@echo "期望二进制   = $(RJPA_BIN)"

# ===========================================================================
# 包 1: rjpa  (纯后台服务，不依赖 LuCI)
# ===========================================================================
define Package/rjpa
  SECTION:=net
  CATEGORY:=Network
  TITLE:=锐捷校园网 eportal 认证客户端
  URL:=https://github.com/
endef

define Package/rjpa/description
 锐捷 (eportal) 校园网自动认证客户端。支持自动探测认证地址、
 自动检测服务类型、断网自动重连，并提供 procd 服务与连接日志。
endef

define Package/rjpa/conffiles
/etc/config/rjpa
endef

define Package/rjpa/install
	@if [ ! -f "$(RJPA_BIN)" ]; then \
		echo ""; \
		echo "*** 找不到 Go 二进制: $(RJPA_BIN)"; \
		echo "*** 当前 OpenWrt ARCH = $(ARCH)，需要文件 rjpa-$(GO_SUFFIX)"; \
		echo "*** 请先编译:  ./build-go.sh $(GO_SUFFIX)           (Linux)"; \
		echo "***     或:    .\\build-go.ps1 -Target $(GO_SUFFIX)   (Windows)"; \
		echo ""; \
		exit 1; \
	fi
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(RJPA_BIN) $(1)/usr/bin/rjpa
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/rjpa $(1)/etc/config/rjpa
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/rjpa $(1)/etc/init.d/rjpa
endef

# ===========================================================================
# 包 2: luci-rjpa  (Lua 版 LuCI 界面)
#
#   luci-compat        提供 luci.cbi / 旧版 Lua 界面兼容层（必须有）
#   luci-lua-runtime   提供 luci.dispatcher / luci.template / lua / nixio
#
# 注意: 24.10 默认只装 JS 版 LuCI，这两个包通常需要额外安装，
#       写进 DEPENDS 后 opkg 会自动拉取（前提是路由器能访问软件源）。
# ===========================================================================
define Package/luci-rjpa
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI 支持 (锐捷校园网认证 / Lua)
  PKGARCH:=all
  # ⚠️ 这里**不能**写 luci-compat / luci-lua-runtime —— 加不加 + 都不行。
  #
  #   原因: SDK 里没有 luci feed，这两个包的 Kconfig 符号不存在。
  #   只要 DEPENDS 里出现它们，CONFIG_PACKAGE_luci-rjpa 就永远无法被选中；
  #   而 OpenWrt 只构建 .config 里被选中的包，见 25.12 的
  #   include/package-pack.mk:
  #       ifneq ($(CONFIG_PACKAGE_$(1))$(DEVELOPER),)
  #         IPKGS += $(1)
  #   于是本包被静默跳过：不报错、不产出，只在 scan 阶段留一条 WARNING。
  #
  #   代价: 装这个包时不会自动拉取 luci-compat / luci-lua-runtime，
  #         必须先手动装（安装说明里已写明这一步）。
  #
  #   想让依赖自动生效，正确做法是给 SDK 补 feeds:
  #       ./scripts/feeds update -a && ./scripts/feeds install -a
  #   然后就能把这两个包写回 DEPENDS。
  DEPENDS:=+rjpa
endef

define Package/luci-rjpa/description
 锐捷校园网认证客户端的 LuCI 界面（Lua 模板实现）：
 基本设置、服务类型检测、连接日志实时查看。
endef

define Package/luci-rjpa/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./luci-root/usr/lib/lua/luci/controller/rjpa.lua \
		$(1)/usr/lib/lua/luci/controller/rjpa.lua

	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi/rjpa
	$(INSTALL_DATA) ./luci-root/usr/lib/lua/luci/model/cbi/rjpa/config.lua \
		$(1)/usr/lib/lua/luci/model/cbi/rjpa/config.lua

	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/rjpa
	$(INSTALL_DATA) ./luci-root/usr/lib/lua/luci/view/rjpa/status.htm \
		$(1)/usr/lib/lua/luci/view/rjpa/status.htm
	$(INSTALL_DATA) ./luci-root/usr/lib/lua/luci/view/rjpa/log.htm \
		$(1)/usr/lib/lua/luci/view/rjpa/log.htm

	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./luci-root/usr/share/rpcd/acl.d/luci-rjpa.json \
		$(1)/usr/share/rpcd/acl.d/luci-rjpa.json
endef

define Package/luci-rjpa/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	# 清掉 LuCI 菜单索引缓存，让新页面立刻出现在菜单里
	rm -f /tmp/luci-indexcache /tmp/luci-indexcache.json 2>/dev/null
	rm -rf /tmp/luci-modulecache 2>/dev/null
}
exit 0
endef

$(eval $(call BuildPackage,rjpa))
$(eval $(call BuildPackage,luci-rjpa))
