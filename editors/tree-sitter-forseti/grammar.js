/// <reference types="tree-sitter-cli/dsl" />
// Tree-sitter grammar for Forseti (.forseti) policies and DMN decision tables.

module.exports = grammar({
  name: "forseti",

  extras: ($) => [
    /\s/,
    $.line_comment,
    $.block_comment,
  ],

  word: ($) => $.identifier,

  rules: {
    source_file: ($) => seq(
      optional($.module_decl),
      repeat($._declaration),
    ),

    _declaration: ($) => choice(
      $.schema_decl,
      $.binding_decl,
      $.table_decl,
      $.rule_decl,
      $.query_decl,
    ),

    module_decl: ($) => seq("module", $.identifier, "version", $.string_literal),

    schema_decl: ($) => seq(
      "schema",
      $.identifier,
      "{",
      commaSep($.field_decl),
      "}",
    ),

    field_decl: ($) => seq($.identifier, ":", $.type_spec),

    type_spec: ($) => choice(
      "bool",
      "i32",
      "i64",
      "f64",
      "string",
      "entity",
      "time",
      seq("enum", "(", commaSep1($.string_literal), ")"),
      $.identifier,
    ),

    binding_decl: ($) => seq(
      choice("source", "derived"),
      field("name", $.identifier),
      ":",
      field("schema", $.identifier),
      "at",
      $.selector_path,
    ),

    selector_path: ($) => seq(
      repeat1(seq(".", $.identifier)),
      optional(seq("[", choice($.variable, "*", $.string_literal), "]")),
    ),

    table_decl: ($) => seq(
      "table",
      field("name", $.identifier),
      "version",
      $.string_literal,
      "hit",
      $.hit_policy,
      optional($.verify_clause),
      "{",
      $.inputs_block,
      $.outputs_block,
      $.rows_block,
      "}",
    ),

    hit_policy: ($) => choice(
      "First",
      "Unique",
      "Any",
      "Priority",
      "Collect",
      "Collect_Sum",
      "Collect_Min",
      "Collect_Max",
      "Collect_Count",
      "Merge",
      "Reverse_Merge",
    ),

    verify_clause: ($) => seq("verify", "(", commaSep1($.identifier), ")"),

    inputs_block: ($) => seq("inputs", "{", commaSep($.table_col_decl), "}"),
    outputs_block: ($) => seq("outputs", "{", commaSep($.table_col_decl), "}"),

    table_col_decl: ($) => seq(
      $.identifier,
      ":",
      $.type_spec,
      optional(seq("cost", $.integer_literal)),
    ),

    rows_block: ($) => seq("rows", "{", repeat($.table_row), "}"),

    table_row: ($) => seq(
      field("id", $.identifier),
      ":",
      $._table_cell,
      repeat(seq("|", $._table_cell)),
      "||",
      $._table_cell,
      repeat(seq("|", $._table_cell)),
      ";",
    ),

    _table_cell: ($) => choice("-", $.expr),

    rule_decl: ($) => seq(
      "rule",
      field("name", $.identifier),
      optional(seq("phase", $.string_literal)),
      optional(seq("salience", optional("-"), $.integer_literal)),
      "{",
      optional($.when_block),
      optional($.then_block),
      optional($.effect_block),
      "}",
    ),

    when_block: ($) => seq("when", "{", repeat($._clause), "}"),
    then_block: ($) => seq("then", "{", repeat($._action), "}"),
    effect_block: ($) => seq("effect", $.string_literal, "{", commaSep($.field_assign), "}"),

    query_decl: ($) => seq(
      "query",
      field("name", $.identifier),
      "(",
      commaSep($.field_decl),
      ")",
      "{",
      repeat($._clause),
      "}",
    ),

    _clause: ($) => choice(
      seq("where", $.expr),
      seq("not", choice($.pattern_clause, seq("(", $._clause, ")"))),
      seq("exists", $.pattern_clause),
      seq($.variable, ":=", "decide", $.identifier, "(", commaSep($.field_assign), ")"),
      seq($.variable, ":=", $.identifier, "(", commaSep($.expr), ")", "from", $.pattern_clause),
      seq(optional(seq($.variable, ":=")), $.pattern_clause),
      $.eav_triple,
    ),

    pattern_clause: ($) => seq($.identifier, "(", commaSep($.field_assign), ")"),

    field_assign: ($) => seq($.identifier, ":", $.expr),

    eav_triple: ($) => seq("[", $.expr, ",", $.expr, ",", $.expr, "]"),

    _action: ($) => choice(
      seq(
        choice("assert", "assert!"),
        choice($.pattern_clause, $.eav_triple),
        optional("unconditional"),
      ),
      seq("retract", $.variable),
    ),

    expr: ($) => prec.left(1, choice(
      $.binary_expr,
      $.unary_expr,
      $.range_expr,
      $.in_expr,
      $.field_access,
      $.call_expr,
      $.variable,
      $.identifier,
      $.integer_literal,
      $.float_literal,
      $.string_literal,
      $.boolean_literal,
      seq("(", $.expr, ")"),
    )),

    unary_expr: ($) => prec(6, seq(choice("-", "not", "!", ">=", "<=", ">", "<", "==", "!="), $.expr)),
    binary_expr: ($) => prec.left(2, seq($.expr, choice("or", "and", "==", "!=", "<", "<=", ">", ">=", "+", "-", "*", "/", "%"), $.expr)),
    range_expr: ($) => prec.left(4, seq($.expr, choice("..", "..="), $.expr)),
    in_expr: ($) => prec(4, seq(optional($.expr), "in", "(", commaSep1($.expr), ")")),
    field_access: ($) => prec.left(7, seq($.expr, ".", $.identifier)),
    call_expr: ($) => prec(7, seq($.identifier, "(", commaSep($.expr), ")")),

    boolean_literal: (_) => choice("true", "false"),
    variable: (_) => /\?[A-Za-z_][A-Za-z0-9_]*/,
    identifier: (_) => /[A-Za-z_][A-Za-z0-9_]*/,
    integer_literal: (_) => /[0-9][0-9_]*/,
    float_literal: (_) => /[0-9][0-9_]*\.[0-9][0-9_]*(?:[eE][+-]?[0-9][0-9_]*)?/,
    string_literal: (_) => /"(?:[^"\\]|\\["\\ntr0])*"/,
    line_comment: (_) => token(seq("//", /[^\n]*/)),
    block_comment: (_) => token(seq("/*", /[^*]*\*+([^/*][^*]*\*+)*/, "/")),
  },
});

function commaSep(rule) {
  return optional(commaSep1(rule));
}

function commaSep1(rule) {
  return seq(rule, repeat(seq(",", rule)));
}
