# apprt-test - live tests of apprt on the KDE Plasma desktop
.POSIX:

CRYSTAL = crystal
CRFLAGS = --threads 2
# kde: the only mode whose desktop serves the global shortcuts portal
MODE = kde
# the names of the cases in cases.yml to run; empty: all of them
CASES =
# how the shards are fetched: "shards update" takes the local checkouts of
# shard.override.yml on every make, "shards install" keeps shard.lock
SHARDS = shards update

all: bin/apprt-test bin/apprt-under-test

bin/apprt-test: src/main.cr src/apprt/test/subject.cr bin/shard.lock bin/lib.stamp
	mkdir -p bin
	$(CRYSTAL) build $(CRFLAGS) src/main.cr -o $@

# the app the cases run; built from the apprt in lib/
bin/apprt-under-test: src/under_test.cr bin/shard.lock bin/lib.stamp
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
	if [ ! -e $@ ] || [ ! -e bin/apprt-under-test ] || \
	  [ -n "$$(find -L lib/*/src lib/*/data lib/*/shard.yml -newer bin/apprt-under-test -print 2>/dev/null | head -n 1)" ]; \
	then touch $@; fi

# fetches the shards now (also part of every make)
shards:
	shards update

# lets bin/apprt-test take window screenshots and makes the desktop grant
# the global shortcut (once per desktop; confirm the dialog, then press the
# shortcut)
setup: all
	bin/apprt-test setup
	bin/apprt-under-test --setup

# runs the cases; MODE=kde takes over the keyboard and the pointer
test: all
	bin/apprt-test -m $(MODE) -b bin/apprt-under-test $(CASES)

spec: bin/shard.lock
	$(CRYSTAL) spec $(CRFLAGS)

docs: bin/shard.lock
	$(CRYSTAL) docs src/main.cr

clean:
	rm -rf bin lib shard.lock out docs

FORCE:

.PHONY: all shards setup test spec docs clean FORCE
