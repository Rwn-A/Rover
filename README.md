# Rover
A small, procedural programming language that compiles to x86-64 assembly. Compatible with Linux only. Possibly partially compatible with MacOS but that is untested and I don't plan on supporting it. When not using libc the language produces static executables and has no runtime. The language is very much in development. Nothing is stable the semantics and syntax may change and that may not be immediately updated in the README. 

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

### A basic Hello, World!
```rust
fn main() {
    print("Hello, World!")
}
```
Since we can syscall directly on Linux the most basic hello world program in Rover is about 8kB.
Playing around with the linker I got it down to 4kB but I am not a linker expert and one could likely get it down much smaller. The executable produced is also statically linked.

**Remaining features will be undocumented until language matures.**

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

### Makefile

Edit the SOURCE_FILE variable on line 3 of the makefile to be the path to your rover file. Then...

```shell
make -s run #or make build if you dont want to run it yet
make -s clean
```

### Manually
Build steps currently change so frequently. This area will be unfinished for now.
