# Makefile
# apprt - native application runtime for Crystal programs on Linux
# See LICENSE file for copyright and license details.
.POSIX:

CRYSTAL = crystal

all: spec

# All specs. The GTK specs start a private headless sway and dbus-daemon.
spec:
	$(CRYSTAL) spec --threads 2

# Specs that need neither a display nor a bus.
spec-pure:
	$(CRYSTAL) spec spec/pure --threads 2

spec-gtk:
	$(CRYSTAL) spec spec/gtk --threads 2

# Regenerates src/apprt/c/*.cr from the GIR files and the allowlists in
# data/gir/ (see tools/gen_gir.cr).
gen:
	$(CRYSTAL) run tools/gen_gir.cr

# Builds the examples into bin/.
examples:
	mkdir -p bin
	$(CRYSTAL) build --threads 2 examples/hello.cr -o bin/hello
	$(CRYSTAL) build --threads 2 examples/canvas.cr -o bin/canvas
	$(CRYSTAL) build --threads 2 examples/ipc.cr -o bin/ipc

# API documentation into docs/.
docs:
	$(CRYSTAL) docs src/apprt.cr -o docs

format:
	$(CRYSTAL) tool format src spec tools examples

clean:
	rm -rf docs bin .dev

.PHONY: all spec spec-pure spec-gtk gen examples docs format clean
