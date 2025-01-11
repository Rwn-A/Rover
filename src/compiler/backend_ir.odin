package compiler

import "core:mem"
import "core:fmt"
import sa"core:container/small_array"

Instruction :: struct {
    opcode: Opcode,
    result: Maybe(Temporary),
    arg_1: Argument,
    arg_2: Argument,
}

Temporary :: distinct int

Argument :: union {
    Symbol_ID,
    Temporary,
    i64,
}

Opcode :: enum {
    Load,
    Store,
    Call,
    Ret,
    Jmp,
    Addr_Of,
    Jz,
    Eq,
    Nq,
    Lt,
    Gt,
    Le,
    Ge,
    Label,
    Add,
    Sub,
    Mul,
    Div,
    Arg,
    Function, //definition, not a call, basically a label with some meta-data
}

IR_Program :: []Instruction

IR_Context :: struct {
    sm: Scope_Manager,
    program_buffer: [dynamic]Instruction,
    current_locals_size: int,
    free_temps: sa.Small_Array(16, Temporary),
    next_new_temp: Temporary,
    current_function: Symbol_ID,
    next_label: int
}

program_append :: proc(using ctx: ^IR_Context, opcode: Opcode, arg1: Argument = nil, arg2: Argument = nil, result: Maybe(Temporary) = nil) {
    append(&program_buffer, Instruction{opcode = opcode, arg_1 = arg1, arg_2 = arg2, result = result})
}

ir_init :: proc(ctx: ^IR_Context, pool: ^Symbol_Pool, allocator: mem.Allocator) {
    ctx.sm = Scope_Manager{
        pool = pool,
        symbol_allocator = allocator,
    }
    ctx.program_buffer = make([dynamic]Instruction, allocator)
}

ir_generate_program :: proc(using ctx: ^IR_Context, ast: AST) -> (program: IR_Program, ok: bool) {
    scope_open(&sm) //global scope
    defer scope_close(&sm)

    scope_register_builtin_types(&sm)

    //forward declare all global symbols
    for decl_node in ast{
        switch decl in decl_node{
            case Function_Node: scope_register(&sm, Symbol{resolved = false, name = decl.name, data=nil}) or_return
            case Foreign_Function_Node: scope_register(&sm, Symbol{resolved = false, name = decl.name, data = nil}) or_return
            case Foreign_Global_Node: scope_register(&sm, Symbol{resolved = false, name = decl.name, data = nil}) or_return
        }
    }

    //resolve global symbols
    for decl_node in ast do scope_register_global_declaration(&sm, decl_node)

    for decl_node in ast {
        if function_node, ok := decl_node.(Function_Node); ok {
            ir_generate_function(ctx, function_node) or_return
        }
    }

    return program_buffer[:], true
}

ir_generate_function :: proc(using ctx: ^IR_Context, decl: Function_Node) -> bool {
    scope_open(&sm)
    defer scope_close(&sm)
    defer current_locals_size = 0

    symbol_id := scope_find(&sm, decl.name) or_return
    function_header_index := len(program_buffer)
    info, exists := &(ctx.sm.pool[symbol_id].data.(Function_Info))
    info.size_of_first_local = -1

    info.param_ids = make([]Symbol_ID, len(decl.params))
    for param, i in decl.params{
        scope_register_variable(&ctx.sm, param, &current_locals_size, true) or_return
        id := scope_find(&ctx.sm, param.name) or_return
        info.param_ids[i] = id
        if i == 0{
            info.size_of_first_local = pool_get(sm.pool, id).data.(Local_Info).type.size
        }
    }

    current_function = symbol_id

    for node in decl.body do ir_generate_statement(ctx, node) or_return

    inject_at(&program_buffer, function_header_index, Instruction{opcode = .Function, arg_1 = symbol_id})
    
    assert(exists)
    info.locals_size = current_locals_size
    return true
}

ir_generate_statement :: proc(using ctx: ^IR_Context, st: Statement) -> bool {
    switch stmt_node in st{
        case Variable_Node:
            scope_register_variable(&sm, stmt_node, &current_locals_size) or_return
            modifiable_info := &(ctx.sm.pool[current_function].data.(Function_Info))
            if modifiable_info.size_of_first_local == -1{
                modifiable_info.size_of_first_local = pool_get(sm.pool, scope_find(&sm, stmt_node.name) or_return).data.(Local_Info).type.size
            }
           
        case Expression_Node: ir_generate_expression(ctx, stmt_node) or_return
        case Return_Node:
            arg_1 := ir_generate_expression(ctx, Expression_Node(stmt_node)) or_return
            program_append(ctx, .Ret, arg_1)
        case If_Node:
            scope_open(&sm)
            defer scope_close(&sm)
            arg_1 := ir_generate_expression(ctx, stmt_node.comparison) or_return
            program_append(ctx, .Jz, arg_1)
            ir_release_temporary(ctx, arg_1)
            jump_inst_position := len(ctx.program_buffer) - 1
            for body_node in stmt_node.body{
                ir_generate_statement(ctx, body_node) or_return
            }
            if_jump_inst_position := 0
            if len(stmt_node.else_body) > 0{
                program_append(ctx, .Jmp)
                if_jump_inst_position = len(ctx.program_buffer) - 1
            }
            program_append(ctx, .Label, i64(next_label))
            program_buffer[jump_inst_position].arg_2 = i64(next_label)
            next_label += 1
            for body_node in stmt_node.else_body{
                ir_generate_statement(ctx, body_node) or_return
            }
            if len(stmt_node.else_body) > 0{
                program_append(ctx, .Label, i64(next_label))
                program_buffer[if_jump_inst_position].arg_1 = i64(next_label)
                next_label += 1
            }
        case While_Node:
            scope_open(&sm)
            defer scope_close(&sm)
            continue_label := next_label
            next_label += 1
            program_append(ctx, .Label, i64(continue_label))
            arg_1 := ir_generate_expression(ctx, stmt_node.condition) or_return
            program_append(ctx, .Jz, arg_1)
            jump_inst_position := len(ctx.program_buffer) - 1
            ir_release_temporary(ctx, arg_1)
            for body_node in stmt_node.body{
                ir_generate_statement(ctx, body_node) or_return
            }
            program_append(ctx, .Jmp, i64(continue_label))
            program_append(ctx, .Label, i64(next_label))
            program_buffer[jump_inst_position].arg_2 = i64(next_label)
            next_label += 1
        case: unimplemented()
    }
    return true
}

ir_generate_expression :: proc(using ctx: ^IR_Context, expr: Expression_Node) -> (arg: Argument, ok: bool) {
       #partial switch expr_node in expr{
        case Literal_Int: return expr_node.data.(i64), true
        case Identifier_Node:
            symbol_id := scope_find(&ctx.sm, Token(expr_node)) or_return
            result := ir_use_temporary(ctx)
            program_append(ctx, .Load, symbol_id, nil, result)
            return result, true
        case ^Binary_Expression_Node: 
            if expr_node.operator.kind == .Equal{
                arg_1 := ir_lvalue(ctx, expr_node.lhs) or_return
               arg_2 := ir_generate_expression(ctx, expr_node.rhs) or_return
               defer ir_release_temporary(ctx, arg_2)
               defer ir_release_temporary(ctx, arg_1)
               program_append(ctx, .Store, arg_1, arg_2)
               return nil, true
            }else{
                arg_1 := ir_generate_expression(ctx, expr_node.lhs) or_return
                arg_2 := ir_generate_expression(ctx, expr_node.rhs) or_return
                defer ir_release_temporary(ctx, arg_1)
                defer ir_release_temporary(ctx, arg_2)
                result := ir_use_temporary(ctx)
                #partial switch expr_node.operator.kind {
                    case .Plus: program_append(ctx, .Add, arg_1, arg_2, result)
                    case .Dash: program_append(ctx, .Sub, arg_1, arg_2, result)
                    case .Asterisk: program_append(ctx, .Mul, arg_1, arg_2, result)
                    case .SlashForward: program_append(ctx, .Div, arg_1, arg_2, result)
                    case .DoubleEqual: program_append(ctx, .Eq, arg_1, arg_2, result)
                    case .LessThan: program_append(ctx, .Lt, arg_1, arg_2, result)
                    case .LessThanEqual: program_append(ctx, .Le, arg_1, arg_2, result)
                    case .NotEqual: program_append(ctx, .Nq, arg_1, arg_2, result)
                    case .GreaterThan: program_append(ctx, .Gt, arg_1, arg_2, result)
                    case .GreaterThanEqual: program_append(ctx, .Ge, arg_1, arg_2, result)
                    case: unimplemented()
                }
                return result, true
            }
        case ^Unary_Expression_Node:
            #partial switch expr_node.operator.kind{
                case .Ampersand: 
                    arg_1 := ir_lvalue(ctx, expr_node.rhs) or_return
                    defer ir_release_temporary(ctx, arg_1)
                    result := ir_use_temporary(ctx)
                    program_append(ctx, .Addr_Of, arg_1, nil, result)
                    return result, true
                case .Hat:
                    arg_1 := ir_generate_expression(ctx, expr_node.rhs) or_return
                    defer ir_release_temporary(ctx, arg_1)
                    result := ir_use_temporary(ctx)
                    program_append(ctx, .Load, arg_1, nil, result)
                    return result, true
                case:
                    error("Not a unary operator %s", expr_node.operator.location, expr_node.operator.kind)
                    return nil, false
            }
        case Function_Call_Node:
            callee := scope_find(&sm, expr_node.name) or_return
            symbol := pool_get(sm.pool, callee)

            #reverse for argument in expr_node.args{
                arg_1 := ir_generate_expression(ctx, argument) or_return
                ir_release_temporary(ctx, arg_1)
                program_append(ctx, .Arg, arg_1)
            }
            result: Maybe(Temporary) 
            #partial switch data in symbol.data{
                case Foreign_Info:
                    result = ir_use_temporary(ctx) if data.return_type.size > 0 else nil
                case Function_Info:
                    result = ir_use_temporary(ctx) if data.return_type.size > 0 else nil
                case: panic("unreachable")
            }
            program_append(ctx, .Call, callee, nil, result)
            if res, ok := result.?; ok do return res, true
            return nil, true

        case: unimplemented()
    }
}

ir_lvalue :: proc(using ctx: ^IR_Context, expr: Expression_Node) -> (res: Argument, ok: bool) {
    #partial switch expr_node in expr{
        case Identifier_Node:
            symbol_id := scope_find(&ctx.sm, Token(expr_node)) or_return
            return symbol_id, true
        case ^Unary_Expression_Node:
            if expr_node.operator.kind != .Hat{
                error("Expected a dereferance operator got %s", expr_node.operator.location, expr_node.operator.kind)
                return nil, false
            }
            result := ir_use_temporary(ctx)
            arg_1 := ir_lvalue(ctx, expr_node.rhs) or_return
            defer ir_release_temporary(ctx, arg_1)
            program_append(ctx, .Load, arg_1, nil, result)
            return result, true
        case: unimplemented()
    }
}

ir_use_temporary :: proc(using ctx: ^IR_Context) -> Temporary{
    free_temp, exists := sa.pop_front_safe(&ctx.free_temps)
    if !exists {
        free_temp = next_new_temp
        next_new_temp += 1
    }
    return free_temp
}

//you can pass non-temporaries to this for ease of use but it wont do anything
ir_release_temporary :: proc(using ctx: ^IR_Context, temp: Argument) {
    if temp, is_temp := temp.(Temporary); is_temp{
        sa.push_back(&ctx.free_temps, temp)
    }
}