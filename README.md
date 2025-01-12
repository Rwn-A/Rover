# Rover
A small, procedural programming language that compiles to x86-64 assembly. Compatible with Linux only. Possibly partially compatible with MacOS but that is untested and I don't plan on supporting it. The language is very much in development. Nothing is stable the semantics and syntax may change and that may not be immediately updated in the README.

## Language Features
Rover supports, or plans to support, a simple set of features similiar to a C.

Currently supported features include:
- Functions
- Local Variables (Signed 64-bit integers and C-style strings only right now)
- Control Flow (If statements and while statements)
- Basic arithmetic (+, -, *, /)
- Pointers
- FFI* (Can call into C functions and access global variables from C)

_*FFI is not completely implemented, Rover types do not always align with C types and a certain amount of C functions that have lots of parameters or paramaters of certain types will not be called correctly._ 

Planned features include:
- Support for floating point numbers and single byte values
- Structures, Arrays and Slices
- Importing other source files
- More robust FFI, (Not aiming for complete compatibility with C but good for most functions)
- Type Checking in the Compiler
- For Loops
- Enums and Unions
- Macros, Generics or some other kind of compile time code execution

I have no intention of adding optimizations to the compiler or to make the compiler capable of spotting most errors in the code. Type checking may be implemented but deeper semantic analysis likely will not.

## Feature Referance
Shows an example of the different language features. Will not be updated until language is more matute.
## Installation
Although this language is not really meant to be used by anyone, I will still put the installation
instructions below.

[fasm](https://flatassembler.net/) and [odin](https://odin-lang.org) are required so install them first.

To compile the compiler.
```shell
git clone https://github.com/Rwn-A/Rover

odin build Rover/src/roverc -out:roverc
```

Next create a rover file ending with `.rv`.
```shell
touch main.rv
```

Add the below "Hello, World!" code to the file.
```rust
foreign fn puts(cstring, &int);
foreign stdout: &int;

fn main() {
    puts("Hello, World!", stdout)
}
```

Next we need to compile our source file into fasm, create an object file with fasm and then link.
```shell
roverc main.rv

fasm output.asm

ld output.o -o my_program -dynamic-linker /lib64/ld-linux-x86-64.so.2 -lc
```

**Note:** *If one is not using libc or any foreign code that depends on it the ld command can be shortend to:* `ld output.o -o my_program`

When run you should see `Hello, World!` printed to the console.

