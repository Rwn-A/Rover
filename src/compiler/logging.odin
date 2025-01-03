package compiler

import "core:fmt"
import "core:os"

//used for errors in the compiler.
fatal :: proc(fmt_str: string, args: ..any){
    fmt.printf("Fatal Error: ")
    fmt.printfln(fmt_str, ..args)
    os.exit(1)
}

//error would be for an error in the source file
error :: proc(fmt_str: string, source_loc: File_Location, args: ..any) {
    fmt.eprintf("%s:%d:%d Error: ", source_loc.filepath, source_loc.row, source_loc.col)
    fmt.eprintfln(fmt_str, ..args)
}