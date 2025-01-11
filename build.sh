odin build src/roverc -out:./build_artifacts/roverc

cd build_artifacts

./roverc ../programs/test.rv

compiled_succesfully=$?

if [ $compiled_succesfully -eq 0 ]; then
   fasm output.fasm

   ld output.o -o output -dynamic-linker /lib64/ld-linux-x86-64.so.2 -lc

   ./output
else
   echo "exiting..."
fi

# For linking to other non-libc code
#gcc -c -fPIC -o testing.o testing.c
#ld -shared -soname libtesting.so -o libtesting.so testing.o
#ld -o myprogram output.o -L. -ltesting -dynamic-linker /lib64/ld-linux-x86-64.so.2 -lc
#export LD_LIBRARY_PATH=.:$LD_LIBRARY_PATH