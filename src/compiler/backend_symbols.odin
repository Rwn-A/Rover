package compiler

import "core:mem"
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
    }
}

Function_Info :: struct {
    param_names: []string,
    param_types: []Type_Info,
    return_type: Type_Info,
}

Local_Info :: struct {
    address: int,
    type: Type_Info,
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
Type_Info_Pointer :: struct {element_type: ^Type_Info}


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
    for i := scopes.len - 1; i <= 0; i -= 1 {
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

create_type_info :: proc(using sm: ^Scope_Manager, ast_node: Type_Node) -> (Type_Info, bool) {
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
        case: unimplemented("other types besides builtin")
    }
}

//assumes all global symbols have been forward declared
scope_register_global_declaration :: proc(using sm: ^Scope_Manager, decl_node: Declaration_Node) -> bool {
    switch decl in decl_node{
        case Function_Node:
            data := Function_Info{}

            param_name_builder := make([dynamic]string, sm.symbol_allocator)
            param_type_builder := make([dynamic]Type_Info, sm.symbol_allocator)
            for name in decl.param_names do append(&param_name_builder, ident(name))
            for type in decl.param_types do append(&param_type_builder, create_type_info(sm, type) or_return)
            data.param_names = param_name_builder[:]
            data.param_types = param_type_builder[:]

            return_type, exists := decl.return_type.?
            if !exists{
                data.return_type = NULL_INFO
            }else{
                data.return_type = create_type_info(sm, decl.return_type.?) or_return
            }
            
            symbol := &pool[scope_find(sm, decl.name) or_return] 
            symbol.resolved = true
            symbol.data = data
            return true 
    }
    unreachable()
}
// //enter a scope
// //for IR
// //add a scope block to the IR with the specified scope ID
// //when codegen looks up symbols it knows its current scope and can traverse upwards

// //for symbol table
// //call into it when opening a scope, set the parent and return the ID for the IR
// //keep track of the current scope and add symbols when encountered


// Symbol_ID :: distinct int
// Scope_ID :: distinct int
// Symbol_Pool :: struct {
//     all_symbols: map[Symbol_ID]Symbol, //codegen will use this as "scoping" no longer exists in IR
//     scopes: map[Scope_ID]Scope,
//     current_scope: Scope_ID,
//     next_scope_id: Scope_ID,
//     next_symbol_id: Symbol_ID,
//     allocator: mem.Allocator,
// }

// Scope :: struct {
//     parent_scope: Maybe(Scope_ID),
//     symbols: map[string]Symbol_ID,
// }

// Symbol :: struct{
//     resolved: bool,
//     data: union{
//         Type_Info,
//         Function_Info,
//         Local_Info,
//     }
// }

// Function_Info :: struct {
//     param_names: []string,
//     param_types: []Type_Info,
//     return_type: Type_Info,
// }

// Local_Info :: struct {
//     address: int,
//     type: Type_Info,
// }

// Type_Info :: struct {
//     size: int,
//     data: union {
//         Type_Info_Null,
//         Type_Info_Integer,
//         Type_Info_Float,
//         Type_Info_Bool,
//         Type_Info_Byte,
//         Type_Info_Pointer,
//         Type_Info_Struct,
//     }
// }

// Type_Info_Integer :: struct {}
// Type_Info_Float :: struct  {}
// Type_Info_Null :: struct {}
// Type_Info_Bool :: struct {}
// Type_Info_Byte :: struct {}
// Type_Info_Pointer :: struct {element_type: ^Type_Info}
// Type_Info_Struct :: struct {
//     field_names: []string,
//     field_types: []Type_Info,
//     field_offsets: []int,
// }

// symbol_pool_init :: proc(sm: ^Symbol_Pool, allocator: mem.Allocator) {

// }

// symbol_pool_open_global :: proc(using sp: ^Symbol_Pool, ast: []Declaration_Node) -> bool {
//     scope_id := symbol_pool_open_scope(sp)
//     assert(scope_id == 0)
//     scope := &scopes[scope_id]
//     scope.parent_scope = nil

//      //forward declare all symbols so they exist
//      for decl_node in ast{
//         switch decl in decl_node{
//             case Function_Node: symbol_pool_put(sp, decl.name, Symbol{resolved = false, data=nil}) or_return
//         }
//     }

//     //resolve all the symbols so the type info is known
//     for decl_node in ast{
//         switch decl in decl_node{
//             case Function_Node:
//                 data := Function_Info{}

//                 param_name_builder := make([dynamic]string, allocator)
//                 param_type_builder := make([dynamic]Type_Info, allocator)
//                 for name in decl.param_names do append(&param_name_builder, ident(name))
//                 for type in decl.param_types {
//                     append(&param_type_builder, create_type_info(sp, type) or_return)
//                 } 
//                 data.param_names = param_name_builder[:]
//                 data.param_types = param_type_builder[:]

//                 return_type, exists := decl.return_type.?
//                 if !exists{
//                     data.return_type = NULL_INFO
//                 }else{
//                     data.return_type = create_type_info(sp, decl.return_type.?) or_return
//                 }

//                 symbol_pool_update(sp, ident(decl.name), Symbol{resolved = true, data = data})
//         }
//     }

//     return true
    
// }

// symbol_pool_open_scope :: proc(using sp: ^Symbol_Pool) -> Scope_ID {
//     scope := Scope{}
//     defer next_scope_id += 1

//     scope.parent_scope = current_scope
//     scope.symbols = make(map[string]Symbol_ID, allocator = allocator)

//     scope_id := next_scope_id
//     current_scope = next_scope_id
//     scopes[scope_id] = scope

//     return scope_id
// }

// symbol_pool_leave_scope :: proc(using sp: ^Symbol_Pool) {
//     scope := &scopes[current_scope]
//     current_scope = scope.parent_scope.?
// }

// symbol_pool_find_tk :: proc(using sp: ^Symbol_Pool,  symbol: Token, initial_scope_id: Scope_ID = -1) -> (Symbol_ID, bool){
//     scope_id := initial_scope_id if initial_scope_id != -1 else current_scope

//     name := ident(symbol)
//     if symbol, exists := scopes[scope_id].symbols[name]; exists {
//         return symbol^, true
//     }

//     if parent, exists := scopes[scope_id].parent_scope.?; exists {
//         return symbol_pool_find_str(sp, name, parent)
//     }

//     error("Could not find identifier %v", symbol.location, name)
    
//     return {}, false
// }

// symbol_pool_find_str :: proc(using sp: ^Symbol_Pool, symbol: string, initial_scope_id: Scope_ID = -1) -> (Symbol_ID, bool){
//     scope_id := initial_scope_id if initial_scope_id != -1 else current_scope

//     if symbol, exists := scopes[scope_id].symbols[symbol]; exists {
//         return symbol^, true
//     }

//     if parent, exists := scopes[scope_id].parent_scope.?; exists {
//         return symbol_pool_find_str(sp, symbol, parent)
//     }

//     fatal("Could not find identifier %v", symbol)
    
//     return {}, false
// }

// symbol_pool_update :: proc(using sp: ^Symbol_Pool, name: string, data: Symbol) {
//     if symbol, exists := scopes[current_scope].symbols[name]; exists {
//         symbol^ = data
//     }else{
//         fatal("Tried to update symbol that did not exist in current scope")
//     }
// }

// symbol_pool_find_id :: proc(using sp: ^Symbol_Pool, symbol_id: Symbol_ID) -> Symbol_ID {
//     symbol, exists := all_symbols[symbol_id]
//     assert(exists)
//     return symbol
// }

// symbol_pool_find :: proc{symbol_pool_find_str, symbol_pool_find_tk, symbol_pool_find_id}

// symbol_pool_put :: proc(using sp: ^Symbol_Pool, token: Token, symbol: Symbol) -> bool{
//     name := ident(token)
//     all_symbols[next_symbol_id] = symbol
//     next_symbol_id += 1

//     scope := &scopes[current_scope]
//     if _, exists := scope.symbols[name]; exists {
//         error("Redefinition of symbol %v", token.location, name)
//         return false
//     }

//     scope.symbols[name] = &all_symbols[next_symbol_id]

//     return true
// }

// NULL_INFO := Type_Info{size = 0, data = Type_Info_Null{}}
// INTEGER_INFO := Type_Info{size = 8, data = Type_Info_Integer{}}
// FLOAT_INFO := Type_Info{size = 8, data = Type_Info_Float{}}
// BOOL_INFO := Type_Info{size = 1, data = Type_Info_Bool{}}
// BYTE_INFO := Type_Info{size = 1, data = Type_Info_Byte{}}
// register_builtin_types :: proc(using sp: ^Symbol_Pool) {
//     symbol_pool_put(sp, Token{data = "int", kind = .Identifier}, Symbol{resolved = true, data = INTEGER_INFO})
//     symbol_pool_put(sp, Token{data = "float", kind = .Identifier}, Symbol{resolved = true, data = FLOAT_INFO})
//     symbol_pool_put(sp, Token{data = "bool", kind = .Identifier}, Symbol{resolved = true, data = BOOL_INFO})
//     symbol_pool_put(sp, Token{data = "byte", kind = .Identifier}, Symbol{resolved = true, data = BYTE_INFO})
// }


// create_type_info :: proc(using sm: ^Symbol_Pool, ast_node: Type_Node) -> (Type_Info, bool) {
//     switch ast_type in ast_node{
//         case Symbol_Type:
//             symbol, exists := symbol_pool_find(sm, ast_type)
//             if !exists do return {}, false
//             info, is_type := symbol.data.(Type_Info)
//             if !is_type {
//                 error("Symbol %v was expected to be a type", ast_type.location, ident(ast_type))
//                 return {}, false
//             }
//             return info, true
//         case: unimplemented("other types besides builtin")
//     }
// }