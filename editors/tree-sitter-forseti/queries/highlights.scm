; Tree-sitter highlight queries for Forseti (.forseti)

[
  "module"
  "import"
  "version"
  "schema"
  "source"
  "derived"
  "at"
  "table"
  "hit"
  "verify"
  "inputs"
  "outputs"
  "rows"
  "cost"
  "rule"
  "phase"
  "salience"
  "when"
  "then"
  "effect"
  "where"
  "decide"
  "assert"
  "assert!"
  "unconditional"
  "retract"
  "from"
  "query"
  "enum"
] @keyword

[
  "not"
  "exists"
  "and"
  "or"
  "in"
] @keyword.operator

[
  "bool"
  "i32"
  "i64"
  "f64"
  "string"
  "entity"
  "time"
] @type.builtin

(hit_policy) @constant.builtin
[
  "true"
  "false"
] @boolean
(variable) @variable
(string_literal) @string
(integer_literal) @number
(float_literal) @number.float
(line_comment) @comment
(block_comment) @comment

(binding_decl name: (identifier) @variable.definition)
(binding_decl schema: (identifier) @type)
(selector_path) @property
(table_decl name: (identifier) @function.definition)
(table_row id: (identifier) @label)
(rule_decl name: (identifier) @function.definition)
(query_decl name: (identifier) @function.definition)
(pattern_clause (identifier) @type)
(field_assign (identifier) @property)

[
  "|"
  "||"
  "-"
  ":="
  ".."
  "..="
  "=="
  "!="
  "<"
  "<="
  ">"
  ">="
  "+"
  "*"
  "/"
  "%"
  "!"
] @operator
