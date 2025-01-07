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
    string, //label
}

Opcode :: enum {
    Load,
    Store,
    Call,
    Ret,
    Add,
    Sub,
    Mul,
    Div,
    Function, //definition, not a call, basically a label with some meta-data
}

IR_Program :: []Instruction

IR_Context :: struct {
    sm: Scope_Manager,
    program_buffer: [dynamic]Instruction,
    current_locals_size: int,
    free_temps: sa.Small_Array(16, Temporary),
    next_new_temp: Temporary
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

    func_info := pool_get(sm.pool, symbol_id).data.(Function_Info)
    for name, i in func_info.param_names {
        symbol := Symbol{resolved = true, name = name, data = Local_Info{
            address = current_locals_size,
            type = func_info.param_types[i]
        }}
        current_locals_size += symbol.data.(Local_Info).type.size
        scope_register(&ctx.sm, symbol) or_return
    }

    for node in decl.body do ir_generate_statement(ctx, node) or_return

    inject_at(&program_buffer, function_header_index, Instruction{opcode = .Function, arg_1 = symbol_id})
    
    //update symbol with local size
    info, exists := &(ctx.sm.pool[symbol_id].data.(Function_Info))
    assert(exists)
    info.locals_size = current_locals_size
    return true
}

ir_generate_statement :: proc(using ctx: ^IR_Context, st: Statement) -> bool {
    switch stmt_node in st{
        case Variable_Node:
            scope_register_variable(&sm, stmt_node, &current_locals_size) or_return
        case Expression_Node: ir_generate_expression(ctx, stmt_node) or_return
        case Return_Node:
            arg_1 := ir_generate_expression(ctx, Expression_Node(stmt_node)) or_return
            program_append(ctx, .Ret, arg_1)
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
               arg_1 := scope_find(&ctx.sm, Token(expr_node.lhs.(Identifier_Node))) or_return
               arg_2 := ir_generate_expression(ctx, expr_node.rhs) or_return
               defer ir_release_temporary(ctx, arg_2)
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
                    case .Ampersand: program_append(ctx, .Mul, arg_1, arg_2, result)
                    case .SlashForward: program_append(ctx, .Div, arg_1, arg_2, result)
                    case: unimplemented()
                }
                return result, true
               
            }
        case: unimplemented()
    }
    unreachable()
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