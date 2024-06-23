package backend

import fe"../frontend"
import "../shared"

Opcode :: enum {
    Push,
    Add,
    Sub,
    Mul,
    Div,
}

Operand :: int

Instruction :: struct {
    opc: Opcode,
    operand: Operand,
}

IR_Context :: struct{
    program_buffer: [dynamic]Instruction,
    current_stack_size: int,
    sm: Scope_Manager,

    funcs: Functions,
}

Functions :: struct {
    names: [dynamic]string,
    code: [dynamic][]Instruction,
    stack_size: [dynamic]int,
    param_size: [dynamic]int,
}

generate_function :: proc(using ctx: ^IR_Context, func: ^fe.Function_Declaration) -> bool {
    append(&funcs.names, func.name.data.(string))

    sym_info := scope_find(&sm, func.name.data.(string)) or_return
    info := sym_info.data.(Type_Info_Func)

    param_size := 0
    for p_type in info.parameter_types{
        param_size += p_type.size
    }
    append(&funcs.param_size, param_size)

    for stmt in func.body {
        generate_statement(ctx, stmt) or_return
    }

    append(&funcs.stack_size, current_stack_size)
    append(&funcs.code, program_buffer[:])

    current_stack_size = 0
    clear(&program_buffer)

    return true

}

generate_statement :: proc(using ctx: ^IR_Context, stmt: fe.Statement) -> bool {
    #partial switch stmt_val in stmt {
        case fe.Expression: generate_expression(ctx, stmt_val) or_return
        case: shared.rover_fatal("Unimplemented %v", stmt)
    }
    return true
}   


generate_expression :: proc(using ctx: ^IR_Context, expr: fe.Expression) -> bool {
    for node in expr{
        #partial switch node_val in node {
            case fe.Literal_Int: append(&program_buffer, Instruction{.Push, node_val.data.(int)})
            case fe.Literal_Bool: append(&program_buffer, Instruction{.Push, 1 if node_val.kind == .True else 0})
            case fe.Binary_Expression:
                #partial switch node_val.operator.kind {
                    case .Plus: append(&program_buffer, Instruction{.Add, 0})
                    case .Dash: append(&program_buffer, Instruction{.Sub, 0})
                    case .Asterisk: append(&program_buffer, Instruction{.Mul, 0})
                    case .SlashForward: append(&program_buffer, Instruction{.Div, 0})
                    case: 
                        shared.rover_error("%s is not a valid binary operator", node_val.operator.location, node_val.operator.kind)
                        return false
                }
            case: shared.rover_fatal("Unimplemented %v", node)
        }
    }
    return true
}   

