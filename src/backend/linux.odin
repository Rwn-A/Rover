package backend

import "core:fmt"
import "core:os"

import "../shared"

x86_64_fasm :: proc(funcs: Functions) -> bool {
    fd, err := os.open("./out/output.fasm", os.O_RDWR | os.O_CREATE | os.O_TRUNC, 0o777)
    if err != os.ERROR_NONE {
        shared.rover_fatal("Could not open output assembly file")
    }
    defer os.close(fd)

    fmt.fprintfln(fd, "format ELF64")
    fmt.fprintfln(fd, "section '.text' executable")
    
    for name in funcs.names{
        fmt.fprintfln(fd, "public rover_%s", name)
    }

    for code, idx in funcs.code{
        fmt.fprintfln(fd, "rover_%s:", funcs.names[idx])
        fmt.fprintfln(fd, "push rbp")
        fmt.fprintfln(fd, "mov rbp, rsp")
        for inst in code{
            using inst
            switch opc {
                case .Push:
                    fmt.fprintfln(fd, ";;push a word")
                    fmt.fprintfln(fd, "pushq %d", operand)
                    fmt.fprintfln(fd, ";;end push a word\n")
                case .Add:
                    fmt.fprintfln(fd, ";;add")
                    fmt.fprintfln(fd, "pop rax")
                    fmt.fprintfln(fd, "pop rbx")
                    fmt.fprintfln(fd, "add rbx, rax")
                    fmt.fprintfln(fd, "push rbx")
                    fmt.fprintfln(fd, ";;end add\n")
                case .Mul:
                    fmt.fprintfln(fd, ";;mul")
                    fmt.fprintfln(fd, "pop rbx")
                    fmt.fprintfln(fd, "pop rax")
                    fmt.fprintfln(fd, "mul rbx")
                    fmt.fprintfln(fd, "push rax")
                    fmt.fprintfln(fd, ";;end mul\n")
                case .Sub:
                    fmt.fprintfln(fd, ";;sub")
                    fmt.fprintfln(fd, "pop rax")
                    fmt.fprintfln(fd, "pop rbx")
                    fmt.fprintfln(fd, "sub rbx, rax")
                    fmt.fprintfln(fd, "push rbx")
                    fmt.fprintfln(fd, ";;end sub\n")
                case .Div:
                    fmt.fprintfln(fd, ";;div")
                    fmt.fprintfln(fd, "pop rax")
                    fmt.fprintfln(fd, "pop rbx")
                    fmt.fprintfln(fd, "div rbx, rax")
                    fmt.fprintfln(fd, "push rbx")
                    fmt.fprintfln(fd, ";;end div\n")      
            }
        }
        fmt.fprintfln(fd, "pop rax") //TODO: get rid of this
        fmt.fprintfln(fd, "leave")
        fmt.fprintfln(fd, "ret")

    }
    return true
}