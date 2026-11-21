package forseti

Span :: struct {
	offset: u32,
	len:    u32,
}

String_Id :: distinct u32
EMPTY_STRING :: String_Id(0)

Node_Id :: distinct u32
INVALID_NODE :: Node_Id(0)

Expr_Id :: distinct u32
INVALID_EXPR :: Expr_Id(0)

Schema_Id :: distinct u32
Binding_Id :: distinct u32
Table_Id :: distinct u32
Rule_Id :: distinct u32
Query_Id :: distinct u32
Enum_Id :: distinct u32

INVALID_ID :: max(u32)

Entity_Id :: distinct u64
Time_Ns :: distinct i64

Enum_Val :: struct {
	enum_id: u32,
	variant: u32,
}

Value :: union {
	bool,
	i32,
	i64,
	f64,
	String_Id,
	Entity_Id,
	Time_Ns,
	Enum_Val,
}
#assert(size_of(Value) == 16)

Type_Kind :: enum u8 {
	Unknown,
	Bool,
	I32,
	I64,
	F64,
	String,
	Entity,
	Time,
	Enum,
	Fact,
	Table_Result,
}

Type_Ref :: struct {
	kind:   Type_Kind,
	ref_id: u32,
}

Hit_Policy :: enum u8 {
	First,
	Unique,
	Any,
	Priority,
	Collect,
	Collect_Sum,
	Collect_Min,
	Collect_Max,
	Collect_Count,
	Merge,
	Reverse_Merge,
}

Table_Verify_Flag :: enum u8 {
	Complete,
	No_Overlap,
	No_Dead_Rules,
	Strict,
}

Table_Verify_Flags :: bit_set[Table_Verify_Flag; u8]

Binding_Kind :: enum u8 {
	Source,
	Derived,
}

Accum_Op :: enum u8 {
	Count,
	Sum,
	Min,
	Max,
	Avg,
	Distinct,
	Collect,
}

Unary_Op :: enum u8 {
	Neg,
	Not,
}

Binary_Op :: enum u8 {
	Add,
	Sub,
	Mul,
	Div,
	Mod,
	Eq,
	Neq,
	Lt,
	Lte,
	Gt,
	Gte,
	And,
	Or,
}

merge_spans :: proc "contextless" (a, b: Span) -> Span {
	start := min(a.offset, b.offset)
	end := max(a.offset + a.len, b.offset + b.len)
	return Span{offset = start, len = end - start}
}
