package compiler

import sa"core:container/small_array"
import "core:os"
import "core:fmt"
import "core:strings"
import "core:slice"

Register :: enum {
    rax,
    rdi,
    rsi,
    rcx,
    rdx,
    r8,
    r9,
}

Asm_Size :: enum {
    QWORD = 8,
    DWORD = 4,
    WORD = 2,
    BYTE = 1,
}

Stack_Offset :: int
Temporary_Location :: union #no_nil{
    Register,
    Stack_Offset,
}

Register_Allocator :: struct {
    free_registers: sa.Small_Array(6, Register),
    free_stack_positions: [dynamic]Stack_Offset,
    register_to_temp: [Register]Temporary,
    temp_to_memory: map[Temporary]Temporary_Location,
    next_stack_position: int,
}

Codegen_Context :: struct{
    ra: Register_Allocator,
    sp: ^Symbol_Pool,
    fd: os.Handle,
    text_buffer: []byte,
    defined_externals: [dynamic]string,
    defined_strings: [dynamic]string,
}

@(private="file")
save_temporary :: proc(using cc: ^Codegen_Context, temp: Temporary) -> (Temporary_Location, bool){
    using ra
    //try register first
    if register, exists := sa.pop_front_safe(&free_registers); exists{
        register_to_temp[register] = temp
        temp_to_memory[temp] = register
        return register, true
    }

    //next see if we have any already allocated stack spots to use
    if stack_position, exists := pop_safe(&free_stack_positions); exists{
        temp_to_memory[temp] = stack_position
        return stack_position, false
    }

    //finally, we create more room on the stack
    temp_to_memory[temp] = next_stack_position
    defer next_stack_position += 8
    fmt.fprintfln(fd, "sub rsp, 8")
    return next_stack_position, false
}

@(private="file")
free_temporary :: proc(using cc: ^Codegen_Context, temp: Temporary) {
    using ra
    _, location_union := delete_key(&temp_to_memory, temp) //this shouldnt be nessecary, but might catch a bug

    switch location in location_union {
        case Register: sa.push_front(&free_registers, location)
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

@(private="file")
temp_require_register :: proc(using cc: ^Codegen_Context, temp: Temporary) -> Register{
    if register, exists := sa.pop_front_safe(&cc.ra.free_registers); exists{
        ra.register_to_temp[register] = temp
        ra.temp_to_memory[temp] = register
        return register
    }
    t_replaced := cc.ra.register_to_temp[.rcx]
    free_temporary(cc, t_replaced)
    temp_location, _ := save_temporary(cc, temp)
    save_temporary(cc, t_replaced)

    return temp_location.(Register)
}


x86_64_linux_fasm :: proc(sp: ^Symbol_Pool, program: IR_Program) {
    //Context Initialization
    fd, err := os.open("output.asm", os.O_RDWR | os.O_CREATE | os.O_TRUNC, 0o777)
    if err != os.ERROR_NONE {
        fatal("Could not open output assembly file")
    }
    defer os.close(fd)

    cc := Codegen_Context{
        ra = {
            free_stack_positions = make([dynamic]Stack_Offset),
            temp_to_memory = make(map[Temporary]Temporary_Location),
        },
        sp = sp,
        fd = fd,
        text_buffer = make([]byte, 1024),
        defined_externals = make([dynamic]string),
        defined_strings = make([dynamic]string),
    }
    
    defer {
        delete(cc.ra.free_stack_positions)
        delete(cc.ra.temp_to_memory)
        delete(cc.text_buffer)
        delete(cc.defined_externals)
        delete(cc.defined_strings)
    }

    for reg in Register{
        if reg == .rax do continue
        sa.push_back(&cc.ra.free_registers, reg)
    }

    //Begin codegen
    write_asm_header(&cc)

    for inst in program{
        switch inst.opcode{
            case .Function: write_function_header(&cc, inst)
            case .LoadW, .LoadB: write_load(&cc, inst)
            case .StoreB, .StoreW: write_store(&cc, inst)
            case .Addr_Of: write_addr_of(&cc, inst)
            case .Offset: write_offset(&cc, inst)
            case .Ret: write_return(&cc, inst.arg_1)
            case .Call: write_call(&cc, inst)
            case .Sub, .Add: write_sum(&cc, inst)
            case .SubF, .AddF: write_sum_float(&cc, inst)
            case .Mul: write_mul(&cc, inst)
            case .Div: write_div(&cc, inst)
            case .DivF, .MulF: write_prod_float(&cc, inst)
            case .Eq, .Lt, .Nq, .Le, .Gt, .Ge: write_comparison(&cc, inst)
            case .EqF, .LtF, .NqF, .LeF, .GtF, .GeF: write_comparison_float(&cc, inst)
            case .Jz: write_jz(&cc, inst)
            case .Jmp: fmt.fprintfln(fd, "jmp %s", label_str(&cc, inst.arg_1))
            case .Label: fmt.fprintfln(fd, "%s:", label_str(&cc, inst.arg_1))
            case .Arg: fmt.fprintfln(fd, "push %s", arg_str(&cc, inst.arg_1, true))
        }
        free_all(context.temp_allocator)
    }

    //write data section
    if len(cc.defined_strings) > 0 do fmt.fprintfln(fd, "section '.data' writeable")
    for str, i in cc.defined_strings{
        fmt.fprintfln(fd, "str%d: db \'%s\',0", i, str)
    }

}

@(private="file")
write_asm_header :: proc(using cc: ^Codegen_Context) {
    fmt.fprintfln(fd, "format ELF64")
    fmt.fprintfln(fd, "section '.text' executable")
    fmt.fprintfln(fd, "public _start")
    fmt.fprintfln(fd, "_start:")
    fmt.fprintfln(fd, "call rover_main")
    fmt.fprintfln(fd, "mov rdi, 0")
    fmt.fprintfln(fd, "mov rax, 60")
    fmt.fprintfln(fd, "syscall")
}

@(private="file")
write_function_header :: proc(using cc: ^Codegen_Context, inst: Instruction) {
    symbol := pool_get(sp, inst.arg_1.(Symbol_ID))
    info := symbol.data.(Function_Info)
    fmt.fprintfln(fd, "rover_%s:", ident(symbol.name))
    fmt.fprintfln(fd, "push rbp")
    fmt.fprintfln(fd, "mov rbp, rsp")

    //keeps stack alligned, might not care about this in the future and just align it when talking to C
    locals_size := info.locals_size + (16 - (info.locals_size % 16))

    //set up the stack
    cc.ra.next_stack_position = locals_size + 8
    fmt.fprintfln(fd, "sub rsp, %d", locals_size)

    //load params
    offset := 16
    for param_id in info.param_ids{
        param := pool_get(sp, param_id)
        param_info := param.data.(Local_Info)
        write_param_load(cc, &param_info.address, param_info.type, &offset)
    }
}

@(private="file")
write_param_load :: proc(using cc: ^Codegen_Context, s_offset: ^int, type: Type_Info, l_offset: ^int) {
    if is_simple_type(type) {
        qualifer := Asm_Size(type.size)
        register := "rax" if type.size == 8 else "al"
        fmt.fprintfln(fd, "mov rax, QWORD [rbp + %d]", l_offset^)
        fmt.fprintfln(fd, "mov %s [rbp - %d], %s", qualifer, s_offset^, register)
        l_offset^ += 8
        return
    }
    #partial switch info in type.data{
        case Type_Info_Array:
            if !is_simple_type(info.element_type^) do write_param_load(cc, s_offset, info.element_type^, l_offset)
            length := type.size / info.element_type.size
            stack_size := length * 8 //byte arrays are promoted to full words when passing
            l_offset^ += stack_size - 8
            for i in 0..<length {
                write_param_load(cc, s_offset, info.element_type^, l_offset)
                s_offset^ -= type.size
                l_offset^ -= 16
            }
            l_offset^ += stack_size + 8
        case Type_Info_Struct:
           s_offset^ -= type.size - info.field_types[0].size
           for field, i in info.field_types {
                s_offset^ += info.field_offsets[i]
                if !is_simple_type(field) do write_param_load(cc, s_offset, field, l_offset)
                write_param_load(cc, s_offset, field, l_offset)
                s_offset^ -= info.field_offsets[i]


           }

        case: unimplemented()
    }

}

@(private="file")
write_load :: proc(using cc: ^Codegen_Context, inst: Instruction) {
    location, in_register := save_temporary(cc, inst.result.?)
    location_str := temporary_str(cc, inst.result.?)
    size := 8 if inst.opcode == .LoadW else 1
    mov_inst := "mov" if size == 8 else "movzx"
    #partial switch arg in inst.arg_1{
        case Temporary:
            defer free_temporary(cc, arg)
            address_register: Register
            if register, in_register := cc.ra.temp_to_memory[arg].(Register); in_register{
                address_register = register
            }else{
                fmt.fprintfln(fd, "mov rax, %s", temporary_str(cc, arg))
                address_register = .rax
            }
            qualifier: Asm_Size = .QWORD if size == 8 else .BYTE
            if in_register{
                fmt.fprintfln(fd, "%s %s, %s [%s]", mov_inst, location_str, qualifier, address_register)
            }else{
                fmt.fprintfln(fd, "%s rax, %s [%s]", mov_inst, location_str, qualifier, address_register)
                fmt.fprintfln(fd, "mov %s, rax", location_str)
            }
        case Symbol_ID:
            if in_register{
                fmt.fprintfln(fd, "%s %s, %s",mov_inst, location_str, symbol_str(cc, arg))
            }else{
                fmt.fprintfln(fd, "%s rax, %s", mov_inst, symbol_str(cc, arg))
                fmt.fprintfln(fd, "mov %s, rax", location_str)
            }    
        case: panic("Tried to load from a non-loadable operand")
    }
}

@(private="file")
write_store :: proc(using cc: ^Codegen_Context, inst: Instruction) {
    value_operand := arg_str(cc, inst.arg_2)

    size := 8 if inst.opcode == .StoreW else 1
    
    //cannot mov, addr, addr so if value is an address we will move to rax
    if temp, is_temp := inst.arg_2.(Temporary); is_temp{
        defer free_temporary(cc, temp) //since store creates no new temporaries this is fine to do early
        location := cc.ra.temp_to_memory[temp]
        if offset, on_stack := location.(Stack_Offset); on_stack{
            fmt.fprintfln(fd, "mov rax, %s", temporary_str(cc, temp))
            value_operand = "rax" if size == 8 else "al"
        }else{
            value_operand = register_string(location.(Register), size)
        }
    }else if _, is_float := inst.arg_2.(Immediate).(f64); is_float {
        fmt.fprintfln(fd, "movq rax, xmm2")
        value_operand = "rax"
    }

    #partial switch arg in inst.arg_1{
        case Temporary:
            address_register: string
            defer free_temporary(cc, arg)
            
            register, in_register := cc.ra.temp_to_memory[arg].(Register)
            if in_register{
                address_register = register_string(register, 8)
            }else{
                fmt.fprintfln(fd, "push rbx")
                fmt.fprintfln(fd, "mov rbx, %s", temporary_str(cc, arg))
                address_register = "rbx"
            }
            qualifier: Asm_Size = .QWORD if size == 8 else .BYTE
            fmt.fprintfln(fd, "mov %s [%s], %s", qualifier, address_register, value_operand)
            if !in_register do fmt.fprintfln(fd, "pop rbx")
        case Symbol_ID:
            fmt.fprintfln(fd, "mov %s, %s", symbol_str(cc, arg), value_operand)
        case: panic("Tried to store to a non-loadable operand")
    }
}

@(private="file")
write_addr_of :: proc(using cc: ^Codegen_Context, inst: Instruction) {
    result := temp_require_register(cc, inst.result.?)
    fmt.fprintfln(fd, "lea %s, %s", result, symbol_str(cc, inst.arg_1, true))
}

@(private="file")
write_offset :: proc(using cc: ^Codegen_Context, inst: Instruction) {
    result, in_register := save_temporary(cc, inst.result.?)
    from := temporary_str(cc, inst.arg_1, false)
    offset := immediate_str(cc, inst.arg_2)
    register := result.(Register) if in_register else .rax
    fmt.fprintfln(fd, "mov %s, %s", register, from)
    fmt.fprintfln(fd, "add %s, %s", register, offset)
    if !in_register do fmt.fprintfln(fd, "mov %s, rax", from)
}

@(private="file")
write_sum :: proc(using cc: ^Codegen_Context, inst: Instruction) {
    result_location := temp_require_register(cc, inst.result.?)
    fmt.fprintfln(fd, "mov %s, %s", result_location, arg_str(cc, inst.arg_1, true))
    if inst.opcode == .Sub{
        fmt.fprintfln(fd, "sub %s, %s", result_location, arg_str(cc, inst.arg_2, true))
    }else{
        fmt.fprintfln(fd, "add %s, %s", result_location, arg_str(cc, inst.arg_2, true))
    }
}

@(private="file")
write_mul :: proc(using cc: ^Codegen_Context, inst: Instruction) {
    result_location := temp_require_register(cc, inst.result.?)
    fmt.fprintfln(fd, "mov rax, %s", arg_str(cc, inst.arg_1, true))
    fmt.fprintfln(fd, "imul %s, rax, %s", result_location, arg_str(cc, inst.arg_2, true))
}

@(private="file")
write_div :: proc(using cc: ^Codegen_Context, inst: Instruction) {
    result_location, _ := save_temporary(cc, inst.result.?)
    
    //could move other temps around and free one of the other registers
    fmt.fprintfln(fd, "push rbx") 
    fmt.fprintfln(fd, "push rdx")

    fmt.fprintfln(fd, "mov rax, %s", arg_str(cc, inst.arg_1, true))
    fmt.fprintfln(fd, "cqo")
    if num, is_num := inst.arg_2.(Immediate); is_num{
        value: i64 = ---
        if val, is_int := num.(i64); is_int do value = i64(val)
        if val, is_byte := num.(byte); is_byte do value = i64(val)
        //rdx already needs to be saved because the remainder goes here
        //so we can use it
        fmt.fprintfln(fd, "mov rbx, %d", value) 
        fmt.fprintfln(fd, "idiv rbx")

    }else{  
        fmt.fprintfln(fd, "idiv %s", arg_str(cc, inst.arg_2, true))
    }
    fmt.fprintfln(fd, "pop rbx") 
    fmt.fprintfln(fd, "pop rdx")


    fmt.fprintfln(fd, "mov %s, rax", result_location)
}
        
@(private="file")
write_comparison :: proc(using cc: ^Codegen_Context, inst: Instruction) {
    result_location := temp_require_register(cc, inst.result.?)
    fmt.fprintfln(fd, "mov %s, %s", result_location, arg_str(cc, inst.arg_1, true))
    fmt.fprintfln(fd, "cmp %s, %s", result_location, arg_str(cc, inst.arg_2, true))
    #partial switch inst.opcode{
        case .Eq: fmt.fprintfln(fd, "sete %s", register_8_bit(result_location))
        case .Nq: fmt.fprintfln(fd, "setne %s", register_8_bit(result_location))
        case .Lt: fmt.fprintfln(fd, "setl %s", register_8_bit(result_location))
        case .Gt: fmt.fprintfln(fd, "setg %s", register_8_bit(result_location))
        case .Le: fmt.fprintfln(fd, "setle %s", register_8_bit(result_location))
        case .Ge: fmt.fprintfln(fd, "setge %s", register_8_bit(result_location))
        case: panic("unreachable")
    }
    fmt.fprintfln(fd, "movzx %s, %s", result_location, register_8_bit(result_location))
}

@(private="file")
write_comparison_float :: proc(using cc: ^Codegen_Context, inst: Instruction) {
    result_location := temp_require_register(cc, inst.result.?)
    fmt.fprintfln(fd, "movq xmm0, %s", arg_str(cc, inst.arg_1, true))
    fmt.fprintfln(fd, "movq xmm1, %s", arg_str(cc, inst.arg_2, true))
    fmt.fprintfln(fd, "ucomisd xmm0, xmm1")
    #partial switch inst.opcode{
        case .EqF: fmt.fprintfln(fd, "sete %s", register_8_bit(result_location))
        case .NqF: fmt.fprintfln(fd, "setne %s", register_8_bit(result_location))
        case .LtF: fmt.fprintfln(fd, "setnae %s", register_8_bit(result_location))
        case .GtF: fmt.fprintfln(fd, "setnbe %s", register_8_bit(result_location))
        case .LeF: fmt.fprintfln(fd, "setna %s", register_8_bit(result_location))
        case .GeF: fmt.fprintfln(fd, "setnb %s", register_8_bit(result_location))
        case: panic("unreachable")
    }
    fmt.fprintfln(fd, "movzx %s, %s", result_location, register_8_bit(result_location))
}

@(private="file")
write_return :: proc(using cc: ^Codegen_Context, arg_1: Argument) {
    if arg_1 != nil do fmt.fprintfln(fd, "mov rax, %s", arg_str(cc, arg_1, true))
    fmt.fprintfln(fd, ";;Function Epilogue--")
    fmt.fprintfln(fd, "mov rsp, rbp")
    fmt.fprintfln(fd, "pop rbp")
    fmt.fprintfln(fd, "ret")
}

@(private="file")
write_jz :: proc(using cc: ^Codegen_Context, inst: Instruction) {
    #partial switch arg in inst.arg_1 {
        case Immediate:
            value: bool = ---
            if val, is_int := arg.(i64); is_int do value = bool(val)
            if val, is_byte := arg.(byte); is_byte do value = bool(val)
            if value == false do fmt.fprintfln(fd, "jmp %d", label_str(cc, inst.arg_2))
        case Temporary:
            fmt.fprintfln(fd, "cmp %s, 0", temporary_str(cc, arg, true))
            fmt.fprintfln(fd, "je %s", label_str(cc, inst.arg_2))
        case: panic("Got an uncomparable argument")
    } 
}

@(private="file")
write_call :: proc(using cc: ^Codegen_Context, inst: Instruction) {
    write_foreign_call :: proc(using cc: ^Codegen_Context, inst: Instruction, symbol: Symbol) {
        info := symbol.data.(Foreign_Info)

        register_idx := 1
        float_idx := 0
        for arg_type, i in info.arg_types{
            if _, is_float := arg_type.data.(Type_Info_Float); is_float{
                if float_idx == 8{
                    error("Warning: Foreign functions with stack passed paramaters are untested", symbol.name.location)
                }else{
                    fmt.fprintfln(fd, "pop rax")
                    fmt.fprintfln(fd, "movq xmm%d, rax", float_idx)
                    float_idx += 1
                }
            }
            else if Register(register_idx) < Register.r9{
                fmt.fprintfln(fd, "pop %s", Register(register_idx)) //+1 skips rax
                register_idx += 1
            }else{
                error("Warning: Foreign functions with stack passed paramaters are untested", symbol.name.location)
            }
        }

        fmt.fprintfln(fd, "push rbx")
        fmt.fprintfln(fd, "mov rbx, rsp")

        if !info.builtin {
            if float_idx != 0 {
                fmt.fprintfln(fd, "mov rax, %d", float_idx)
            }else{
                fmt.fprintfln(fd, "xor rax, rax")
            }
            fmt.fprintfln(fd, "and rsp, 0xFFFFFFFFFFFFFFF0")
        }

        already_externed := false
        for name in cc.defined_externals{
            if name == ident(symbol.name) do already_externed = true
        }
        if !already_externed{
            fmt.fprintfln(fd, "extrn %s", ident(symbol.name))
            append(&cc.defined_externals, ident(symbol.name))
        }

        fmt.fprintfln(fd, "call %s", ident(symbol.name))

        fmt.fprintfln(fd, "mov rsp, rbx")
        fmt.fprintfln(fd, "pop rbx")
    }

    symbol := pool_get(cc.sp, inst.arg_1.(Symbol_ID))
    return_register: string = "rax"
    return_move: string = "mov"
    if info, is_foreign_func := symbol.data.(Foreign_Info); is_foreign_func{
        write_foreign_call(cc, inst, symbol)
        if _, is_float := info.return_type.data.(Type_Info_Float); is_float {
            return_register = "xmm0"
            return_move = "movq"
        }
        
    }else{
        fmt.fprintfln(fd, "call rover_%s", ident(symbol.name))
    }
    if return_value, does_return := inst.result.?; does_return {
        save_temporary(cc, return_value)
        fmt.fprintfln(fd, "%s %s, %s",return_move,  arg_str(cc, return_value, false), return_register)
    }
}

@(private="file")
write_sum_float :: proc(using cc: ^Codegen_Context, inst: Instruction) {
    _, _ = save_temporary(cc, inst.result.?)
    instruction := "addsd" if inst.opcode == .AddF else "subsd"
    fmt.fprintfln(fd, "movq xmm0, %s", arg_str(cc, inst.arg_1, true))
    fmt.fprintfln(fd, "movq xmm1, %s", arg_str(cc, inst.arg_2, true))
    fmt.fprintfln(fd, "%s xmm0, xmm1", instruction)
    fmt.fprintfln(fd, "movq %s, xmm1", temporary_str(cc, inst.result.?))
}

@(private="file")
write_prod_float :: proc(using cc: ^Codegen_Context, inst: Instruction) {
    _, _ = save_temporary(cc, inst.result.?)
    instruction := "mulsd" if inst.opcode == .MulF else "divsd"
    fmt.fprintfln(fd, "movq xmm0, %s", arg_str(cc, inst.arg_1, true))
    fmt.fprintfln(fd, "movq xmm1, %s", arg_str(cc, inst.arg_2, true))
    fmt.fprintfln(fd, "%s xmm0, xmm1", instruction)
    fmt.fprintfln(fd, "movq %s, xmm0", temporary_str(cc, inst.result.?) )
}

@(private="file")
label_str :: proc(using cc: ^Codegen_Context, arg: Argument) -> string{
    return fmt.aprintf(".rover_label_%d", arg.(Label), allocator = context.temp_allocator)
}

@(private="file")
temporary_str :: proc(using cc: ^Codegen_Context, arg: Argument, free := false) -> string{
    memory_location := cc.ra.temp_to_memory[arg.(Temporary)]
    if free do free_temporary(cc, arg.(Temporary))
    switch loc in memory_location{
        case Register: return fmt.aprintf( "%s", loc, allocator = context.temp_allocator)
        case Stack_Offset: return fmt.aprintf( "QWORD [rbp - %d]", loc, allocator = context.temp_allocator)
        case: panic("Unreachable")
    }
}

@(private="file")
immediate_str :: proc(using cc: ^Codegen_Context, arg: Argument) -> string{
    switch value in arg.(Immediate){
        case byte: return fmt.aprintf("%d", value, allocator = context.temp_allocator)
        case i64: return fmt.aprintf("%d", value, allocator = context.temp_allocator)
        case f64:
            fmt.fprintfln(fd, "mov rax, %f", value)
            fmt.fprintfln(fd, "movq xmm2, rax")
            return fmt.aprintf("xmm2", allocator = context.temp_allocator)
        case string:
            append(&cc.defined_strings, value)
            return fmt.aprintf("str%d", last_idx(cc.defined_strings),allocator =  context.temp_allocator)
        case: panic("unreachable")
    }
}

@(private="file")
symbol_str :: proc(using cc: ^Codegen_Context, arg: Argument, address: bool = false) -> (string){
    symbol := pool_get(cc.sp, arg.(Symbol_ID))

    #partial switch info in symbol.data{
        case Local_Info:
            size := Asm_Size(info.type.size)
            if address {
                return fmt.aprintf("[rbp - %d]", info.address, allocator = context.temp_allocator)
            }
            return fmt.aprintf("%s [rbp - %d]", size,  info.address, allocator = context.temp_allocator)
        case Foreign_Global_Info:
            already_externed := false
            for name in cc.defined_externals{
                if name == ident(symbol.name) do already_externed = true
            }
            if !already_externed{
                fmt.fprintfln(fd, "extrn %s", ident(symbol.name))
                append(&cc.defined_externals, ident(symbol.name))
            }
            return fmt.aprintfln("[%s]", ident(symbol.name), allocator = context.temp_allocator)
        case: panic("Unreachable")
    }
}

@(private="file")
arg_str :: proc(using cc: ^Codegen_Context, arg:Argument, free_temp := false) -> string{
    switch _ in arg{
        case Immediate: return immediate_str(cc, arg)
        case Temporary: return temporary_str(cc, arg, free_temp)
        case Label: return label_str(cc, arg)
        case Symbol_ID: return symbol_str(cc, arg)
        case: panic("Unreachable")
    }
}

@(private="file")
register_8_bit :: proc(register: Register) -> string {
    switch register{
        case .rax: return "al"
        case .rcx:return "cl"
        case .rdx:return "dl"
        case .rsi:return "sil"
        case .rdi:return "dil"
        case .r8:return "r8b"
        case .r9:return "r9b"
        case: panic("unreachable")
    }
}

@(private="file")
register_string :: proc(register: Register, size: int) -> string{
    if size == 1 do return register_8_bit(register)
    switch register{
        case .rax: return "rax"
        case .rsi: return "rsi"
        case .r8: return "r8"
        case .r9: return "r9"
        case .rcx: return "rcx"
        case .rdi: return "rdi"
        case .rdx: return "rdx"
        case: panic("Unreachable")
    }
}