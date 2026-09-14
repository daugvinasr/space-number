VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null | sed 's/^v//' || echo dev)
COMMIT  ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)

build/space-number: main.swift build/Version.swift
	swiftc -O $^ -o $@

build/Version.swift: FORCE | build
	@printf 'let appVersion = "%s"\nlet appCommit = "%s"\n' "$(VERSION)" "$(COMMIT)" > $@.tmp
	@cmp -s $@.tmp $@ || mv $@.tmp $@; rm -f $@.tmp

build:
	@mkdir -p build

clean:
	rm -rf build

.PHONY: clean FORCE
