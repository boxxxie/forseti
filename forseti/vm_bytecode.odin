package forseti

import "core:mem"

Opcode :: enum u8 {
	Halt = 0,
	Load_Const,
	Load_Var,
	Move,
	Load_Field,
	Add,
	Sub,
	Mul,
	Div,
	Mod,
	Neg,
	Eq,
	Neq,
	Lt,
	Lte,
	Gt,
	Gte,
	Not,
	And,
	Or,
	Jmp,
	Jmp_If_False,
	Jmp_If_True,
	Decide_Call,
	Load_Decide_Out,
	In_Range,
}

Instruction :: struct {
	op:  Opcode,
	dst: u8,
	lhs: u8,
	rhs: u8,
}
#assert(size_of(Instruction) == 4)

Vm_Error :: enum u8 {
	None = 0,
	Register_Overflow,
	Unsupported_Expr,
	Trap_Div_By_Zero,
	Trap_Int_Overflow,
	Type_Mismatch,
	Step_Limit_Exceeded,
	Unknown_Table,
	Missing_Field,
}

Field_Access_Desc :: struct {
	fact_slot:     u8,
	field_idx:     i16,
	segments:      []string,
	expected_type: Type_Kind,
}

Decide_Arg_Spec :: struct {
	col_idx: u8,
	reg:     u8,
}

Decide_Call_Desc :: struct {
	table_idx:   u32,
	result_slot: u8,
	args:        []Decide_Arg_Spec,
}

Range_Desc :: struct {
	lo:     Value,
	hi:     Value,
	lo_inc: bool,
	hi_inc: bool,
}

Bytecode_Program :: struct {
	code:         []Instruction,
	consts:       []Value,
	field_refs:   []Field_Access_Desc,
	decide_calls: []Decide_Call_Desc,
	ranges:       []Range_Desc,
	max_regs:     u16,
	allocator:    mem.Allocator,
}

Vm_Fact_Slot_Desc :: struct {
	var_name:  String_Id,
	schema_id: Schema_Id,
}

Vm_Decide_Slot_Desc :: struct {
	var_name:  String_Id,
	table_idx: u32,
}

Vm_Compile_Env :: struct {
	ir:           ^Rulebase_IR,
	tables:       []Compiled_Table,
	var_names:    map[String_Id]u8,
	fact_descs:   []Vm_Fact_Slot_Desc,
	decide_descs: []Vm_Decide_Slot_Desc,
}

@(private)
Reg_Alloc :: struct {
	used:     [256]bool,
	max_used: u16,
}

@(private)
reg_alloc :: proc(ra: ^Reg_Alloc) -> (reg: u8, ok: bool) {
	for i := 0; i < 256; i += 1 {
		if !ra.used[i] {
			ra.used[i] = true
			if u16(i + 1) > ra.max_used {
				ra.max_used = u16(i + 1)
			}
			return u8(i), true
		}
	}
	return 0, false
}

@(private)
reg_free :: proc(ra: ^Reg_Alloc, reg: u8) {
	ra.used[reg] = false
}

@(private)
Vm_Compiler :: struct {
	env:          ^Vm_Compile_Env,
	ra:           Reg_Alloc,
	code:         [dynamic]Instruction,
	consts:       [dynamic]Value,
	field_refs:   [dynamic]Field_Access_Desc,
	decide_calls: [dynamic]Decide_Call_Desc,
	ranges:       [dynamic]Range_Desc,
	alloc:        mem.Allocator,
}

vm_program_destroy :: proc(p: ^Bytecode_Program) {
	if p == nil {
		return
	}
	if p.allocator.procedure != nil {
		for fr in p.field_refs {
			delete(fr.segments, p.allocator)
		}
		for dc in p.decide_calls {
			delete(dc.args, p.allocator)
		}
		delete(p.code, p.allocator)
		delete(p.consts, p.allocator)
		delete(p.field_refs, p.allocator)
		delete(p.decide_calls, p.allocator)
		delete(p.ranges, p.allocator)
	}
	p^ = {}
}

@(private)
vmc_add_const :: proc(c: ^Vm_Compiler, v: Value) -> u16 {
	for existing, i in c.consts {
		if existing == v {
			return u16(i)
		}
	}
	idx := u16(len(c.consts))
	append(&c.consts, v)
	return idx
}

@(private)
vmc_emit_load_const :: proc(c: ^Vm_Compiler, dst: u8, v: Value) -> Vm_Error {
	idx := vmc_add_const(c, v)
	append(&c.code, Instruction{
		op  = .Load_Const,
		dst = dst,
		lhs = u8(idx >> 8),
		rhs = u8(idx & 0xff),
	})
	return .None
}

@(private)
vmc_find_table :: proc(c: ^Vm_Compiler, name: String_Id) -> (u32, bool) {
	target := ir_string(c.env.ir, name)
	for &tbl, i in c.env.tables {
		if interner_get(&tbl.interner, tbl.table_name) == target || target == compiled_table_string(&tbl, tbl.table_name) {
			return u32(i), true
		}
	}
	for tbl, i in c.env.ir.tables {
		if tbl.name == name {
			return u32(i), true
		}
	}
	return 0, false
}

@(private)
vmc_collect_field_chain :: proc(
	c: ^Vm_Compiler,
	eid: Expr_Id,
	segs_out: ^[dynamic]String_Id,
) -> (base: Expr_Id, ok: bool) {
	cur := eid
	depth := 0
	for cur != INVALID_EXPR && int(cur) < len(c.env.ir.exprs) {
		depth += 1
		if depth > 64 {
			return INVALID_EXPR, false
		}
		e := c.env.ir.exprs[cur]
		if e.kind == .Field_Access {
			append(segs_out, e.str_id)
			cur = e.lhs
			continue
		}
		// Reverse collected segments in place so root field comes first.
		n := len(segs_out)
		for i := 0; i < n / 2; i += 1 {
			segs_out[i], segs_out[n - 1 - i] = segs_out[n - 1 - i], segs_out[i]
		}
		return cur, true
	}
	return INVALID_EXPR, false
}

@(private)
vmc_compile_field_access :: proc(c: ^Vm_Compiler, eid: Expr_Id) -> (reg: u8, err: Vm_Error) {
	segs := make([dynamic]String_Id, 0, 4, context.temp_allocator)
	base_eid, chain_ok := vmc_collect_field_chain(c, eid, &segs)
	if !chain_ok || base_eid == INVALID_EXPR || len(segs) == 0 {
		return 0, .Unsupported_Expr
	}
	base_expr := c.env.ir.exprs[base_eid]
	if base_expr.kind != .Var {
		return 0, .Unsupported_Expr
	}

	// Check decide result slot first (e.g. `?gate.action`).
	if len(segs) == 1 {
		for dd, di in c.env.decide_descs {
			if dd.var_name == base_expr.str_id && int(dd.table_idx) < len(c.env.ir.tables) {
				tbl := c.env.ir.tables[dd.table_idx]
				col_idx, col_ok := find_table_col_idx(tbl.outputs, segs[0])
				if !col_ok {
					return 0, .Missing_Field
				}
				r, r_ok := reg_alloc(&c.ra)
				if !r_ok {
					return 0, .Register_Overflow
				}
				append(&c.code, Instruction{
					op  = .Load_Decide_Out,
					dst = r,
					lhs = u8(di),
					rhs = u8(col_idx),
				})
				return r, .None
			}
		}
	}

	// Check bound pattern fact slots (e.g. `?raw.employees` or `?raw.address.country`).
	for fd, fi in c.env.fact_descs {
		if fd.var_name == base_expr.str_id {
			field_idx := i16(-1)
			exp_type := Type_Kind.Unknown
			if len(segs) == 1 && u32(fd.schema_id) != INVALID_ID && int(fd.schema_id) < len(c.env.ir.schemas) {
				schema := c.env.ir.schemas[fd.schema_id]
				for f, sfi in schema.fields {
					if f.name == segs[0] {
						field_idx = i16(sfi)
						exp_type = f.type.kind
						break
					}
				}
			}
			str_segs := make([]string, len(segs), c.alloc)
			for sid, si in segs {
				str_segs[si] = ir_string(c.env.ir, sid)
			}
			ref_idx := u16(len(c.field_refs))
			append(&c.field_refs, Field_Access_Desc{
				fact_slot     = u8(fi),
				field_idx     = field_idx,
				segments      = str_segs,
				expected_type = exp_type,
			})
			r, r_ok := reg_alloc(&c.ra)
			if !r_ok {
				return 0, .Register_Overflow
			}
			append(&c.code, Instruction{
				op  = .Load_Field,
				dst = r,
				lhs = u8(ref_idx >> 8),
				rhs = u8(ref_idx & 0xff),
			})
			return r, .None
		}
	}

	return 0, .Missing_Field
}

@(private)
find_table_col_idx :: proc(cols: []Table_Col_Def, name: String_Id) -> (int, bool) {
	for c, i in cols {
		if c.name == name {
			return i, true
		}
	}
	return -1, false
}

@(private)
vmc_compile_expr :: proc(c: ^Vm_Compiler, eid: Expr_Id) -> (reg: u8, err: Vm_Error) {
	if eid == INVALID_EXPR || int(eid) >= len(c.env.ir.exprs) {
		return 0, .Unsupported_Expr
	}
	e := c.env.ir.exprs[eid]
	switch e.kind {
	case .Invalid, .Wildcard, .Ident:
		return 0, .Unsupported_Expr

	case .Lit_Bool:
		r, ok := reg_alloc(&c.ra)
		if !ok {
			return 0, .Register_Overflow
		}
		vmc_emit_load_const(c, r, e.bool_val)
		return r, .None

	case .Lit_Int:
		r, ok := reg_alloc(&c.ra)
		if !ok {
			return 0, .Register_Overflow
		}
		vmc_emit_load_const(c, r, e.int_val)
		return r, .None

	case .Lit_Float:
		r, ok := reg_alloc(&c.ra)
		if !ok {
			return 0, .Register_Overflow
		}
		vmc_emit_load_const(c, r, e.float_val)
		return r, .None

	case .Lit_String:
		r, ok := reg_alloc(&c.ra)
		if !ok {
			return 0, .Register_Overflow
		}
		vmc_emit_load_const(c, r, e.str_id)
		return r, .None

	case .Var:
		slot, ok := c.env.var_names[e.str_id]
		if !ok {
			return 0, .Missing_Field
		}
		r, rok := reg_alloc(&c.ra)
		if !rok {
			return 0, .Register_Overflow
		}
		append(&c.code, Instruction{op = .Load_Var, dst = r, lhs = slot, rhs = 0})
		return r, .None

	case .Field_Access:
		return vmc_compile_field_access(c, eid)

	case .Unary:
		inner := vmc_compile_expr(c, e.lhs) or_return
		dst, ok := reg_alloc(&c.ra)
		if !ok {
			reg_free(&c.ra, inner)
			return 0, .Register_Overflow
		}
		op := Opcode.Neg if e.unary_op == .Neg else Opcode.Not
		append(&c.code, Instruction{op = op, dst = dst, lhs = inner, rhs = 0})
		reg_free(&c.ra, inner)
		return dst, .None

	case .Binary:
		if e.binary_op == .And || e.binary_op == .Or {
			lhs_r := vmc_compile_expr(c, e.lhs) or_return
			res_r, rok := reg_alloc(&c.ra)
			if !rok {
				reg_free(&c.ra, lhs_r)
				return 0, .Register_Overflow
			}
			append(&c.code, Instruction{op = .Move, dst = res_r, lhs = lhs_r})
			reg_free(&c.ra, lhs_r)

			jmp_idx := len(c.code)
			jmp_op := Opcode.Jmp_If_False if e.binary_op == .And else Opcode.Jmp_If_True
			append(&c.code, Instruction{op = jmp_op, dst = res_r, lhs = 0, rhs = 0})

			rhs_r, r_err := vmc_compile_expr(c, e.rhs)
			if r_err != .None {
				reg_free(&c.ra, res_r)
				return 0, r_err
			}
			append(&c.code, Instruction{op = .Move, dst = res_r, lhs = rhs_r})
			reg_free(&c.ra, rhs_r)

			skip := len(c.code) - (jmp_idx + 1)
			c.code[jmp_idx].lhs = u8(skip >> 8)
			c.code[jmp_idx].rhs = u8(skip & 0xff)
			return res_r, .None
		}

		lhs_r := vmc_compile_expr(c, e.lhs) or_return
		rhs_r, r_err := vmc_compile_expr(c, e.rhs)
		if r_err != .None {
			reg_free(&c.ra, lhs_r)
			return 0, r_err
		}
		dst, ok := reg_alloc(&c.ra)
		if !ok {
			reg_free(&c.ra, lhs_r)
			reg_free(&c.ra, rhs_r)
			return 0, .Register_Overflow
		}
		op: Opcode
		#partial switch e.binary_op {
		case .Add: op = .Add
		case .Sub: op = .Sub
		case .Mul: op = .Mul
		case .Div: op = .Div
		case .Mod: op = .Mod
		case .Eq:  op = .Eq
		case .Neq: op = .Neq
		case .Lt:  op = .Lt
		case .Lte: op = .Lte
		case .Gt:  op = .Gt
		case .Gte: op = .Gte
		case:
			reg_free(&c.ra, lhs_r)
			reg_free(&c.ra, rhs_r)
			reg_free(&c.ra, dst)
			return 0, .Unsupported_Expr
		}
		append(&c.code, Instruction{op = op, dst = dst, lhs = lhs_r, rhs = rhs_r})
		reg_free(&c.ra, lhs_r)
		reg_free(&c.ra, rhs_r)
		return dst, .None

	case .Range:
		// Evaluates as boolean false/unsupported directly; Range inside Cell_Cmp/Alpha uses Range_Desc.
		return 0, .Unsupported_Expr

	case .In_List:
		if e.extra_span.count == 0 {
			r, ok := reg_alloc(&c.ra)
			if !ok {
				return 0, .Register_Overflow
			}
			vmc_emit_load_const(c, r, false)
			return r, .None
		}
		// Compare e.lhs against each extra expression with short-circuit OR.
		lhs_r := vmc_compile_expr(c, e.lhs) or_return
		res_r, rok := reg_alloc(&c.ra)
		if !rok {
			reg_free(&c.ra, lhs_r)
			return 0, .Register_Overflow
		}
		vmc_emit_load_const(c, res_r, false)
		end_jmps := make([dynamic]int, 0, int(e.extra_span.count), context.temp_allocator)

		for i in e.extra_span.start ..< e.extra_span.start + e.extra_span.count {
			cand_r, cerr := vmc_compile_expr(c, c.env.ir.extra_exprs[i])
			if cerr != .None {
				reg_free(&c.ra, lhs_r)
				reg_free(&c.ra, res_r)
				return 0, cerr
			}
			append(&c.code, Instruction{op = .Eq, dst = res_r, lhs = lhs_r, rhs = cand_r})
			reg_free(&c.ra, cand_r)
			append(&end_jmps, len(c.code))
			append(&c.code, Instruction{op = .Jmp_If_True, dst = res_r, lhs = 0, rhs = 0})
		}
		for ji in end_jmps {
			skip := len(c.code) - (ji + 1)
			c.code[ji].lhs = u8(skip >> 8)
			c.code[ji].rhs = u8(skip & 0xff)
		}
		reg_free(&c.ra, lhs_r)
		return res_r, .None

	case .Cell_Cmp, .Call:
		return 0, .Unsupported_Expr
	}
	return 0, .Unsupported_Expr
}

// Compiles a single Expr_IR into a standalone register-recycled Bytecode_Program ending with .Halt.
vm_compile_expr :: proc(
	env: ^Vm_Compile_Env,
	eid: Expr_Id,
	alloc := context.allocator,
) -> (prog: Bytecode_Program, err: Vm_Error) {
	if env == nil || env.ir == nil {
		return {}, .Unsupported_Expr
	}
	c := Vm_Compiler{
		env          = env,
		code         = make([dynamic]Instruction, 0, 16, context.temp_allocator),
		consts       = make([dynamic]Value, 0, 8, context.temp_allocator),
		field_refs   = make([dynamic]Field_Access_Desc, 0, 4, context.temp_allocator),
		decide_calls = make([dynamic]Decide_Call_Desc, 0, 2, context.temp_allocator),
		ranges       = make([dynamic]Range_Desc, 0, 2, context.temp_allocator),
		alloc        = alloc,
	}
	defer if err != .None {
		for fr in c.field_refs {
			delete(fr.segments, alloc)
		}
		for dc in c.decide_calls {
			delete(dc.args, alloc)
		}
	}

	res_reg := vmc_compile_expr(&c, eid) or_return
	append(&c.code, Instruction{op = .Halt, dst = res_reg, lhs = 0, rhs = 0})
	reg_free(&c.ra, res_reg)

	return _finalize_vm_program(&c), .None
}

// Compiles a `decide table_name(col: expr, ...)` clause into bytecode storing result into `decide_slot`.
vm_compile_decide :: proc(
	env: ^Vm_Compile_Env,
	table_name: String_Id,
	args: []Field_Binding_IR,
	decide_slot: u8,
	alloc := context.allocator,
) -> (prog: Bytecode_Program, err: Vm_Error) {
	if env == nil || env.ir == nil {
		return {}, .Unsupported_Expr
	}
	c := Vm_Compiler{
		env          = env,
		code         = make([dynamic]Instruction, 0, 16, context.temp_allocator),
		consts       = make([dynamic]Value, 0, 8, context.temp_allocator),
		field_refs   = make([dynamic]Field_Access_Desc, 0, 8, context.temp_allocator),
		decide_calls = make([dynamic]Decide_Call_Desc, 0, 2, context.temp_allocator),
		ranges       = make([dynamic]Range_Desc, 0, 2, context.temp_allocator),
		alloc        = alloc,
	}
	defer if err != .None {
		for fr in c.field_refs {
			delete(fr.segments, alloc)
		}
		for dc in c.decide_calls {
			delete(dc.args, alloc)
		}
	}

	tidx, tok := vmc_find_table(&c, table_name)
	if !tok || int(tidx) >= len(env.ir.tables) {
		return {}, .Unknown_Table
	}
	tbl := env.ir.tables[tidx]

	arg_specs := make([]Decide_Arg_Spec, len(args), alloc)
	for fb, i in args {
		col_idx, cok := find_table_col_idx(tbl.inputs, fb.name)
		if !cok {
			delete(arg_specs, alloc)
			return {}, .Missing_Field
		}
		r, r_err := vmc_compile_expr(&c, fb.expr)
		if r_err != .None {
			for j := 0; j < i; j += 1 {
				reg_free(&c.ra, arg_specs[j].reg)
			}
			delete(arg_specs, alloc)
			return {}, r_err
		}
		arg_specs[i] = Decide_Arg_Spec{
			col_idx = u8(col_idx),
			reg     = r,
		}
	}

	desc_idx := u8(len(c.decide_calls))
	append(&c.decide_calls, Decide_Call_Desc{
		table_idx   = tidx,
		result_slot = decide_slot,
		args        = arg_specs,
	})

	out_reg, rok := reg_alloc(&c.ra)
	if !rok {
		return {}, .Register_Overflow
	}
	append(&c.code, Instruction{
		op  = .Decide_Call,
		dst = out_reg,
		lhs = desc_idx,
		rhs = decide_slot,
	})
	for a in arg_specs {
		reg_free(&c.ra, a.reg)
	}
	append(&c.code, Instruction{op = .Halt, dst = out_reg, lhs = 0, rhs = 0})
	reg_free(&c.ra, out_reg)

	return _finalize_vm_program(&c), .None
}

@(private)
_finalize_vm_program :: proc(c: ^Vm_Compiler) -> Bytecode_Program {
	code := make([]Instruction, len(c.code), c.alloc)
	copy(code, c.code[:])

	consts: []Value
	if len(c.consts) > 0 {
		consts = make([]Value, len(c.consts), c.alloc)
		copy(consts, c.consts[:])
	}

	field_refs: []Field_Access_Desc
	if len(c.field_refs) > 0 {
		field_refs = make([]Field_Access_Desc, len(c.field_refs), c.alloc)
		copy(field_refs, c.field_refs[:])
	}

	decide_calls: []Decide_Call_Desc
	if len(c.decide_calls) > 0 {
		decide_calls = make([]Decide_Call_Desc, len(c.decide_calls), c.alloc)
		copy(decide_calls, c.decide_calls[:])
	}

	ranges: []Range_Desc
	if len(c.ranges) > 0 {
		ranges = make([]Range_Desc, len(c.ranges), c.alloc)
		copy(ranges, c.ranges[:])
	}

	return Bytecode_Program{
		code         = code,
		consts       = consts,
		field_refs   = field_refs,
		decide_calls = decide_calls,
		ranges       = ranges,
		max_regs     = c.ra.max_used,
		allocator    = c.alloc,
	}
}
