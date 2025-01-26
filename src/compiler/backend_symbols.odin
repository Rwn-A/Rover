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
    current_function: ^Symbol,
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
    },
    ast_node: Declaration_Node, //not safe to access after IR is generated, used in early stages of symbol resolving

}

Function_Info :: struct {
    param_ids: []Symbol_ID,
    return_type: Type_Info,
    locals_size: int,
}

Foreign_Info :: struct {
    return_type: Type_Info,
    arg_types: []Type_Info,
    builtin: bool,
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
        Type_Info_Array,
        Type_Info_Struct,
    }
}

Type_Info_Integer :: struct {}
Type_Info_Float :: struct  {}
Type_Info_Null :: struct {}
Type_Info_Bool :: struct {}
Type_Info_Byte :: struct {}
Type_Info_Pointer :: struct {pointing_at: ^Type_Info}
Type_Info_Array :: struct{element_type: ^Type_Info}
Type_Info_Struct :: struct {
    field_names: []Token,
    field_types: []Type_Info,
    field_offsets: []int,
    alignment: int,
}


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
CSTRING_INFO := Type_Info{size = 8, data = Type_Info_Pointer{pointing_at = &BYTE_INFO}}
scope_register_builtins :: proc(using sm: ^Scope_Manager) {
    scope_register(sm,  Symbol{resolved = true, name=Token{data = "float", kind = .Identifier}, data = FLOAT_INFO})
    scope_register(sm,  Symbol{resolved = true, name=Token{data = "int", kind = .Identifier}, data = INTEGER_INFO})
    scope_register(sm,  Symbol{resolved = true, name=Token{data = "bool", kind = .Identifier}, data = BOOL_INFO})
    scope_register(sm,  Symbol{resolved = true, name=Token{data = "byte", kind = .Identifier}, data = BYTE_INFO})
    scope_register(sm,  Symbol{resolved = true, name=Token{data = "cstring", kind = .Identifier}, data = CSTRING_INFO})

    //will be replaced with an import to a file that has these foreign declarations 
    //for now we will manually add them to every executable
    print_foreign_info := Foreign_Info{
        return_type = NULL_INFO,
        arg_types = {CSTRING_INFO},
        builtin = true,
    }
    scope_register(sm, Symbol{resolved = true, name=Token{data = "print", kind = .Identifier}, data=print_foreign_info})
}

create_type_info :: proc(using sm: ^Scope_Manager, ast_node: Type_Node) -> (info: Type_Info, ok: bool) {
    switch ast_type in ast_node{
        case Symbol_Type:
            symbol_id, exists := scope_find(sm, ast_type)
            if !exists do return {}, false
            if sym := pool_get(pool, symbol_id); sym.resolved == false {
                scope_register_global_declaration(sm, sym.ast_node) or_return
            }
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
        case Array_Type:
                element_type := new(Type_Info, symbol_allocator)
                element_type^ = create_type_info(sm, ast_type.element^) or_return
                length := ast_type.length
                return Type_Info{data = Type_Info_Array{element_type = element_type}, size = length * element_type.size}, true
        case: panic("unreachable")
    }
}

//assumes all global symbols have been forward declared
scope_register_global_declaration :: proc(using sm: ^Scope_Manager, decl_node: Declaration_Node) -> bool {
    switch decl in decl_node{
        case Function_Node:
            symbol := &pool[scope_find(sm, decl.name) or_return] 
            if symbol.resolved do return true
            data := Function_Info{}

            return_type, exists := decl.return_type.?
            if !exists{
                data.return_type = NULL_INFO
            }else{
                data.return_type = create_type_info(sm, decl.return_type.?) or_return
            }

            data.locals_size = 0 //this will be updated by ir generator
            
            symbol.resolved = true
            symbol.data = data
            return true 
        case Struct_Definition_Node:
            symbol := &pool[scope_find(sm, decl.name) or_return] 
            if symbol.resolved do return true
            data := Type_Info_Struct{}

            data.field_names = make([]Token, len(decl.fields))
            data.field_types = make([]Type_Info, len(decl.fields))
            data.field_offsets = make([]int, len(decl.fields))
            data.alignment = 0

            current_size: int = 0
            //current_offset: int = 0
            for field_node, i in decl.fields{
                field_type := create_type_info(sm, field_node.type) or_return
                data.field_types[i] = field_type
                data.field_names[i] = field_node.name

                alignment := get_alignment(field_type)
                if alignment > data.alignment do data.alignment = alignment
                offset := align_address(current_size, alignment)
                data.field_offsets[i] = offset

                current_size = offset + field_type.size
            }
            current_size = align_address(current_size, data.alignment)
            
            symbol.resolved = true
            symbol.data = Type_Info{size = current_size, data = data}
            return true 
        case Foreign_Function_Node:
            symbol := &pool[scope_find(sm, decl.name) or_return] 
            if symbol.resolved do return true
            data := Foreign_Info{}

            return_type, exists := decl.return_type.?
            if !exists{
                data.return_type = NULL_INFO
            }else{
                data.return_type = create_type_info(sm, decl.return_type.?) or_return
            }

            arg_builder := make([dynamic]Type_Info, symbol_allocator)
            for ast_type in decl.param_types{
                append(&arg_builder, create_type_info(sm, ast_type) or_return)
            }
            data.arg_types = arg_builder[:]
            
            symbol.resolved = true
            symbol.data = data
            return true 
        case Foreign_Global_Node:
            symbol := &pool[scope_find(sm, decl.name) or_return] 
            if symbol.resolved do return true
            type := create_type_info(sm, decl.type) or_return
            symbol.resolved = true
            symbol.data = Foreign_Global_Info(type)
            return true


    }
    panic("unreachable")
}

scope_register_variable :: proc(using sm: ^Scope_Manager, decl: Variable_Node, constant := false) -> bool {
    type := create_type_info(sm, decl.type) or_return
    current_fn_info := &current_function.data.(Function_Info)
    symbol := Symbol{resolved = true, name = decl.name, data = Local_Info{
        address = current_fn_info.locals_size + type.size, type = type, constant = constant,
    }}
    scope_register(sm, symbol) or_return
    current_fn_info.locals_size += type.size
    return true
}

get_alignment :: proc(type_info: Type_Info) -> int {
    #partial switch data in type_info.data{
        case Type_Info_Array: return get_alignment(data.element_type^)
        case Type_Info_Struct: return data.alignment
        case: return type_info.size
    }
}

//what do i need to add to an address to satisfy an alignment
align_address :: proc(address: int, alignment: int) -> int {
    // Ensure alignment is a power of 2
    if alignment <= 0 || (alignment & (alignment - 1)) != 0 {
        panic("Compiler Error: Tried to align a complex type")
    }

    // Calculate aligned address
    return (address + alignment - 1) & ~(alignment - 1);
}