package compiler

import "core:mem"
import "core:fmt"
import sa"core:container/small_array"

MAX_BLOCK_DEPTH :: 128


Symbol_Pool :: [dynamic]Symbol //all symbols in the program go here, queried by ID
Symbol_Table :: map[string]Symbol_ID //only variables in scope will ever need to be queried by string
Symbol_ID :: distinct int

Scope_Manager :: struct{
    scopes: sa.Small_Array(MAX_BLOCK_DEPTH, Symbol_Table),
    symbol_allocator: mem.Allocator, //some symbols require allocations, nested types primarily
    pool: ^Symbol_Pool,
}


Symbol :: struct{
    name: Token,
    resolved: bool,
    data: union{
        Type_Info,
        Function_Info,
        Local_Info,
        Foreign_Info,
        Foreign_Global_Info,
    }
}

Function_Info :: struct {
    param_ids: []Symbol_ID,
    return_type: Type_Info,
    locals_size: int,
    size_of_first_local: int, //when accessing locals it will be rbp - (offset + size_of_first_local)
}

Foreign_Info :: struct {
    return_type: Type_Info,
    num_args: int,
}

Foreign_Global_Info :: distinct Type_Info

Local_Info :: struct {
    address: int,
    type: Type_Info,
    constant: bool,
}

Type_Info :: struct {
    size: int,
    data: union {
        Type_Info_Null,
        Type_Info_Integer,
        Type_Info_Float,
        Type_Info_Bool,
        Type_Info_Byte,
        Type_Info_Pointer,
    }
}

Type_Info_Integer :: struct {}
Type_Info_Float :: struct  {}
Type_Info_Null :: struct {}
Type_Info_Bool :: struct {}
Type_Info_Byte :: struct {}
Type_Info_Pointer :: struct {pointing_at: ^Type_Info}


scope_open :: proc(using sm: ^Scope_Manager) {
    if ok := sa.push_back(&scopes, make(Symbol_Table)); !ok {
        panic("Fatal Compiler Error: Too many nested blocks")
    }
}

scope_close :: proc(using sm: ^Scope_Manager) {
    scope, ok := sa.pop_back_safe(&scopes)
    if !ok {
        panic("Fatal Compiler Error: Tried to close a scope, none were open")
    }
    delete_map(scope)
}

scope_find :: proc(using sm: ^Scope_Manager, symbol: Token) -> (Symbol_ID, bool){
    for i := scopes.len - 1; i >= 0; i -= 1 {
        if id, exists := sa.get(scopes, i)[ident(symbol)]; exists{
            return id, true
        }
    }
    error("Undeclared Identifier %v", symbol.location, ident(symbol))
    return -1, false
}

scope_register :: proc(using sm: ^Scope_Manager, info: Symbol) -> bool {
    current_scope := sa.get_ptr(&scopes, scopes.len - 1)
    name := ident(info.name)
    if name in current_scope{
        error("Re-definition of symbol %s", info.name.location, name)
        return false
    }
    current_scope[name] = pool_register(pool, info)
    return true
}

pool_register :: proc(pool: ^Symbol_Pool, info: Symbol) -> Symbol_ID {
    append(pool, info)
    return Symbol_ID(len(pool) - 1)
}

pool_get :: proc(pool: ^Symbol_Pool, id: Symbol_ID) -> Symbol {
    return pool[id]
}


NULL_INFO := Type_Info{size = 0, data = Type_Info_Null{}}
INTEGER_INFO := Type_Info{size = 8, data = Type_Info_Integer{}}
FLOAT_INFO := Type_Info{size = 8, data = Type_Info_Float{}}
BOOL_INFO := Type_Info{size = 1, data = Type_Info_Bool{}}
BYTE_INFO := Type_Info{size = 1, data = Type_Info_Byte{}}
scope_register_builtin_types :: proc(using sm: ^Scope_Manager) {
    scope_register(sm,  Symbol{resolved = true, name=Token{data = "float", kind = .Identifier}, data = FLOAT_INFO})
    scope_register(sm,  Symbol{resolved = true, name=Token{data = "int", kind = .Identifier}, data = INTEGER_INFO})
    scope_register(sm,  Symbol{resolved = true, name=Token{data = "bool", kind = .Identifier}, data = BOOL_INFO})
    scope_register(sm,  Symbol{resolved = true, name=Token{data = "byte", kind = .Identifier}, data = BYTE_INFO})
}

create_type_info :: proc(using sm: ^Scope_Manager, ast_node: Type_Node) -> (info: Type_Info, ok: bool) {
    switch ast_type in ast_node{
        case Symbol_Type:
            symbol_id, exists := scope_find(sm, ast_type)
            if !exists do return {}, false
            info, is_type := pool_get(pool, symbol_id).data.(Type_Info)
            if !is_type {
                error("Symbol %v was expected to be a type", ast_type.location, ident(ast_type))
                return {}, false
            }
            return info, true
        case Pointer_Type:
            pointing_at := new(Type_Info, symbol_allocator)
            pointing_at^ = create_type_info(sm, ast_type.pointing_at^) or_return
            return Type_Info{data = Type_Info_Pointer{pointing_at = pointing_at}, size = 8}, true
        case: panic("unreachable")
    }
}

//assumes all global symbols have been forward declared
scope_register_global_declaration :: proc(using sm: ^Scope_Manager, decl_node: Declaration_Node) -> bool {
    switch decl in decl_node{
        case Function_Node:
            data := Function_Info{}

            return_type, exists := decl.return_type.?
            if !exists{
                data.return_type = NULL_INFO
            }else{
                data.return_type = create_type_info(sm, decl.return_type.?) or_return
            }

            data.locals_size = 0 //this will be updated by ir generator
            
            symbol := &pool[scope_find(sm, decl.name) or_return] 
            symbol.resolved = true
            symbol.data = data
            return true 
        case Foreign_Function_Node:
            data := Foreign_Info{}

            return_type, exists := decl.return_type.?
            if !exists{
                data.return_type = NULL_INFO
            }else{
                data.return_type = create_type_info(sm, decl.return_type.?) or_return
            }
            data.num_args = len(decl.param_types)

            symbol := &pool[scope_find(sm, decl.name) or_return] 
            symbol.resolved = true
            symbol.data = data
            return true 
        
        case Foreign_Global_Node:
            type := create_type_info(sm, decl.type) or_return
            symbol := &pool[scope_find(sm, decl.name) or_return] 
            symbol.resolved = true
            symbol.data = Foreign_Global_Info(type)
            return true


    }
    panic("unreachable")
}

scope_register_variable :: proc(using sm: ^Scope_Manager, decl: Variable_Node, function_size: ^int, constant := false) -> bool {
    symbol := Symbol{resolved = true, name = decl.name, data = Local_Info{
        address = function_size^,
        type = create_type_info(sm, decl.type) or_return,
        constant = constant,
    }}
    function_size^ += symbol.data.(Local_Info).type.size
    scope_register(sm, symbol) or_return
    return true
}