odin run src

compiled_succesfully=$?

if [ $compiled_succesfully -eq 0 ]; then
   fasm output.fasm

    ld output.o

    ./a.out

    echo $?
else
   echo "exiting..."
fi
