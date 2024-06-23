set -xe

odin build src -out:out/rover
./out/rover ./rover_programs/test.rover
fasm ./out/output.fasm
fasm ./out/runtime.fasm
ld ./out/*.o -o ./out/my_program