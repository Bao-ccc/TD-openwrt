include $(TOPDIR)/rules.mk

PKG_NAME:=dae-box
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/hhCodingCat/dae-box.git
PKG_SOURCE_VERSION:=main

PKG_LICENSE:=GPL-3.0
PKG_MAINTAINER:=hhCodingCat

PKG_BUILD_DEPENDS:=golang/host
PKG_BUILD_PARALLEL:=1
PKG_USE_MIPS16:=0

GO_PKG:=github.com/hhCodingCat/dae-box/cmd/dae-box
GO_PKG_BUILD_PKG:=github.com/hhCodingCat/dae-box/cmd/dae-box
GO_PKG_LDFLAGS:=-s -w

include $(INCLUDE_DIR)/package.mk
include $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk

define Package/dae-box
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Routing and Redirection
  TITLE:=Next-Gen eBPF-Powered Hybrid Proxy Engine
  URL:=https://github.com/hhCodingCat/dae-box
  DEPENDS:=$(GO_ARCH_DEPENDS) +ca-bundle +kmod-sched-bpf +kmod-veth +kmod-xdp-sockets-diag
endef

define Package/dae-box/description
  Next-Gen eBPF-Powered Hybrid Proxy Engine combining dae kernel bypass,
  sing-box modern protocols, and Clash-compatible control plane.
endef

define Package/dae-box/install
	$(call GoPackage/Package/Install/Bin,$(PKG_INSTALL_DIR))
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/bin/dae-box $(1)/usr/bin/dae-box

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/dae-box $(1)/etc/config/dae-box

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/dae-box $(1)/etc/init.d/dae-box
endef

$(eval $(call GoPackage/Package/dae-box))
$(eval $(call BuildPackage,dae-box))
