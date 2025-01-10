package compiler

import "core:mem"
import "core:fmt"

AST :: []Declaration_Node

Declaration_Node :: union {
    Function_Node,
    //Variable_Node, (global vars / constants)
    //Struct_Node
}

Statement :: union {
    Variable_Node,
    Expression_Node,
    Return_Node,
    If_Node,
}

Function_Node :: struct {
    name: Token,
    params: []Variable_Node,
    return_type: Maybe(Type_Node),
    body: []Statement,
}

If_Node :: struct {
    comparison: Expression_Node,
    body: []Statement,
    else_body: []Statement,
}

Variable_Node :: struct {
    name: Token,
    type: Type_Node,
}

Symbol_Type :: Token
Type_Node :: union {
    Symbol_Type //types defined by a single symbol
    //pointer type
}

Return_Node :: distinct Expression_Node
Expression_Node :: union {
    Literal_Int,
    Literal_Bool,
    Literal_String,
    Literal_Float,
    Identifier_Node,
    ^Binary_Expression_Node,
    ^Unary_Expression_Node,
    Function_Call_Node,
}

Literal_Int :: distinct Token
Literal_Bool ::  distinct Token
Literal_String ::  distinct Token
Literal_Float :: distinct Token
Identifier_Node :: distinct Token

Binary_Expression_Node :: struct {
    lhs: Expression_Node,
    rhs: Expression_Node,
    operator: Token,
}

Unary_Expression_Node :: struct {
    rhs: Expression_Node,
    operator: Token,
}

Function_Call_Node :: struct {
    name: Token,
    args: []Expression_Node,
}

Parser :: struct {
    lexer: ^Lexer,
    token: Token,
    peek: Token,
}

parser_init :: proc(parser: ^Parser, lexer: ^Lexer) -> bool {
    parser.token = lexer_next(lexer) or_return
    parser.peek = lexer_next(lexer) or_return
    parser.lexer = lexer
    return true
}

//TODO confirm that the context does carry down to the other parse functions
parser_parse :: proc(using parser: ^Parser, node_allocator: mem.Allocator) -> (ast: AST, ok: bool) {
    context.allocator = node_allocator

    ast_builder := make([dynamic]Declaration_Node)
    for token.kind != .EOF{
        #partial switch token.kind {
            case .Fn: append(&ast_builder, parse_function_node(parser) or_return)
            case: error("Top-Level statement cannot begin with %v", token.location, token.kind)
        }
    }

    return ast_builder[:], true
}

@(private="file")
parser_advance :: proc(using parser: ^Parser) -> (ok: bool) {
    token = peek
    peek = lexer_next(lexer) or_return
    return true
}

@(private="file")
parser_assert :: proc(using parser: ^Parser, expected: ..TokenKind) ->  bool{
    for expect in expected{
        if token.kind != expect {
            error("Unexpected token %v expected %v", token.location, token.kind, expected)
            return false
        }
        if parser_advance(parser) == false do return false
    }
    return true
}   

//common use-case of assert is for identifiers but they are usually stored so this is handy
@(private="file")
parser_assert_identifier :: proc(using parser: ^Parser) -> (tk: Token, ok: bool) {
    initial := token
    if token.kind != .Identifier{
        error("Expected identifier found %s", token.location, token.kind)
        return Token{}, false
    }
    parser_advance(parser) or_return
    return initial, true
}

@(private="file")
parse_function_node :: proc(using parser: ^Parser) -> (node: Function_Node, ok: bool) {
    parser_advance(parser) or_return //consumes fn token
    node.name = parser_assert_identifier(parser) or_return

    parser_assert(parser, .Lparen) or_return

    param_builder := make([dynamic]Variable_Node)
    for token.kind != .Rparen{
        param_decl := parse_statement(parser) or_return
        if param, is_param := param_decl.(Variable_Node); is_param {
            append(&param_builder, param)
        }else{
            error("Expected parameter definition, got %v", node.name.location, param_decl)
            return {}, false
        }
        if token.kind == .Comma do parser_advance(parser) or_return
    }
    parser_assert(parser, .Rparen) or_return
    node.params = param_builder[:]

    if token.kind != .Lbrace{
        node.return_type = parse_type(parser) or_return
    }
    parser_assert(parser, .Lbrace) or_return

    //body builder lol
    body_builder := make([dynamic]Statement)
    for token.kind != .Rbrace{
        append(&body_builder, parse_statement(parser) or_return)
    }
    parser_assert(parser, .Rbrace)
    node.body = body_builder[:]

    return node, true
}

@(private="file")
parse_type :: proc(using parser: ^Parser) -> (type: Type_Node, ok:bool) {
    initial := token
    if initial.kind == .Identifier{
        parser_advance(parser) or_return
        return Symbol_Type(initial), true
    }
    unimplemented("other types")
}

//used for structs
@(private="file")
parse_name_type_pairs :: proc(using parser: ^Parser) -> (names: []Token, types: []Type_Node, ok: bool) {
    //these are allocated with the ast allocator and should not be deleted
    name_builder := make([dynamic]Token)
    type_builder := make([dynamic]Type_Node)
    for {
        name := parser_assert_identifier(parser) or_return
        parser_assert(parser, .Colon) or_return
        type := parse_type(parser) or_return 
        append(&name_builder, name)
        append(&type_builder, type)
        if token.kind == .Comma {
            parser_advance(parser) or_return
            continue
        }else{
            break
        }
    }
    return name_builder[:], type_builder[:], true
}

@(private="file")
parse_statement :: proc(using parser: ^Parser) -> (stmt: Statement, ok: bool) {
    initial := token
    #partial switch initial.kind {
        case .If:
            parser_advance(parser) or_return
            comparision := parse_primary_expression(parser, .Lowest) or_return
            parser_advance(parser) or_return
            parser_assert(parser, .Lbrace) or_return
            body_builder := make([dynamic]Statement)
            for token.kind != .Rbrace{
                append(&body_builder, parse_statement(parser) or_return)
            }
            parser_assert(parser, .Rbrace) or_return
            if token.kind != .Else do return If_Node{comparison = comparision, body = body_builder[:]}, true
            parser_advance(parser) or_return
            parser_assert(parser, .Lbrace) or_return
            else_builder := make([dynamic]Statement)
            for token.kind != .Rbrace{
                append(&else_builder, parse_statement(parser) or_return)
            }
            parser_assert(parser, .Rbrace) or_return
            return If_Node{comparison = comparision, body = body_builder[:], else_body = else_builder[:]}, true
        case .While: unimplemented("while")
        case .Identifier:
            if peek.kind != .Colon do return parse_expression(parser)
            parser_advance(parser) or_return //skip name
            parser_advance(parser) or_return //skip colon
            var_decl := Variable_Node{}
            var_decl.name = initial
            var_decl.type = parse_type(parser) or_return
            if token.kind == .Equal{
                //this tricks the parser into seeing the next thing as an assignment expression
                //I wouldnt say im happy with this but i didnt want the assignment to be part
                //of the variable declaration node
                parser.lexer.position = uint(token.location.position + 1)
                peek = token
                token = initial
                
            }
            return var_decl, true
        case .Return:
            parser_advance(parser)
            expr := parse_expression(parser) or_return
            return cast(Return_Node)expr, true
        case: return parse_expression(parser)
    }
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

TokenKindSet :: bit_set[TokenKind]
Operator_Token: TokenKindSet : {
    .Dash, .DashEqual, .Dot, .DoubleEqual,
    .Equal, .NotEqual, .Plus, .PlusEqual, .Equal,
    .Asterisk, .AsteriskEqual, .SlashForward, .SlashEqual,
    .LessThan, .LessThanEqual, .GreaterThan, .GreaterThanEqual,
}

@(private="file")
operator_precedence :: proc(kind: TokenKind) -> Operator_Precedence {
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

@(private="file")
parse_expression :: proc(using parser: ^Parser) -> (expr: Expression_Node, ok: bool) {
    expr = parse_primary_expression(parser, .Lowest) or_return
    if !line_end(token, peek) {
        error("Unexpected Token %v, Expected newline or ;", peek.location, peek.kind)
        return expr, false
    }
    if peek.kind == .SemiColon do parser_advance(parser) or_return //optional semicolon handling
    parser_advance(parser) or_return
    return expr, true
}

@(private="file")
parse_primary_expression :: proc(using parser: ^Parser, prec: Operator_Precedence) -> (expr: Expression_Node, ok: bool) {
    #partial switch token.kind {
        case .Integer: expr = cast(Literal_Int)token
        case .Float: expr = cast(Literal_Float)token
        case .True,. False: expr = cast(Literal_Bool)token
        case .String: expr = cast(Literal_String)token
        case .Lparen: expr = parse_grouped(parser) or_return
        case .Hat, .ExclamationMark, .Ampersand, .Dash: expr = parse_prefix(parser) or_return
        case .Identifier:
            #partial switch peek.kind {
                case .Lparen: 
                    expr = parse_call(parser) or_return
                case: expr = cast(Identifier_Node)token
            }
        case: {
            error("Expression cannot start with %v", token.location, token.kind)
            return nil, false
        }
    }

    for !line_end(token, peek) && prec < operator_precedence(peek.kind) {
        if peek.kind not_in Operator_Token do return expr, true
        parser_advance(parser) or_return
        expr = parse_infix(parser, expr) or_return
    }

    return expr, true
}

@(private="file")
parse_grouped :: proc(using parser: ^Parser) -> (expr: Expression_Node, ok: bool){
    parser_advance(parser) or_return
    expr = parse_primary_expression(parser, .Lowest) or_return
    if peek.kind != .Rparen {
        error("Unexpected token %v expected )", token.location, token.kind)
        return nil, false
    }
    parser_advance(parser) or_return
    return expr, true
}

@(private="file")
parse_call :: proc(using parser: ^Parser) -> (expr: Expression_Node, ok: bool) {
    name := parser_assert_identifier(parser) or_return
    parser_advance(parser) or_return

    arg_builder := make([dynamic]Expression_Node)
    for {
        append(&arg_builder, parse_primary_expression(parser, .Lowest) or_return)
        parser_advance(parser) or_return
        if token.kind == .Comma{
            parser_advance(parser) or_return
            continue
        }else{
            //parser_assert(parser, .Rparen) or_return
            break
        }
    }
    return Function_Call_Node{name = name, args = arg_builder[:]}, true
}

@(private="file")
parse_infix :: proc(using parser: ^Parser, lhs: Expression_Node) -> (expr: Expression_Node, ok: bool) {
    bin_expr := new(Binary_Expression_Node)
    bin_expr.lhs = lhs 
    bin_expr.operator = token

    prec := operator_precedence(token.kind)
    parser_advance(parser)

    //dot is right associative, subtracting 1 from the precedence seems to work for that
    if bin_expr.operator.kind == .Dot {
        bin_expr.rhs = parse_primary_expression(parser, Operator_Precedence(int(prec) - 1)) or_return
    } else {
        bin_expr.rhs = parse_primary_expression(parser, prec) or_return
    }

    return bin_expr, true
}

@(private="file")
parse_prefix :: proc(using parser: ^Parser) -> (expr: Expression_Node, ok: bool) {
    un_expr := new(Unary_Expression_Node);
    un_expr.operator = token
    parser_advance(parser) or_return
    un_expr.rhs = parse_primary_expression(parser, .Prefix) or_return
    return un_expr, true
}

@(private="file")
line_end :: proc(tk: Token, peek: Token) -> bool {
    return peek.location.row > tk.location.row || peek.kind == .EOF || peek.kind == .SemiColon
}