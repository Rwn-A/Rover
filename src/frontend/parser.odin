package frontend

import "base:runtime"

import "../shared"

ast_from_bytes :: proc(source: []byte, filepath: string, sa: runtime.Allocator) -> (ast: []Statement, ok: bool) {
    lexer := Lexer{
        sm = String_Manager{
            allocations = make([dynamic]string, sa),
            allocator = sa,
        },
        source = source,
        position = 0,
        cur_loc = shared.Rover_Location{
            row = 1,
            col = 1,
            filepath = filepath,
        },
    }

    token := lexer_next(&lexer) or_return
    peek := lexer_next(&lexer) or_return

    parser := Parser{
        lexer = &lexer,
        token = token,
        peek = peek,
    }

    roots := make([dynamic]Statement)

    for parser.token.kind != .EOF {
        if stmt, stmt_ok := parse_statement(&parser); stmt_ok {
            append(&roots, stmt)
        }else {
            return {}, false
        }
    }

    return roots[:], true
}


Parser :: struct {
    lexer: ^Lexer,

    token: Token,
    peek: Token,

    expression_buffer: [dynamic]Expression_Node
}

parser_advance :: proc(using parser: ^Parser) -> (ok: bool) {
    token = peek
    peek = lexer_next(lexer) or_return
    return true
}

parser_assert :: proc(using parser: ^Parser, expected: ..TokenType) ->  bool{
    for expect in expected{
        if token.kind != expect {
            shared.rover_error("Unexpected token %v expected %v", token.location, token.kind, expected)
            return false
        }
        if parser_advance(parser) == false do return false
    }
    return true
}

Statement :: union {
    ^Variable_Declaration,
    ^Function_Declaration,
    ^Struct_Declaration,
    ^Type_Alias,
    ^Import,
    Return,
    Expression,
}

Return :: distinct Expression

Variable_Declaration :: struct {
    name: Token,
    type: Maybe(Type_Node),
    value: Expression,
}

Function_Declaration :: struct {
    name: Token,
    return_type: Maybe(Type_Node),
    params: []Identifer_Type_Pair,
    body: []Statement,
}

Type_Alias :: struct {
    name: Token,
    type: Type_Node,
}

Struct_Declaration :: struct {
    name: Token,
    fields: []Identifer_Type_Pair,
}

Import :: struct {
    path: Token,
    alias: Token,
}

Type_Node :: union {
    ^Pointer_Type,
    Basic_Type,
    ^Array_type,
    ^Slice_Type,
}

Basic_Type :: distinct Token

Pointer_Type :: struct {
    pointing_to: Type_Node
}

Slice_Type :: struct {
    backing_type: Type_Node,
}

Array_type :: struct {
    length_token: Token,
    backing_type: Type_Node,
}

Identifer_Type_Pair :: struct {
    name: Token,
    type: Type_Node,
}

parse_statement :: proc(using parser: ^Parser) -> (stmt: Statement, ok: bool) {
    initial := token
    #partial switch token.kind {
        case .Identifier:
            if peek.kind != .Colon do return parse_expression(parser)
            parser_assert(parser, token.kind, .Colon) or_return
            #partial switch token.kind {
                case .Equal: return parse_var_decl(parser, initial, nil)
                case .Fn: return parse_function(parser, initial)
                case .Import: return parse_import(parser, initial)
                case .Struct: return parse_struct_decl(parser, initial)
                case .Alias: return parse_type_alias(parser, initial)
                case: return parse_var_decl(parser, initial, parse_type(parser) or_return)
            }
        case .If: unimplemented("if statements not implemented")
        case .For: unimplemented("for loops not implemented")
        case .While: unimplemented("while not implemented")
        case .Return:
            parser_advance(parser)
            expr, ok := parse_expression(parser)
            return cast(Return)expr, ok
        case: return parse_expression(parser)
    }

    return nil, true
}

parse_type :: proc(using parser: ^Parser) -> (typ: Type_Node, ok: bool) {
    tk := token
    parser_advance(parser) or_return
    #partial switch tk.kind {
        case .Identifier: return cast(Basic_Type)tk, true
        case .Hat:
            pointer_type := new(Pointer_Type)
            pointer_type.pointing_to = parse_type(parser) or_return
            return pointer_type, true
        case .Lbracket:
            //slice
            if token.kind == .Rbracket {
                parser_advance(parser) or_return
                slice_type := new(Slice_Type)
                slice_type.backing_type = parse_type(parser) or_return
                return slice_type, true
            }
            //fixed array
            array_type := new(Array_type)
            if token.kind != .Integer {
                panic("arrays with out number literal length unimplemented")
            }
            array_type.length_token = token
            parser_assert(parser, token.kind, .Rbracket)
            array_type.backing_type = parse_type(parser) or_return
            return array_type, true
        case:
            shared.rover_error("Unexpected token %s expected a type", token.location, token.kind)
            return nil, false
    }
}

parse_id_type_pair :: proc(using parser: ^Parser, end: TokenType) -> (pairs: []Identifer_Type_Pair, ok: bool) {
    pairs_builder := make([dynamic]Identifer_Type_Pair)

    for {
        ident := token
        parser_assert(parser, .Identifier, .Colon) or_return
        typ := parse_type(parser) or_return
        append(&pairs_builder, Identifer_Type_Pair{name = ident, type = typ})
        if token.kind != .Comma do break
        parser_advance(parser) or_return
        if token.kind == end do break
    }

    return pairs_builder[:], true
}

parse_var_decl :: proc(using parser: ^Parser, name: Token, type: Maybe(Type_Node)) -> (stmt: Statement, ok: bool) {
    var_decl := new(Variable_Declaration)
    var_decl.name = name
    var_decl.type = type

    parser_assert(parser, .Equal) or_return

    var_decl.value = parse_expression(parser) or_return

    return var_decl, true
}

parse_type_alias :: proc(using parser: ^Parser, name: Token) -> (stmt: Statement, ok: bool) {
    alias := new(Type_Alias)
    parser_assert(parser, token.kind, .Equal) or_return
    alias.name = name
    alias.type = parse_type(parser) or_return
    return alias, true
}

parse_struct_decl :: proc(using parser: ^Parser, name: Token) -> (stmt: Statement, ok: bool) {
    struct_decl := new(Struct_Declaration)
    struct_decl.name = name

    parser_assert(parser, token.kind, .Equal, .Lbrace) or_return

    struct_decl.fields = parse_id_type_pair(parser, .Rbrace) or_return

    parser_assert(parser, .Rbrace)

    return struct_decl, true
}

parse_import :: proc(using parser: ^Parser, name: Token) -> (stmt: Statement, ok: bool) {
    import_stmt := new(Import)
    import_stmt.alias = name

    parser_assert(parser, token.kind, .Equal) or_return
    import_stmt.path = token
    parser_assert(parser, .String)

    return import_stmt, true
}

parse_function :: proc(using parser: ^Parser, name: Token) -> (stmt: Statement, ok: bool) {
    func_decl := new(Function_Declaration)
    func_decl.name = name

    parser_assert(parser, token.kind, .Lparen) or_return

    if token.kind != .Rparen do func_decl.params = parse_id_type_pair(parser, .Rparen) or_return

    parser_assert(parser, .Rparen) or_return
    func_decl.return_type = token.kind == .Equal ? nil : parse_type(parser) or_return
    parser_assert(parser, .Equal, .Lbrace) or_return

    body_builder := make([dynamic]Statement) //great name

    for token.kind != .Rbrace{
        //TODO: try and parse another statement so multiple errors can be caught
        append(&body_builder, parse_statement(parser) or_return) 
    }

    parser_advance(parser) or_return

    func_decl.body = body_builder[:]

    return func_decl, true
}

symbol_name :: proc(stmt: Statement) -> Token {
    #partial switch value in stmt {
        case ^Function_Declaration: return value.name
        case ^Struct_Declaration: return value.name
        case ^Type_Alias: return value.name
        case ^Variable_Declaration: return value.name
        case: panic("Cannot get symbol name for statement type")
    }
}

expression_location :: proc(expr: Expression) -> shared.Rover_Location{
    expr_start := expr[0]
    switch expr_val in expr_start{
        case Unary_Expression: return expr_val.operator.location
        case Binary_Expression: return expr_val.operator.location
        case Assignment_Expression: return expr_val.op_loc
        case Literal_Bool: return expr_val.location
        case Literal_Float: return expr_val.location
        case Literal_String: return expr_val.location
        case Literal_Int: return expr_val.location
        case Identifier: return expr_val.location
        case:panic("Unreachable")

    }
}

Expression :: []Expression_Node

Expression_Ref :: distinct i16

Expression_Node :: union {
    Literal_Int,
    Literal_Bool,
    Literal_String,
    Literal_Float,
    Identifier,
    Binary_Expression,
    Unary_Expression,
    Assignment_Expression,
}

Literal_Int :: distinct Token
Literal_Bool ::  distinct Token
Literal_String ::  distinct Token
Literal_Float :: distinct Token
Identifier :: distinct Token

Binary_Expression :: struct {
    lhs: Expression_Ref,
    rhs: Expression_Ref,
    operator: Token,
}

Unary_Expression :: struct {
    expr: Expression_Ref,
    operator: Token,
}

Assignment_Expression :: struct {
    lhs: Expression_Ref,
    rhs: Expression_Ref,
    op_loc: shared.Rover_Location,
}

Operator_Token: TokenTypeSet : {
    .Dash, .DashEqual, .Dot, .DoubleEqual,
    .Equal, .NotEqual, .Plus, .PlusEqual, .Equal,
    .Asterisk, .AsteriskEqual, .SlashForward, .SlashEqual,
    .LessThan, .LessThanEqual, .GreaterThan, .GreaterThanEqual,
}

Operator_Precedence :: enum {
    Lowest,
    Equals,
    LessGreater,
    Sum,
    Product,
    Prefix,
    Highest,
}

operator_precedence :: proc(kind: TokenType) -> Operator_Precedence {
    #partial switch kind {
        case .NotEqual: return .Equals
        case .LessThan: return .LessGreater
        case .GreaterThan: return .LessGreater
        case .DoubleEqual: return .Equals
        case .Equal: return .Equals
        case .LessThanEqual: return .LessGreater
        case .GreaterThanEqual: return .LessGreater
        case .Plus: return .Sum
        case .Dash: return .Sum
        case .Asterisk: return .Product
        case .SlashForward: return .Product
        case .Dot: return .Highest
        case: return .Lowest
    }
}

parse_expression :: proc(using parser: ^Parser) -> (expr: Expression, ok: bool) {
    expression_buffer = make([dynamic]Expression_Node)
    parse_primary_expression(parser, .Lowest) or_return
    if !line_end(token, peek) {
        shared.rover_error("Unexpected Token %v, Expected newline or ;",peek.location, peek.kind)
        return expr, false
    }
    if peek.kind == .SemiColon do parser_advance(parser) or_return
    parser_advance(parser) or_return
    return expression_buffer[:], true
}


parse_primary_expression :: proc(using parser: ^Parser, prec: Operator_Precedence) -> (ref: Expression_Ref, ok: bool) {
    ref = Expression_Ref(len(expression_buffer))

    #partial switch token.kind {
        case .Integer: append(&expression_buffer, cast(Literal_Int)token)
        case .Float: append(&expression_buffer, cast(Literal_Float)token)
        case .True,. False: append(&expression_buffer, cast(Literal_Bool)token)
        case .String: append(&expression_buffer, cast(Literal_String)token)
        case .Lparen: ref = parse_grouped(parser) or_return
        case .Lbrace: unimplemented("arrays")
        case .Hat, .ExclamationMark, .Ampersand, .Dash: 
            Expression_Ref(len(expression_buffer))
            append(&expression_buffer, parse_prefix(parser) or_return)
        case .Identifier:
           #partial switch peek.kind {
               case .Lparen: unimplemented("function calls")
               case .Lbrace: unimplemented("struct")
               case: append(&expression_buffer, cast(Identifier)token)
           }
        case: {
            shared.rover_error("Expression cannot start with %v", token.location, token.kind)
            return ref, false
        }
    }

   
    for !line_end(token, peek) && prec < operator_precedence(peek.kind) {
        if peek.kind not_in Operator_Token do return ref, true
        parser_advance(parser) or_return
        expr := parse_infix(parser, ref) or_return
        ref = Expression_Ref(len(expression_buffer))
        append(&expression_buffer, expr)
    }
    
    return ref, true
}

parse_infix :: proc(using parser: ^Parser, lhs: Expression_Ref) -> (expr: Expression_Node, ok: bool) {
    bin_expr := Binary_Expression{lhs = lhs, operator = token}

    prec := operator_precedence(token.kind)
    parser_advance(parser) or_return

    //dot is right associative subtracting 1 from the precedence seems to work for that
    if bin_expr.operator.kind == .Dot {
        bin_expr.rhs = parse_primary_expression(parser, Operator_Precedence(int(prec) - 1)) or_return
    } else {
        bin_expr.rhs = parse_primary_expression(parser, prec) or_return
    }

    if bin_expr.operator.kind == .Equal{
        assign_expr := Assignment_Expression{lhs = bin_expr.lhs, rhs = bin_expr.rhs,op_loc = bin_expr.operator.location}
        return assign_expr, true 
    }

    return bin_expr, true
}

parse_prefix :: proc(using parser: ^Parser) -> (expr: Expression_Node, ok: bool) {
    un_expr := Unary_Expression{operator = token}
    parser_advance(parser) or_return
    un_expr.expr = parse_primary_expression(parser, .Prefix) or_return
    return un_expr, true
}

parse_grouped :: proc(using parser: ^Parser) -> (ref: Expression_Ref, ok: bool){
    parser_advance(parser) or_return
    ref = parse_primary_expression(parser, .Lowest) or_return
    if peek.kind != .Rparen {
        shared.rover_error("Unexpected token %v expected )", token.location, token.kind)
        return ref, false
    }
    parser_advance(parser) or_return
    return ref, true
}

line_end :: proc(tk: Token, peek: Token) -> bool {
    return peek.location.row > tk.location.row || peek.kind == .EOF || peek.kind == .SemiColon
}
