package backend

import fe"../frontend"
import "../shared"

Opcode :: enum {
    Push,
    Add,
    Sub,
    Mul,
    Div,
    Store,
    Ret,
    Load,
}

Addr_Loc :: enum {
    Stack,
    Param,
    Other,
}

Operand :: int
Instruction :: struct {
    opc: Opcode,
    operand: Operand,
}

IR_Context :: struct{
    program_buffer: [dynamic]Instruction,
    current_stack_size: int,
    current_expression_type: Type_Info,

    sm: Scope_Manager,

    funcs: Functions,
}

Functions :: struct {
    names: [dynamic]string,
    code: [dynamic][]Instruction,
    stack_size: [dynamic]int,
    param_size: [dynamic]int,
}

STACK_BEGIN :: 0

generate_function :: proc(using ctx: ^IR_Context, func: ^fe.Function_Declaration) -> bool {
    current_stack_size = STACK_BEGIN
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

    clear(&program_buffer)

    return true

}

generate_statement :: proc(using ctx: ^IR_Context, stmt: fe.Statement) -> bool {
    #partial switch stmt_val in stmt {
        case fe.Expression: 
            info := generate_expression(ctx, stmt_val) or_return
            if _, ok := info.data.(Type_Info_Null); !ok {
                shared.rover_error("Expression has a result that is not handled", fe.expression_location(stmt_val))
            }
        case fe.Return:
            info := generate_expression(ctx, cast(fe.Expression)stmt_val) or_return
            append(&program_buffer, Instruction{.Ret,42})
           
        case ^fe.Variable_Declaration:
            info: Variable_Info = {stack_offset = current_stack_size}
            defer current_stack_size += info.type_info.size
            append(&program_buffer, Instruction{.Push, info.stack_offset})
            expr_type := generate_expression(ctx, stmt_val.value) or_return
    
            append(&program_buffer, Instruction{.Store, int(Addr_Loc.Stack)})
            info.type_info = expr_type

            ast_type, has_type := stmt_val.type.?

            if has_type{
                //TODO confirm types work are compatible
                info.type_info = (get_type_info(&sm, ast_type) or_return)^
            }

            scope_register_symbol(
                &sm, 
                Symbol_Info{data = info, resolution_state = .Resolved, ast_node = nil}, 
                stmt_val.name,
            ) or_return
        

        case: shared.rover_fatal("Unimplemented %v", stmt)
    }
    return true
}   



generate_expression :: proc(using ctx: ^IR_Context, expr: fe.Expression) -> (info: Type_Info, ok: bool) {
    for node in expr{
        #partial switch node_val in node {
            case fe.Literal_Int: 
                append(&program_buffer, Instruction{.Push, node_val.data.(int)})
                current_expression_type = (scope_find(&sm, "int") or_return).data.(Type_Info)
            case fe.Literal_Bool: 
                append(&program_buffer, Instruction{.Push, 1 if node_val.kind == .True else 0})
                current_expression_type = (scope_find(&sm, "bool") or_return).data.(Type_Info)
            case fe.Binary_Expression:
                #partial switch node_val.operator.kind {
                    case .Plus: append(&program_buffer, Instruction{.Add, 0})
                    case .Dash: append(&program_buffer, Instruction{.Sub, 0})
                    case .Asterisk: append(&program_buffer, Instruction{.Mul, 0})
                    case .SlashForward: append(&program_buffer, Instruction{.Div, 0})
                    case: 
                        shared.rover_error("%s is not a valid binary operator", node_val.operator.location, node_val.operator.kind)
                        return {}, false
                }
            case fe.Identifier:
                info := scope_find(&sm, node_val.data.(string)) or_return
                var_info := info.data.(Variable_Info)
                append(&program_buffer, Instruction{.Push, var_info.stack_offset})
                append(&program_buffer, Instruction{.Load, int(Addr_Loc.Stack)})
            case: shared.rover_fatal("Unimplemented %v", node)
        }
    }
    return current_expression_type, true
}

