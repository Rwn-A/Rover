ROVERC_SOURCES = $(wildcard src/compiler/*.odin)
STDLIB_SOURCES = $(wildcard src/stdlib/*.odin)
SOURCE_FILE = programs/test.rv

roverc: $(ROVERC_SOURCES)
	odin build src/roverc -out:roverc

stdlib: $(STDLIB_SOURCES)
	odin build src/stdlib -build-mode:shared -out:libstd.so

build: roverc stdlib $(SOURCE_FILE)
	./roverc $(SOURCE_FILE)
	fasm output.asm > /dev/null
	ld -o program output.o -L. -lstd -dynamic-linker /lib64/ld-linux-x86-64.so.2 

run: build
	export LD_LIBRARY_PATH=.:$$LD_LIBRARY_PATH
	./program

clean:
	rm output.asm
	rm libstd.so
	rm output.o
	rm roverc
	rm program