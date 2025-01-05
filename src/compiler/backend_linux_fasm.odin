package compiler

import "core:os"
import "core:fmt"

temp_to_reg :: proc(temporary: Temporary) -> (string, bool) {
    switch temporary{
        case 0: return "rcx", true
        case 1: return "rdx", true
        case 2: return "rsi", true
        case 3: return "rdi", true
        case 4: return "r8", true
        case 5: return "r9", true
        case: return "", false
    }
}

generate_fasm :: proc(sp: ^Symbol_Pool, program: IR_Program) -> bool {
    fd, err := os.open("output.fasm", os.O_RDWR | os.O_CREATE | os.O_TRUNC, 0o777)
    if err != os.ERROR_NONE {
        fatal("Could not open output assembly file")
    }
    defer os.close(fd)

    fmt.fprintfln(fd, "format ELF64")
    fmt.fprintfln(fd, "section '.text' executable")
    fmt.fprintfln(fd, "public _start")
    fmt.fprintfln(fd, "_start:")
    fmt.fprintfln(fd, "call rover_main")
    fmt.fprintfln(fd, "mov rdi, rax")
    fmt.fprintfln(fd, "mov rax, 60")
    fmt.fprintfln(fd, "syscall")

    for inst in program {
        #partial switch inst.opcode {
            case .Function:
                symbol := pool_get(sp, inst.arg_1.(Symbol_ID))
                info := symbol.data.(Function_Info)
                fmt.fprintfln(fd, "rover_%s:", ident(symbol.name))
                fmt.fprintfln(fd, "push rbp")
                fmt.fprintfln(fd, "mov rbp, rsp")
                //keeps stack alligned, might not care about this in the future and just align it when talking to C
                fmt.fprintfln(fd, "sub rsp, %d", info.locals_size + (16 - (info.locals_size % 16)))
            case .Add:
                #partial switch arg in inst.arg_1 {
                    case Temporary:
                        register, in_register := temp_to_reg(arg)
                        if !in_register{
                            fmt.fprintfln(fd, "pop r10")
                        }else{
                            fmt.fprintfln(fd, "mov r10, %v", register)
                        }

                    case i64:
                        fmt.fprintfln(fd, "mov r10, %v", arg)
                    case: unreachable()
                }
                #partial switch arg in inst.arg_2 {
                    case Temporary:
                        register, in_register := temp_to_reg(arg)
                        if !in_register{
                            fmt.fprintfln(fd, "pop r11")
                        }else{
                            fmt.fprintfln(fd, "mov r10, %v", register)
                        }
                    case i64:
                        fmt.fprintfln(fd, "mov r11, %v", arg)
                    case: unreachable()
                }
                fmt.fprintfln(fd, "add r10, r11")
                result_reg, in_reg := temp_to_reg(inst.result.(Temporary))
                if !in_reg{
                    fmt.fprintfln(fd, "push r10")
                }else{
                    fmt.fprintfln(fd, "mov %s, r10", result_reg)
                }
            case .Ret:
                #partial switch arg in inst.arg_1 {
                    case Temporary:
                        register, in_register := temp_to_reg(arg)

                        if !in_register{
                            fmt.fprintfln(fd, "pop rax")
                        }else{
                            fmt.fprintfln(fd, "mov rax, %v", register)
                        }
                    case i64:
                        fmt.fprintfln(fd, "mov rax, %v", arg)
                    case: unreachable()
                }
                fmt.fprintfln(fd, "mov rsp, rbp")
                fmt.fprintfln(fd, "pop rbp")
                fmt.fprintfln(fd, "ret")
        }   
    }
    return true
}

