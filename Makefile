PREFIX   ?= /usr
SBINDIR  ?= $(PREFIX)/sbin
CONFDIR  ?= /etc
DESTDIR  ?=

VERSION  := $(shell sed -n 's/^readonly VERSION="\(.*\)"/\1/p' be-btrfs.sh)
PKG_NAME := be-btrfs
PKG_ARCH := all

# --- Install / Uninstall ---

.PHONY: install uninstall deb apk clean

install:
	install -Dm755 be-btrfs.sh    $(DESTDIR)$(SBINDIR)/be-btrfs
	install -Dm644 be-btrfs.conf  $(DESTDIR)$(CONFDIR)/be-btrfs.conf
	install -Dm644 misc/be-btrfs-completion.bash \
	    $(DESTDIR)$(CONFDIR)/bash_completion.d/be-btrfs
	install -Dm644 misc/_be-btrfs \
	    $(DESTDIR)$(PREFIX)/share/zsh/vendor-completions/_be-btrfs
	install -Dm644 misc/be-btrfs.fish \
	    $(DESTDIR)$(PREFIX)/share/fish/vendor_completions.d/be-btrfs.fish
	install -d $(DESTDIR)$(CONFDIR)/apt/apt.conf.d
	sed 's|@bindir@|$(SBINDIR)|g' misc/90-boot-environments.conf.in \
	    > $(DESTDIR)$(CONFDIR)/apt/apt.conf.d/90-boot-environments.conf

uninstall:
	rm -f $(DESTDIR)$(SBINDIR)/be-btrfs
	rm -f $(DESTDIR)$(CONFDIR)/be-btrfs.conf
	rm -f $(DESTDIR)$(CONFDIR)/bash_completion.d/be-btrfs
	rm -f $(DESTDIR)$(PREFIX)/share/zsh/vendor-completions/_be-btrfs
	rm -f $(DESTDIR)$(PREFIX)/share/fish/vendor_completions.d/be-btrfs.fish
	rm -f $(DESTDIR)$(CONFDIR)/apt/apt.conf.d/90-boot-environments.conf

# --- .deb package (dpkg-deb) ---

DEB_DIR  := build/deb/$(PKG_NAME)_$(VERSION)_$(PKG_ARCH)
DEB_FILE := build/$(PKG_NAME)_$(VERSION)_$(PKG_ARCH).deb

deb:
	rm -rf $(DEB_DIR)
	$(MAKE) install DESTDIR=$(DEB_DIR)
	install -d $(DEB_DIR)/DEBIAN
	sed -e 's/@VERSION@/$(VERSION)/g' \
	    -e 's/@ARCH@/$(PKG_ARCH)/g' \
	    pkg/debian/control.in > $(DEB_DIR)/DEBIAN/control
	cp pkg/debian/conffiles $(DEB_DIR)/DEBIAN/conffiles
	dpkg-deb --root-owner-group --build $(DEB_DIR) $(DEB_FILE)
	@echo "Built: $(DEB_FILE)"

# --- Alpine .apk package (abuild) ---

APK_SRCDIR := build/apk

apk:
	rm -rf $(APK_SRCDIR)
	install -d $(APK_SRCDIR)
	sed 's/@VERSION@/$(VERSION)/g' pkg/alpine/APKBUILD.in > $(APK_SRCDIR)/APKBUILD
	tar czf $(APK_SRCDIR)/$(PKG_NAME)-$(VERSION).tar.gz \
	    --transform='s,^,$(PKG_NAME)-$(VERSION)/,' \
	    be-btrfs.sh be-btrfs.conf misc/ Makefile
	cd $(APK_SRCDIR) && abuild checksum && abuild -rd
	@echo "APK built (check ~/packages/)"

# --- Clean ---

clean:
	rm -rf build/
