# Rover
A small, procedural programming language that compiles to x86-64 assembly.
Remaining documentation will remain unfinished until a working build exists.

TODO:
    size_of_first local implementation
    how params are handled in IR, and symbol table, needs to be streamlined
    attempt to adhere to C calling convention
    can always add param instruction somehow
    current idea, treat param like local variable
    function header in assembky copies them to their spot
    trying to adhere to the C calling convention.