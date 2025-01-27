# Rover
A small, procedural programming language that compiles to x86-64 assembly. Compatible with Linux only. When not using libc the language produces static executables and has no runtime. The language is very much in development. Nothing is stable the semantics and syntax may change and that may not be immediately updated in the README. 

## Language Features
Rover supports, or plans to support, a simple set of features similiar to a C.

Currently supported features include:
- Functions
- Local Variables Signed 64 bit, C-style strings, floats, byte
- Control Flow (If statements and while statements)
- Basic arithmetic (+, -, *, /)
- Pointers
- Structures
- Arrays (1 Dimensional)
- FFI* (Can call into C functions and access global variables from C)

_*FFI is not completely implemented, Rover types do not always align with C types and a certain amount of C functions that have lots of parameters or paramaters of certain types will not be called correctly._ 

I have no intention of adding optimizations to the compiler or to make the compiler capable of spotting most errors in the code. Type checking may be implemented but deeper semantic analysis likely will not.

## Feature Reference

### A basic Hello, World!
```rust
fn main() {
    print("Hello, World!")
}
```
Since we can syscall directly on Linux the most basic hello world program in Rover is about 1kB when using gold instead of ld.
Playing around with gold I got it down to just under 600B but I am not a linker expert and one could likely get it down much smaller.

### Variables
```rust
//to declare a variable, not initialized
x: int

//to assign a variable
x = 10

//or both
x: int = 10
```

### Builtin Types
```rust
int //8 bytes
float //8 bytes
byte //1 byte
cstring //8 bytes, same as C basically syntax sugar for &byte
```

### Pointers
```rust
x: int = 100 
b: &int = &x //B is now a pointer to x
c: int = ^b //c is now the dereferanced value of B (100)
```

### Control Flow
```rust
x: int = 0
if x == 0 {
    print("is zero")
}else{
    print("not zero")
}

while x < 10 {
    print("Less than 10")
    x = x + 1
}
```

### Arrays
Rover does not support multi-dimensional arrays or array of structures as of right now.
```rust
xs: [5]int = [1, 2, 3, 4, 5] //creates the array

//to access an element
xs.0
//or
idx: int = 2
xs.idx

//Unlike C this will NOT work
x: int = ^(&xs) //this does not equal 1 like expected

//instead you must explicitly cast the pointer like so
xptr: &int = &xs
x: int = ^xptr //x now contains 1
```

### Structs
Structs are aligned in accordance with the system V ABI. But the calling convention is not implemented. It is up to the programmer to determine if C expects the struct to be passed by referance or by value. Rover will pass by value unless explicitily passed by pointer.
```rust
struct Data {
    x: int,
    y: int,
    buffer: [5]byte,
}

fn get_buffer_idx(d: Data, idx: int) byte {
    return d.buffer.idx
}
```

### Functions
```rust
fn add(x: int, y: int) int {
    return x + y
}
```
Everything is passed by value to keep things simple. So if passing large arrays or structs one should explicitly pass by pointer.
**NOTE: Function return type currently only support non-compound types (No arrays, or structs)**

### Foreign Interface
Rover can call into C code, although not every C type is supported by Rover so not every function will work as expected. There is limited type checking in Rover so you can fudge alot of the types.

```rust
//stdout isnt really an int but a pointer to an 8 byte value is comparable 
//to what a file descriptor is
foreign stdout: &int,  

//Rover has no var args so change what printf expects to suite your needs
foreign fn printf(cstring, int) 
foreign fn fflush(&int)

fn main() {
    x: int = 10
    printf("Hello, World! %d", x)
    fflush(stdout) //No C runtime to flush stdout for you
}
```

### Builtin Functions
Right now only `print` is built in. A wrapper for the function is written in assembly and linked to the program. The print function only uses the write syscall and thus the builtin functions dont rely on Libc.


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
