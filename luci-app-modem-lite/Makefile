#
# luci-app-modem-lite: LuCI page and helper for a USB LTE modem driven over AT
# commands (APN, signal, data call, SMS, Slack forwarding).
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-modem-lite
PKG_VERSION:=1.0.0
PKG_RELEASE:=2
PKG_LICENSE:=GPL-2.0-only

LUCI_TITLE:=Mobile modem settings, signal and SMS (lite)
LUCI_DESCRIPTION:=APN, PIN and data-call management, signal status and LEDs, \
	SMS inbox/send and forwarding to Slack for AT-command USB modems such as \
	the Quectel EC200A. Uses sms-tool for all modem I/O.
LUCI_DEPENDS:=+luci-base +sms-tool +uclient-fetch +ca-bundle
LUCI_PKGARCH:=all

define Package/luci-app-modem-lite/conffiles
/etc/config/modem-lite
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
