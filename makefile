ROVERC_SOURCES = $(wildcard src/compiler/*.odin)
SOURCE_FILE = programs/test.rv

roverc: $(ROVERC_SOURCES)
	odin build src/roverc -out:roverc

builtin: $(BUILTIN_SOURCES)
	fasm src/builtin/builtin.asm builtin.o > /dev/null

build: roverc builtin $(SOURCE_FILE)
	./roverc $(SOURCE_FILE)
	fasm output.asm > /dev/null
	ld -o program output.o builtin.o

build_gold: roverc builtin $(SOURCE_FILE)
	./roverc $(SOURCE_FILE)
	fasm output.asm > /dev/null
	gold -o program output.o builtin.o --strip-all -n -O3
	strip --remove-section=.note.gnu.gold-version program


libc_only: roverc $(SOURCE_FILE)
	./roverc $(SOURCE_FILE)
	fasm output.asm > /dev/null
	ld -o program output.o -L. -dynamic-linker /lib64/ld-linux-x86-64.so.2 -lc

run: build
	./program

clean:
	rm output.asm
	rm builtin.o
	rm output.o
	rm roverc
	rm program