ROVERC_SOURCES = $(wildcard src/compiler/*.odin)
STDLIB_SOURCES = $(wildcard src/stdlib/*.odin)
SOURCE_FILE = programs/test.rv

roverc: $(ROVERC_SOURCES)
	odin build src/roverc -out:roverc

stdlib: $(STDLIB_SOURCES)
	odin build src/stdlib -build-mode:obj -out:stdlib.o -no-crt -default-to-nil-allocator

build: roverc stdlib $(SOURCE_FILE)
	./roverc $(SOURCE_FILE)
	fasm output.asm > /dev/null
	ld -o program output.o stdlib.o


#ld -o program output.o -L. -dynamic-linker /lib64/ld-linux-x86-64.so.2 -lc

run: build
	export LD_LIBRARY_PATH=.:$$LD_LIBRARY_PATH
	./program

clean:
	rm output.asm
	rm stdlib.o
	rm output.o
	rm roverc
	rm program