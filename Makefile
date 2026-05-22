# Top-level convenience targets.
#
#   make             — build dylib + cli
#   make dylib       — just the dylib (out: dylib/libyarm.dylib)
#   make cli         — just the rust binary (out: target/release/yarm)
#   make install     — install both into $(PREFIX) (default /opt/homebrew)
#   make uninstall   — remove
#   make dev-install — build, install under $(PREFIX), register LaunchAgent
#   make clean

PREFIX ?= /opt/homebrew

DYLIB_SRC := dylib/libyarm.dylib
DYLIB_DST := $(PREFIX)/lib/libyarm.dylib
CLI_SRC   := target/release/yarm
CLI_DST   := $(PREFIX)/bin/yarm
AGENT_TPL := agent/com.maxbridgland.yarm.plist

all: dylib cli

dylib:
	$(MAKE) -C dylib

cli:
	cargo build --release

install: all
	install -d $(PREFIX)/lib $(PREFIX)/bin $(PREFIX)/share/yarm
	install -m 0755 $(DYLIB_SRC) $(DYLIB_DST)
	install -m 0755 $(CLI_SRC)   $(CLI_DST)
	install -m 0644 $(AGENT_TPL) $(PREFIX)/share/yarm/

uninstall:
	rm -f $(DYLIB_DST) $(CLI_DST)
	rm -rf $(PREFIX)/share/yarm

dev-install: install
	$(CLI_DST) install

clean:
	$(MAKE) -C dylib clean
	cargo clean

.PHONY: all dylib cli install uninstall dev-install clean
