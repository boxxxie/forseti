package forseti_actors_specs

import "core:fmt"
import "../forseti"

driver_compile_policy :: proc(src: string) -> (entry: Policy_Entry, ok: bool, msg: string) {
	if forseti.diag_list_init(&entry.diags) != nil {
		return {}, false, "diag_list_init failed"
	}
	ir, c_err := forseti.compile_source(src, "policy.forseti", &entry.diags)
	if c_err != nil || entry.diags.error_count > 0 {
		forseti.ir_destroy(&ir)
		forseti.diag_list_destroy(&entry.diags)
		return {}, false, fmt.tprintf("compile_source errors=%d err=%v", entry.diags.error_count, c_err)
	}
	entry.ir = ir

	rb := new(forseti.Rulebase)
	rb_val, rb_err := forseti.rulebase_compile(&entry.ir)
	if rb_err != .None {
		forseti.rulebase_destroy(&rb_val)
		free(rb)
		forseti.ir_destroy(&entry.ir)
		forseti.diag_list_destroy(&entry.diags)
		return {}, false, fmt.tprintf("rulebase_compile err=%v", rb_err)
	}
	rb^ = rb_val
	entry.rb = rb
	return entry, true, ""
}
