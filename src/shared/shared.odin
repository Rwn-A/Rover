package shared

import "core:fmt"
import "core:os"

Rover_Location :: struct {
    row: int,
    col: int,
    filepath: string
}


//error would be for an error in the rover source file
rover_error :: proc(fmt_str: string, source_loc: Rover_Location, args: ..any) {
    fmt.eprintf("%s:%d:%d Error: ", source_loc.filepath, source_loc.row, source_loc.col)
    fmt.eprintfln(fmt_str, ..args)
}

//fatal would be an error in the compiler program, or an error before the source file is ready
//this exits the program so it can leak memory but "let it leak".
rover_fatal :: proc(fmt_str: string, args: ..any) {
    fmt.printf("Fatal Error: ")
    fmt.printfln(fmt_str, ..args)
    os.exit(1)
}

//info is for info on compilation stages, would be handy for debugging
rover_info :: proc(fmt_str: string, args: ..any) {
    fmt.printf("Info: ")
    fmt.printfln(fmt_str, ..args)
    os.exit(1)
}