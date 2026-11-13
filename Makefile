# Makefile
# apprt - native application runtime for Crystal programs on Linux
# See LICENSE file for copyright and license details.
.POSIX:

CRYSTAL = crystal

all: spec

spec:
	$(CRYSTAL) spec --threads 2

# Regenerates src/apprt/c/*.cr from the GIR files and the allowlists in
# data/gir/ (see tools/gen_gir.cr).
gen:
	$(CRYSTAL) run tools/gen_gir.cr

# API documentation into docs/.
docs:
	$(CRYSTAL) docs src/apprt.cr -o docs

format:
	$(CRYSTAL) tool format src spec tools

clean:
	rm -rf docs bin .dev

.PHONY: all spec gen docs format clean
