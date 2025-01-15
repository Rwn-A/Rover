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

dump_ir :: proc(ir: IR_Program) {
    print_argument :: proc(arg: Argument) {
        switch arg_val in arg{
            case Immediate: fmt.printf("%v ", arg_val)
            case Symbol_ID: fmt.printf("S%v ", arg_val)
            case Temporary: fmt.printf("T%v ", arg_val)
            case Label: fmt.printf("L%v ", arg_val)
            case: fmt.printf("---")
        }
    }
    for inst in ir{
        if temp, exists := inst.result.?; exists do fmt.printf("T%d = ", temp)
        fmt.printf("%v ", inst.opcode)
        print_argument(inst.arg_1)
        print_argument(inst.arg_2)
        
        fmt.println()
    }
}