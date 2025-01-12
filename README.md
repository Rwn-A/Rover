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

## How Was This Built
I have attempted and failed to build a few languages in the past. From concatenative languages to a language
similiar to this one. As a result, the lexer and parser are adapted from those. The lexer is handmade but its not particularly interesting.
Also, the parser is handmade but the expression parsing borrows some logic from the [Writing an Interpreter in Go](https://interpreterbook.com/) book.
In my past languages, I used a stack based IR. This was easy to generate for simple features but was a pain to translate into nice assembly.
The big change for this language was to use a Three-Adress-Code IR. I don't know if there is a technical definition for a TAC IR, if there is,
my IR likely does not follow it. The IR is close enough to assembly to make translation easier especially for more complicated language features.
I decided to generate assembly because I feel like it offered the most learning, and LLVM scares me. Using FASM instead of the more popular NASM was a decision made by [Tsoding](https://github.com/tsoding) for his language. He also inspired the earlier stack-based versions of this language.


## Installation
Although this language is not really meant to be used by anyone, I will still put the installation
instructions below.

[fasm](https://flatassembler.net/) and [odin](https://odin-lang.org) are required so install them first.

**I recomend using the makefile until the build process is ironed out!**

### Makefile

Edit the SOURCE_FILE variable on line 3 of the makefile to be the path to your rover file. Then...

```shell
make -s run #or make build if you dont want to run it yet
make -s clean
```

### Manually

To compile the compiler.
```shell
git clone https://github.com/Rwn-A/Rover

odin build Rover/src/roverc -out:roverc
odin build Rover/src/stdlib -build-mode:shared -out:libstd.so
```

Next create a rover file ending with `.rv`.
```shell
touch main.rv
```

Add the below "Hello, World!" code to the file.
```rust
fn main() {
    print("Hello, World!")
}
```

Next we need to compile our source file into fasm, create an object file with fasm and then link.
```shell
roverc main.rv

fasm output.asm

ld output.o -o my_program -lstd -dynamic-linker /lib64/ld-linux-x86-64.so.2 #add -lc if using libc

export LD_LIBRARY_PATH=.:$LD_LIBRARY_PATH
```

**Note:** *As of right now building the standard library is required, it only contains a single print function for a nice hello application. As time goes on this will be refined and the build process will not be so strange. Eventually, the standard library will be a Rover file that calls into a Odin library instead of just a shared object directly in Odin.*

When run you should see `Hello, World!` printed to the console.

