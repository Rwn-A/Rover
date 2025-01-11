odin run src

compiled_succesfully=$?

if [ $compiled_succesfully -eq 0 ]; then
   fasm output.fasm

    ld output.o -o output -dynamic-linker /lib64/ld-linux-x86-64.so.2 -lc

    ./output
else
   echo "exiting..."
fi
