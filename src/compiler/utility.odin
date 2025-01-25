package compiler

import "core:fmt"
import "core:os"

last :: proc(arr: [dynamic]$T) -> ^T {
    return &arr[last_idx(arr)]
}

last_idx :: proc(arr: [dynamic]$T) -> int {
    return len(arr) - 1
}

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

dump_ir :: proc(ir: IR_Program, sp: ^Symbol_Pool) {
    print_argument :: proc(arg: Argument, sp: ^Symbol_Pool) {
        switch arg_val in arg{
            case Immediate: fmt.printf("%v ", arg_val)
            case Symbol_ID: 
                symbol := pool_get(sp, arg_val)
                fmt.printf("%v ", ident(symbol.name))
            case Temporary: fmt.printf("T%v ", arg_val)
            case Label: fmt.printf("Label: %v ", arg_val)
            case: fmt.printf("---")
        }
    }
    for inst in ir{
        if temp, exists := inst.result.?; exists do fmt.printf("T%d = ", temp)
        fmt.printf("%v ", inst.opcode)
        print_argument(inst.arg_1, sp)
        print_argument(inst.arg_2, sp)
        
        fmt.println()
    }
}