package compiler

//we encounter an instruction.
//we need space for a register
//ask for a register, move 

import sa"core:container/small_array"
import "core:os"
import "core:fmt"
import "core:slice"

Register :: enum {
    rcx,
    rdx,
    rsi,
    rdi,
    r8,
    r9,
}

Stack_Offset :: int
Memory_Location :: union #no_nil{
    Register,
    Stack_Offset,
}

Register_Allocator :: struct {
    free_registers: sa.Small_Array(6, Register), //todo find a better way to deal with constant number
    free_stack_positions: [dynamic]Stack_Offset,
    register_to_temp: [Register]Temporary,
    temp_to_memory: map[Temporary]Memory_Location,
    next_stack_position: int,
}

Codegen_Context :: struct{
    ra: Register_Allocator,
    sp: ^Symbol_Pool,
    current_locals_size: int,
    fd: os.Handle,
    text_buffer: []byte,
}

save_temporary :: proc(using cc: ^Codegen_Context, temp: Temporary) -> Memory_Location{
    using ra
    //try register first
    if register, exists := sa.pop_back_safe(&free_registers); exists{
        register_to_temp[register] = temp
        temp_to_memory[temp] = register
        return register
    }

    //next see if we have any already allocated stack spots to use
    if stack_position, exists := pop_safe(&free_stack_positions); exists{
        temp_to_memory[temp] = stack_position
        return stack_position
    }

    //finally, we create more room on the stack
    temp_to_memory[temp] = next_stack_position
    defer next_stack_position += 8
    fmt.fprintfln(fd, "sub rsp, 8")
    return next_stack_position
}

free_temporary :: proc(using cc: ^Codegen_Context, temp: Temporary) {
    using ra
    _, location_union := delete_key(&temp_to_memory, temp) //this shouldnt be nessecary, but might catch a bug

    switch location in location_union {
        case Register:
            sa.push(&free_registers, location)
        case Stack_Offset:
            //this implies we are the last position on the stack so far
            //best to just move the stack pointer back
            if location == next_stack_position - 8 {
                fmt.fprintfln(fd, "sub rsp, 8")
            }else{
                append(&free_stack_positions, location)
            }
    }
}

require_register :: proc(using cc: ^Codegen_Context, temp: Temporary) -> Register{
    if register, exists := sa.pop_front_safe(&cc.ra.free_registers); exists{
        ra.register_to_temp[register] = temp
        ra.temp_to_memory[temp] = register
        return register
    }
    t_replaced := cc.ra.register_to_temp[.rcx]
    free_temporary(cc, t_replaced)
    temp_location := save_temporary(cc, temp)
    save_temporary(cc, t_replaced)

    return temp_location.(Register)
}



argument_to_asm :: proc(using cc: ^Codegen_Context, argument: Argument, free_temp := true) -> string{
    #partial switch arg in argument{
        case i64: return fmt.bprintf(text_buffer, "%d", arg)
        case Temporary:
            location_union := ra.temp_to_memory[arg]
            if free_temp do free_temporary(cc, arg)
            if register, in_register := location_union.(Register); in_register{
                return fmt.bprintf(text_buffer, "%s", register)
            }
            return fmt.bprintf(text_buffer, "[rbp - %d]", location_union.(Stack_Offset))
        case: unreachable()
    }
}

fasm_linux_generate :: proc(sp: ^Symbol_Pool, program: IR_Program) -> bool {
    fd, err := os.open("output.fasm", os.O_RDWR | os.O_CREATE | os.O_TRUNC, 0o777)
    if err != os.ERROR_NONE {
        fatal("Could not open output assembly file")
    }
    defer os.close(fd)

    cc := Codegen_Context{
        ra = {
            free_stack_positions = make([dynamic]Stack_Offset),
            temp_to_memory = make(map[Temporary]Memory_Location),
        },
        sp = sp,
        fd = fd,
        text_buffer = make([]byte, 1024),
    }
    for reg in Register{
        sa.push_back(&cc.ra.free_registers, reg)
    }
    defer {
        delete(cc.ra.free_stack_positions)
        delete(cc.ra.temp_to_memory)
        delete(cc.text_buffer)
    }

    fmt.fprintfln(fd, "format ELF64")
    fmt.fprintfln(fd, "section '.text' executable")
    fmt.fprintfln(fd, "public _start")
    fmt.fprintfln(fd, "_start:")
    fmt.fprintfln(fd, "call rover_main")
    fmt.fprintfln(fd, "mov rdi, rax")
    fmt.fprintfln(fd, "mov rax, 60")
    fmt.fprintfln(fd, "syscall")

    for inst in program{
        #partial switch inst.opcode{
            case .Function:
                symbol := pool_get(sp, inst.arg_1.(Symbol_ID))
                info := symbol.data.(Function_Info)
                fmt.fprintfln(fd, "rover_%s:", ident(symbol.name))
                fmt.fprintfln(fd, "push rbp")
                fmt.fprintfln(fd, "mov rbp, rsp")
                //keeps stack alligned, might not care about this in the future and just align it when talking to C
                locals_size := info.locals_size + (16 - (info.locals_size % 16))
                cc.current_locals_size = locals_size
                cc.ra.next_stack_position = locals_size
                fmt.fprintfln(fd, "sub rsp, %d", locals_size)
                fmt.fprintfln(fd, ";;--Preamble Over--")
            case .Add:
                result_location := require_register(&cc, inst.result.?)
                fmt.fprintfln(fd, "mov %s, %s", result_location, argument_to_asm(&cc, inst.arg_1))
                fmt.fprintfln(fd, "add %s, %s", result_location, argument_to_asm(&cc, inst.arg_2))
            case .Ret:
                fmt.fprintfln(fd, "mov rax, %s", argument_to_asm(&cc, inst.arg_1))
                fmt.fprintfln(fd, ";;Function Epilogue--")
                fmt.fprintfln(fd, "mov rsp, rbp")
                fmt.fprintfln(fd, "pop rbp")
                fmt.fprintfln(fd, "ret")
                    
        }
    }

    return true
}

