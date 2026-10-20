# tinyeyebreak: build and install.
SWIFT ?= swiftc
PREFIX ?= $(HOME)/.local
BINDIR := $(PREFIX)/bin

.PHONY: all clean install lint uninstall

all: tinyeyebreak

tinyeyebreak: tinyeyebreak.swift
	$(SWIFT) -O $< -o $@

install: all
	install -d $(BINDIR)
	install -m 0755 tinyeyebreak $(BINDIR)

uninstall:
	rm -f $(BINDIR)/tinyeyebreak

lint:
	swiftc -O -warnings-as-errors tinyeyebreak.swift -o /tmp/tinyeyebreak-lint
	swiftc -swift-version 6 -O -warnings-as-errors tinyeyebreak.swift -o /tmp/tinyeyebreak-lint6
	@awk 'length > 100 { print FNR": over 100 cols"; e = 1 } END { exit e }' tinyeyebreak.swift
	@echo "lint: clean (werror in both modes + column check)"

clean:
	rm -f tinyeyebreak
