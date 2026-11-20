# desktop-kit-test - live tests of desktop_kit on the KDE Plasma desktop
.POSIX:

CRYSTAL = crystal
CRFLAGS = --threads 2
# kde: the only mode whose desktop serves the global shortcuts portal;
# sway: a headless nested sway, for the cases that need no desktop
MODE = kde
# the names of the cases in cases.yml to run; empty: all of them
CASES =
# extra harness flags, such as -u to write the goldens or -S to show sway
ARGS =
# how the shards are fetched: "shards update" takes the local checkouts of
# shard.override.yml on every make, "shards install" keeps shard.lock
SHARDS = shards update

all: bin/desktop-kit-test bin/desktop-kit-under-test

bin/desktop-kit-test: src/main.cr src/desktop_kit/test/subject.cr bin/shard.lock bin/lib.stamp
	mkdir -p bin
	$(CRYSTAL) build $(CRFLAGS) src/main.cr -o $@

# the app the cases run; built from the desktop_kit in lib/
bin/desktop-kit-under-test: src/under_test.cr bin/shard.lock bin/lib.stamp
	mkdir -p bin
	$(CRYSTAL) build $(CRFLAGS) src/under_test.cr -o $@

# shard.lock of the last build; it changes only when the shards moved, so
# the binaries are rebuilt only then
bin/shard.lock: FORCE
	$(SHARDS)
	mkdir -p bin
	cmp -s shard.lock $@ || cp shard.lock $@

# touched when a source of the shards in lib/ is newer than the app under
# test, so changes in the local checkouts rebuild the binaries too
bin/lib.stamp: FORCE
	mkdir -p bin
	if [ ! -e $@ ] || [ ! -e bin/desktop-kit-under-test ] || \
	  [ -n "$$(find -L lib/*/src lib/*/data lib/*/shard.yml -newer bin/desktop-kit-under-test -print 2>/dev/null | head -n 1)" ]; \
	then touch $@; fi

# fetches the shards now (also part of every make)
shards:
	shards update

# lets bin/desktop-kit-test take window screenshots and makes the desktop grant
# the global shortcut (once per desktop; confirm the dialog, then press the
# shortcut)
setup: all
	bin/desktop-kit-test setup
	bin/desktop-kit-under-test --setup

# runs the cases; MODE=kde takes over the keyboard and the pointer
test: all
	bin/desktop-kit-test -m $(MODE) -b bin/desktop-kit-under-test $(ARGS) $(CASES)

spec: bin/shard.lock
	$(CRYSTAL) spec $(CRFLAGS)

docs: bin/shard.lock
	$(CRYSTAL) docs src/main.cr

clean:
	rm -rf bin lib shard.lock out docs

FORCE:

.PHONY: all shards setup test spec docs clean FORCE
