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
Label :: distinct int

WORD_SIZE :: 8
BYTE_SIZE :: 1

Argument :: union {
    Symbol_ID,
    Temporary,
    Label,
    Immediate,
}

Immediate :: union {
    i64,
    string,
    f64,
    byte,
}

Opcode :: enum {
    LoadB,
    StoreB,
    StoreW,
    LoadW,
    Call,
    Ret,
    Jmp,
    Addr_Of,
    Offset,
    Jz,
    Eq,
    Nq,
    Lt,
    Gt,
    Le,
    Ge,
    EqF,
    NqF,
    LtF,
    GtF,
    LeF,
    GeF,
    Label,
    Add,
    Sub,
    Mul,
    Div,
    AddF,
    SubF,
    MulF,
    DivF,
    Arg,
    Function, //definition, not a call, basically a label with some meta-data
}

IR_Program :: []Instruction

IR_Builder :: struct {
    sm: Scope_Manager,
    program_buffer: [dynamic]Instruction,
    free_temps: sa.Small_Array(16, Temporary),
    next_new_temp: Temporary,
    next_label: Label,
}

ir_init :: proc(builder: ^IR_Builder, pool: ^Symbol_Pool, allocator: mem.Allocator) {
    builder.sm = Scope_Manager{
        pool = pool,
        symbol_allocator = allocator,
    }
    sa.clear(&builder.free_temps)
    builder.program_buffer = make([dynamic]Instruction, allocator)
}

@(private="file")
program_append :: proc(using builder: ^IR_Builder, opcode: Opcode, arg1: Argument = nil, arg2: Argument = nil, result: Maybe(Temporary) = nil) {
    append(&program_buffer, Instruction{opcode = opcode, arg_1 = arg1, arg_2 = arg2, result = result})
}

@(private="file")
ir_use_label :: proc(using builder: ^IR_Builder) -> Label{
    defer next_label += 1
    return next_label
}

@(private="file")
ir_use_temporary :: proc(using builder: ^IR_Builder, location := #caller_location) -> Temporary{
    free_temp, exists := sa.pop_front_safe(&builder.free_temps)
    
    if !exists {
        free_temp = next_new_temp
        next_new_temp += 1
    }
    return free_temp
}

//you can pass non-temporaries to this for ease of use but it wont do anything
@(private="file")
ir_release_temporary :: proc(using builder: ^IR_Builder, temp: Argument, location := #caller_location ) {
    if temp, is_temp := temp.(Temporary); is_temp{
        for free_temp in builder.free_temps.data[0:free_temps.len] {
            if temp == free_temp {
                fmt.printfln("Double Temporary Free of temp %d at %v\n",temp, location)
                return
            }
        }
        sa.push_back(&builder.free_temps, temp)
    }
}

ir_build_program :: proc(using builder: ^IR_Builder, ast: AST) -> (program: IR_Program, ok: bool) {
    scope_open(&sm) //global scope
    defer scope_close(&sm)

    scope_register_builtins(&sm)

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

    //generate code
    for decl_node in ast {
        function_node := decl_node.(Function_Node) or_continue
        ir_build_function(builder, function_node) or_return
    }

    return program_buffer[:], true
}

@(private="file")
ir_build_function :: proc(using builder: ^IR_Builder, decl: Function_Node) -> bool {
    scope_open(&sm)
    defer scope_close(&sm)

    symbol_id := scope_find(&sm, decl.name) or_return
    sm.current_function = &sm.pool[symbol_id]
    info := &sm.current_function.data.(Function_Info)

    info.param_ids = make([]Symbol_ID, len(decl.params))
    for param, i in decl.params{
        scope_register_variable(&builder.sm, param, true) or_return
        id := scope_find(&builder.sm, param.name) or_return
        info.param_ids[i] = id
    }

    program_append(builder, .Function, symbol_id)
    for node in decl.body do ir_build_statement(builder, node) or_return

    //check if an explicit return is at the end of function, if not add one
    inst := last(builder.program_buffer)

    if inst.opcode != .Ret do program_append(builder, .Ret)    

    return true
}

@(private="file")
ir_build_statement :: proc(using builder: ^IR_Builder, st: Statement) -> bool {
    switch stmt_node in st{
        case Variable_Node: scope_register_variable(&sm, stmt_node) or_return
        case Expression_Node: ir_build_expression(builder, stmt_node) or_return
        case Return_Node: ir_build_return(builder, stmt_node) or_return
        case If_Node: ir_build_if(builder, stmt_node) or_return
        case While_Node: ir_build_while(builder, stmt_node) or_return
    }
    return true
}

@(private="file")
ir_build_if :: proc(using builder: ^IR_Builder, if_node: If_Node) -> bool {
    jump_if_false_instruction: int
    skip_else_if_true_instruction: int
    has_else := true if len(if_node.else_body) > 0 else false
    {
        scope_open(&sm)
        defer scope_close(&sm)
    
        arg_1, _ := ir_build_expression(builder, if_node.comparison) or_return
        ir_release_temporary(builder, arg_1)

        program_append(builder, .Jz, arg_1)
        jump_if_false_instruction = last_idx(program_buffer)

        for body_node in if_node.body do ir_build_statement(builder, body_node) or_return

        if has_else do program_append(builder, .Jmp)
        skip_else_if_true_instruction = last_idx(program_buffer)
    }
    if has_else {
        scope_open(&sm)
        defer scope_close(&sm)

        start_else_label := ir_use_label(builder)
        program_append(builder, .Label, start_else_label)
        program_buffer[jump_if_false_instruction].arg_2 = start_else_label

        for body_node in if_node.else_body do ir_build_statement(builder, body_node)
    }
    end_if_label := ir_use_label(builder)
    program_append(builder, .Label, end_if_label)
    if has_else{
        program_buffer[skip_else_if_true_instruction].arg_1 = end_if_label
    }else{
        program_buffer[jump_if_false_instruction].arg_2 = end_if_label
    }
   
    return true
}

@(private="file")
ir_build_while :: proc(using builder: ^IR_Builder, while_node: While_Node) -> bool {
    scope_open(&sm)
    defer scope_close(&sm)

    continue_label := ir_use_label(builder)
    program_append(builder, .Label, continue_label)

    arg_1, _ := ir_build_expression(builder, while_node.condition) or_return
    ir_release_temporary(builder, arg_1)

    program_append(builder, .Jz, arg_1)
    break_jump_idx := last_idx(program_buffer)

    for body_node in while_node.body do ir_build_statement(builder, body_node) or_return

    program_append(builder, .Jmp, continue_label)
    finish_label := ir_use_label(builder)
    program_append(builder, .Label, finish_label)
    program_buffer[break_jump_idx].arg_2 = finish_label
    
    return true
}

@(private="file")
ir_build_return :: proc(using builder: ^IR_Builder, return_node: Return_Node) -> bool {
    arg_1: Argument = nil
    if expr, has_expr := return_node.?; has_expr {
        arg_1, _ = ir_build_expression(builder, Expression_Node(expr)) or_return
        ir_release_temporary(builder, arg_1)
    }
    program_append(builder, .Ret, arg_1)
    return true
}

Store_Callback :: proc(expr_context: ^Expr_Context, arg: Argument)

Expr_Context :: struct {
    dest_kind: enum {
        Function_Argument,
        Function_Return,
        Memory,
    },
    base_adress: Argument,
    type_info: Type_Info,
    offset: i64,
    builder: ^IR_Builder,
    store_cb: Store_Callback,
}

@(private="file")
ir_build_expression :: proc(using builder: ^IR_Builder, expr: Expression_Node, expr_ctx: ^Expr_Context = nil)  -> (res: Argument, type: Type_Info,  ok: bool) {
    switch expr_node in expr {
        case Literal_Int, Literal_Bool, Literal_Float, Literal_String: return ir_build_value_expression(builder, expr)
        case ^Binary_Expression_Node:
            if expr_node.operator.kind != .Equal && expr_node.operator.kind != .Dot {
                return ir_build_binary_expression(builder, expr_node^)
            }
            
            if expr_node.operator.kind == .Dot{
                lvalue, type := ir_lvalue(builder, expr) or_return
                arg := ir_build_load(builder, lvalue, type, expr_ctx) or_return
                return arg, type, true
            }
            
            if expr_ctx != nil {
                error("Cannot have assignment expression in this context.", expr_node.operator.location)
                return nil, {}, false
            }
            ir_build_assignment(builder, expr_node^) or_return

            return nil, NULL_INFO, true
        case ^Unary_Expression_Node:
            if expr_node.operator.kind != .Hat do return ir_build_basic_unary(builder, expr_node^)
            lvalue, type := ir_build_expression(builder, expr_node.rhs) or_return
            loading_type :=  type.data.(Type_Info_Pointer).pointing_at^
            arg := ir_build_load(builder, lvalue, loading_type, expr_ctx) or_return
            return arg, loading_type, true
        case Array_Literal_Node:
            for entry in expr_node.entries{
                arg, type := ir_build_expression(builder, entry, expr_ctx) or_return
                defer if arg != nil do ir_release_temporary(builder, arg)
                if arg != nil do expr_ctx.store_cb(expr_ctx, arg)
            }
            return nil, NULL_INFO, true
        case Identifier_Node:
            lvalue, type := ir_lvalue(builder, expr) or_return
            arg := ir_build_load(builder, lvalue, type, expr_ctx) or_return
            return arg, type, true
        case Function_Call_Node: return ir_build_function_call(builder, expr_node, expr_ctx)
        case: panic("Unreachable")
    }
}

@(private="file")
ir_build_assignment :: proc(using builder: ^IR_Builder, expr_node: Binary_Expression_Node) -> bool {
    lvalue, type_info := ir_lvalue(builder, expr_node.lhs) or_return

    ctx := Expr_Context{
        dest_kind = .Memory,
        builder =  builder,
        base_adress = lvalue,
        type_info = type_info,
        offset = 0,
        store_cb = store_callback_from_type(type_info),
    }

    value, _ := ir_build_expression(builder, expr_node.rhs, &ctx) or_return
    defer if value != nil do ir_release_temporary(builder, value)

    //nil value indicates there was a sub expression that was not a basic expression
    //in such a case it would have already called the callback for itself.
    if value != nil do ctx.store_cb(&ctx, value)

    return true
}

@(private="file")
ir_build_function_call :: proc(using builder: ^IR_Builder, expr_node: Function_Call_Node, expr_ctx: ^Expr_Context) -> (res: Argument, type: Type_Info,  ok: bool) {
    Store_Arg :: proc(expr_ctx: ^Expr_Context, arg: Argument) {
        ir_release_temporary(expr_ctx.builder, arg)
        program_append(expr_ctx.builder, .Arg, arg)
    }
    callee := scope_find(&sm, expr_node.name) or_return
    symbol := pool_get(sm.pool, callee)
    
    ctx := Expr_Context{
        dest_kind = .Function_Argument,
        store_cb = Store_Arg,
        builder = builder,
    }

    #reverse for argument in expr_node.args {
        arg_1, _ := ir_build_expression(builder, argument, &ctx) or_return
        if arg_1 != nil do Store_Arg(&ctx, arg_1)
    }

    result: Maybe(Temporary) 
    return_type := NULL_INFO
    #partial switch data in symbol.data{
        case Foreign_Info:
            if data.return_type.size > 0 {
                return_type = data.return_type
                result = ir_use_temporary(builder) if data.return_type.size > 0 else nil
            }
        case Function_Info:
            if data.return_type.size > 0 {
                return_type = data.return_type
                result = ir_use_temporary(builder) if data.return_type.size > 0 else nil
            }
        case: panic("unreachable")
    }
    program_append(builder, .Call, callee, nil, result)
    if res, ok := result.?; ok do return res, return_type, true
    return nil, return_type, true
}

@(private="file")
ir_build_load :: proc(using builder: ^IR_Builder, from: Argument, type: Type_Info, expr_ctx: ^Expr_Context) -> (res: Argument,  ok: bool) {
    if is_simple_type(type) {
        result := ir_use_temporary(builder)
        inst: Opcode = .LoadW if type.size == 8 else .LoadB
        program_append(builder, inst, from, nil, result)
        ir_release_temporary(builder, from)
        return result, true
    }

    #partial switch info in type.data{
        case Type_Info_Array:
            length := type.size / info.element_type.size
            from := from
            defer ir_release_temporary(builder, from)
            if sym_id, is_sym := from.(Symbol_ID); is_sym {
                from = ir_use_temporary(builder)
                program_append(builder, .Addr_Of, sym_id, nil, from.(Temporary))
            }
            for i in 0..<length {
                next_address := ir_use_temporary(builder)
                program_append(builder, .Offset, from, Immediate(i64(info.element_type.size)), next_address)
                arg := ir_build_load(builder, from, info.element_type^, expr_ctx) or_return
                if arg != nil do expr_ctx.store_cb(expr_ctx, arg)
                from = next_address
            }

            return nil, true
        case: unimplemented()
    }
}

@(private="file")
ir_build_basic_unary :: proc(using builder: ^IR_Builder, expr_node: Unary_Expression_Node) -> (res: Argument, type: Type_Info,  ok: bool) {
    #partial switch expr_node.operator.kind{
        case .Ampersand: 
            arg_1, type := ir_lvalue(builder, expr_node.rhs) or_return
            if _, is_ident := expr_node.rhs.(Identifier_Node); !is_ident{
                error("Tried to address a non-identifier", expr_node.operator.location)
            }
            result := ir_use_temporary(builder)
            pointing_at := new(Type_Info, sm.symbol_allocator)
            pointing_at^ = type
            program_append(builder, .Addr_Of, arg_1, nil, result)
            return result, Type_Info{size = 8, data = Type_Info_Pointer{pointing_at = pointing_at}}, true
        case .Dash:
            arg_1, type := ir_build_expression(builder, expr_node.rhs) or_return
            defer ir_release_temporary(builder, arg_1)
            result := ir_use_temporary(builder)
            program_append(builder, .Mul, arg_1, Immediate(i64(-1)), result)
            return result, type, true
        case: panic("Not a unary operator")
    }
}

@(private="file")
ir_build_binary_expression :: proc(using builder: ^IR_Builder, expr_node: Binary_Expression_Node) -> (res: Argument, type: Type_Info,  ok: bool) {
    arg_1, type_1 := ir_build_expression(builder, expr_node.lhs) or_return
    arg_2, type_2 := ir_build_expression(builder, expr_node.rhs) or_return
    defer ir_release_temporary(builder, arg_1)
    defer ir_release_temporary(builder, arg_2)
    result := ir_use_temporary(builder)
    if _, is_float := type_1.data.(Type_Info_Float); is_float{
        #partial switch expr_node.operator.kind {
            case .Plus: program_append(builder, .AddF, arg_1, arg_2, result)
            case .Dash: program_append(builder, .SubF, arg_1, arg_2, result)
            case .Asterisk: program_append(builder, .MulF, arg_1, arg_2, result)
            case .SlashForward: program_append(builder, .DivF, arg_1, arg_2, result)
            case .DoubleEqual: program_append(builder, .EqF, arg_1, arg_2, result)
            case .LessThan: program_append(builder, .LtF, arg_1, arg_2, result)
            case .LessThanEqual: program_append(builder, .LeF, arg_1, arg_2, result)
            case .NotEqual: program_append(builder, .NqF, arg_1, arg_2, result)
            case .GreaterThan: program_append(builder, .GtF, arg_1, arg_2, result)
            case .GreaterThanEqual: program_append(builder, .GeF, arg_1, arg_2, result)
            case: unimplemented()
        }
        return result, type_1, true
    }
    #partial switch expr_node.operator.kind {
        case .Plus: program_append(builder, .Add, arg_1, arg_2, result)
        case .Dash: program_append(builder, .Sub, arg_1, arg_2, result)
        case .Asterisk: program_append(builder, .Mul, arg_1, arg_2, result)
        case .SlashForward: program_append(builder, .Div, arg_1, arg_2, result)
        case .DoubleEqual: program_append(builder, .Eq, arg_1, arg_2, result)
        case .LessThan: program_append(builder, .Lt, arg_1, arg_2, result)
        case .LessThanEqual: program_append(builder, .Le, arg_1, arg_2, result)
        case .NotEqual: program_append(builder, .Nq, arg_1, arg_2, result)
        case .GreaterThan: program_append(builder, .Gt, arg_1, arg_2, result)
        case .GreaterThanEqual: program_append(builder, .Ge, arg_1, arg_2, result)
        case: unimplemented()
    }
    return result, type_1, true
}

@(private="file")
ir_build_value_expression :: proc(using builder: ^IR_Builder, expr: Expression_Node) -> (res: Argument, type: Type_Info,  ok: bool) {
    #partial switch expr_node in expr{
        case Literal_Int: return Immediate(expr_node.data.(i64)), INTEGER_INFO, true
        case Literal_String: return Immediate(expr_node.data.(string)), CSTRING_INFO, true
        case Literal_Float: return Immediate(expr_node.data.(f64)), FLOAT_INFO, true
        case Literal_Bool:
            value: byte = 1 if expr_node.kind == .True else 0
            return Immediate(value), BYTE_INFO, true
        case: panic("Not a value expression")
    }
}

@(private="file")
ir_lvalue :: proc(using builder: ^IR_Builder, expr: Expression_Node) -> (res: Argument, type: Type_Info,  ok: bool) {
    #partial switch expr_node in expr{
        case Identifier_Node:
            symbol_id := scope_find(&builder.sm, Token(expr_node)) or_return
            symbol := pool_get(sm.pool, symbol_id)
            type_info: Type_Info
            if local, is_local := symbol.data.(Local_Info); is_local{
                type_info = local.type
            }else{
                type_info = Type_Info(symbol.data.(Foreign_Global_Info))
            }
            return symbol_id, type_info, true
        case ^Binary_Expression_Node:
            assert(expr_node.operator.kind == .Dot)
            if ident, is_ident := expr_node.rhs.(Identifier_Node); is_ident {
                //indicates expression is x.b not x.(b)
                if ident.location.position <= expr_node.operator.location.position + 1 {
                    panic("Structs access not implemented")
                }
            }
            index_expr, type := ir_build_expression(builder, expr_node.rhs) or_return
            from_arg, lvalue_type := ir_lvalue(builder, expr_node.lhs) or_return
            element_type := lvalue_type.data.(Type_Info_Array).element_type^
            defer ir_release_temporary(builder, index_expr)
            defer ir_release_temporary(builder, from_arg)
            if sym, is_sym := from_arg.(Symbol_ID); is_sym {
                from_arg = ir_use_temporary(builder)
                program_append(builder, .Addr_Of, sym, nil, from_arg.(Temporary))
            }
            index_result := ir_use_temporary(builder)
            defer ir_release_temporary(builder, index_result)
            program_append(builder, .Mul, index_expr, Immediate(i64(element_type.size)), index_result)
            result := ir_use_temporary(builder)
            program_append(builder, .Add, index_result, from_arg, result)
            return result, element_type, true
        case ^Unary_Expression_Node:
            if expr_node.operator.kind != .Hat{
                error("Expected a dereferance operator got %s", expr_node.operator.location, expr_node.operator.kind)
                return nil, {}, false
            }
            result := ir_use_temporary(builder)
            arg_1, type := ir_build_expression(builder, expr_node.rhs) or_return
            ir_release_temporary(builder, arg_1)
            return result, type.data.(Type_Info_Pointer).pointing_at^, true
        case: unimplemented()
    }
}


is_simple_type :: proc(type: Type_Info) -> bool {
    #partial switch info in type.data{
        case Type_Info_Array: return false
        case: return true
    }
}

@(private="file")
store_callback_from_type :: proc(type: Type_Info) -> Store_Callback {
    Store_Word :: proc(expr_context: ^Expr_Context, arg: Argument) {
        defer ir_release_temporary(expr_context.builder, expr_context.base_adress)
        program_append(expr_context.builder, .StoreW, expr_context.base_adress, arg)
    }
    Store_Byte :: proc(expr_context: ^Expr_Context, arg: Argument) {
        defer ir_release_temporary(expr_context.builder, expr_context.base_adress)
        program_append(expr_context.builder, .StoreB, expr_context.base_adress, arg)
    }
    Store_Array :: proc(expr_context: ^Expr_Context, arg: Argument) {
        defer ir_release_temporary(expr_context.builder, arg)
        element_size := expr_context.type_info.data.(Type_Info_Array).element_type.size
        store_inst: Opcode = .StoreW if element_size == 8 else .StoreB
        if sym_id, is_sym := expr_context.base_adress.(Symbol_ID); is_sym {
            expr_context.base_adress = ir_use_temporary(expr_context.builder)
            program_append(expr_context.builder, .Addr_Of, sym_id, nil, expr_context.base_adress.(Temporary))
        }
        next_address := ir_use_temporary(expr_context.builder)
        program_append(expr_context.builder, .Offset, expr_context.base_adress, Immediate(i64(element_size)), next_address)
        program_append(expr_context.builder, store_inst, expr_context.base_adress, arg)
        ir_release_temporary(expr_context.builder, expr_context.base_adress)
        expr_context.base_adress = next_address
    }

    if is_simple_type(type) {
        return Store_Word if type.size == 8 else Store_Byte
    }

    #partial switch info in type.data{
        case Type_Info_Array: return Store_Array
        case: unimplemented()
    }
}
