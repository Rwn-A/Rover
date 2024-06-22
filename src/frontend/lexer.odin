package frontend

import "base:runtime"

import "core:mem/virtual"
import "core:strings"
import "core:fmt"
import "core:unicode"
import "core:unicode/utf8"
import "core:strconv"

import "../shared"


TokenTypeSet :: bit_set[TokenType]

TokenType :: enum {
    Identifier,
    Float,
    Integer,
    String,

    Lparen,
    Rparen,
    Lbrace,
    Rbrace,
    Lbracket,
    Rbracket,

    If,
    Else,
    While,
    For,
    Return,
    Fn,
    True,
    False,
    Import,
    In,
    Alias,
    Struct,

    Dot,
    Comma,
    SemiColon,
    Colon,
    Hat,
    Equal,
    Ampersand,

    DoubleEqual,
    NotEqual,
    LessThanEqual,
    GreaterThanEqual,
    LessThan,
    GreaterThan,
    ExclamationMark,
    Plus,
    Dash,
    Asterisk,
    SlashForward,
    PlusEqual,
    DashEqual,
    AsteriskEqual,
    SlashEqual,

    EOF,
}

TokenData :: union {
    string,
    int,
    f64,
}

Token :: struct {
    kind: TokenType,
    data: TokenData,
    location: shared.Rover_Location,
}

//saves strings that may need to be kept around after the file is closed
String_Manager :: struct {
    allocations: [dynamic]string,
    allocator: runtime.Allocator,
}

save_string :: proc(sm: ^String_Manager, str: string) -> string {
    for saved_str, i in sm.allocations {
        if str == saved_str do return saved_str //TODO confirm this comparison compares deeply
    }
    saved_string := strings.clone(str, sm.allocator)
    append(&sm.allocations, saved_string)
    return saved_string
}


Lexer :: struct {
    sm: String_Manager,

    source: []byte,
    position: uint,

    cur_loc: shared.Rover_Location,
}

lexer_next :: proc(using lexer: ^Lexer) -> (token:Token, ok: bool) {
    eof := lexer_skip_whitespace(lexer)

    current_token := Token{kind = .EOF, location = cur_loc, data = nil}

    if eof do return current_token, true


    switch lexer_char(lexer) {
        case '.': current_token.kind = .Dot
        case ',': current_token.kind = .Comma
        case ';': current_token.kind = .SemiColon
        case '^': current_token.kind = .Hat
        case '&': current_token.kind = .Ampersand
        case ':': current_token.kind = .Colon
        case '(': current_token.kind = .Lparen
        case ')': current_token.kind = .Rparen
        case '{': current_token.kind = .Lbrace
        case '}': current_token.kind = .Rbrace
        case '[': current_token.kind = .Lbracket
        case ']': current_token.kind = .Rbracket
        case 'A'..='z': current_token.kind, current_token.data = lexer_lex_word(lexer)
        case '0'..='9': current_token.kind, current_token.data = lexer_lex_number(lexer)
        case '"':
            current_token.kind = .String
            lexer_adv(lexer)
            if current_token.data = lexer_lex_string(lexer); current_token.data == nil {
                shared.rover_error("String literal has no matching \"", cur_loc)
                return Token{}, false
            }
        case '=': current_token.kind = lexer_lex_followed_by_equal(lexer, .Equal, .DoubleEqual)
        case '!': current_token.kind = lexer_lex_followed_by_equal(lexer, .ExclamationMark, .NotEqual)
        case '<': current_token.kind = lexer_lex_followed_by_equal(lexer,  .LessThan, .LessThanEqual)
        case '>': current_token.kind = lexer_lex_followed_by_equal(lexer, .GreaterThan, .GreaterThanEqual)
        case '+': current_token.kind = lexer_lex_followed_by_equal(lexer, .Plus, .PlusEqual)
        case '-': current_token.kind = lexer_lex_followed_by_equal(lexer, .Dash, .DashEqual)
        case '/':
            //comments
            if lexer_peek(lexer) == '/' {
                for lexer_peek(lexer) != '\n' && lexer_peek(lexer) != 0 do lexer_adv(lexer)
                lexer_adv(lexer)
                return lexer_next(lexer)
            }else { // /= operator
                current_token.kind = lexer_lex_followed_by_equal(lexer, .SlashForward, .SlashEqual)
            }
        case '*': current_token.kind = lexer_lex_followed_by_equal(lexer, .Asterisk, .AsteriskEqual)

        case: {
            shared.rover_error("Unexpected Character %c", cur_loc, lexer_char(lexer))
            return Token{}, false
        }

    }

    lexer_adv(lexer)

    return current_token, true
}

//any token that matches ?= such as <=, +=, ==, !=
@(private="file")
lexer_lex_followed_by_equal :: proc(using lexer: ^Lexer, false_case: TokenType, true_case: TokenType) -> TokenType {
    if lexer_peek(lexer) != '=' do return false_case
    lexer_adv(lexer)
    return true_case
}

@(private="file")
lexer_lex_word :: proc(using lexer: ^Lexer) -> (TokenType, TokenData) {
    start_position := position
    loop: for {
        switch lexer_peek(lexer) {
            case 'A'..='z', '0'..='9', '_': lexer_adv(lexer)
            case: break loop
        }
    }

    text := transmute(string)source[start_position:position + 1]
    kind: TokenType = .Identifier

    //could replace with a map but this is fine for now
    switch text {
        case "if": kind = .If
        case "while": kind = .While
        case "return": kind = .Return
        case "else": kind = .Else
        case "struct": kind = .Struct
        case "import": kind = .Import
        case "for": kind = .For
        case "fn": kind = .Fn
        case "alias": kind = .Alias
        case "in": kind = .In
        case "true": kind = .True
        case "false": kind = .False
    }

    if kind != .Identifier do return kind, nil //keywords dont need data

    text = save_string(&sm, text)

    return kind, text
}

@(private="file")
lexer_lex_number :: proc(using lexer: ^Lexer) -> (TokenType, TokenData) {
    start_position := position
    loop: for {
        switch lexer_peek(lexer) {
            case '0'..='9', '_', '.': lexer_adv(lexer)
            case: break loop
        }
    }
    text := transmute(string)source[start_position:position + 1]

    if strings.contains_rune(text, '.')  {
        value, ok := strconv.parse_f64(text)
        if !ok {
            shared.rover_error("Could not generate number from %s", cur_loc, text)
        }
        return .Float, value
    }

    value, ok := strconv.parse_int(text)
    if !ok {
        shared.rover_error("Could not generate number from %s", cur_loc, text)
    }
    

    return .Integer, value
}

@(private="file")
lexer_lex_string :: proc(using lexer: ^Lexer) -> TokenData {
    start_position := position
    loop: for {
        switch lexer_peek(lexer) {
            case '"': break loop
            case 0, '\n': return nil
            case: lexer_adv(lexer)
        }
    }
    lexer_adv(lexer)

    text := transmute(string)source[start_position:position]

    text = save_string(&sm, text)

    return text
}

//lexer state control functions

@(private="file")
lexer_skip_whitespace :: proc(using lexer: ^Lexer) -> (eof:bool) {
    for {
        switch lexer_char(lexer) {
            case ' ', '\t', '\r': lexer_adv(lexer)
            case '\n': cur_loc.row += 1; cur_loc.col = 0; lexer_adv(lexer)
            case 0: return true
            case: return false
        }
    }
}

@(private="file")
lexer_char :: proc(using lexer: ^Lexer) -> byte {
    return position < len(source) ? source[position] : 0
}

@(private="file")
lexer_peek :: proc(using lexer: ^Lexer) -> byte {
    return position + 1 < len(source) ? source[position + 1] : 0
}

@(private="file")
lexer_adv :: proc(using lexer: ^Lexer) {
    cur_loc.col += 1; position += 1
}