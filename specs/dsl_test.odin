package forseti_specs

import "core:strings"
import vmem "core:mem/virtual"
import "core:testing"
import "../forseti"

Policy_Kind :: enum u8 {
	External,
	Internal,
}

Policy_Slot :: struct {
	kind:     Policy_Kind,
	source:   string,
	filename: string,
	builder:  ^forseti.Ir_Builder,
	ir:       forseti.Rulebase_IR,
	diags:    forseti.Diagnostic_List,
	compiled: bool,
}

World :: struct {
	t:         ^testing.T,
	arena:     vmem.Arena,
	telemetry: forseti.Telemetry_Sink,
	policies:  map[string]Policy_Slot,
}

world_init :: proc(w: ^World, t: ^testing.T, loc := #caller_location) {
	w^ = {}
	w.t = t
	arena_err := vmem.arena_init_growing(&w.arena)
	testing.expect_value(t, arena_err, nil, loc = loc)

	tel_err := forseti.telemetry_init(&w.telemetry, enabled = true)
	testing.expect_value(t, tel_err, nil, loc = loc)

	w.policies = make(map[string]Policy_Slot, 8)
}

world_destroy :: proc(w: ^World) {
	vmem.arena_check_temp(&w.arena)
	for _, &slot in w.policies {
		if slot.compiled {
			forseti.ir_destroy(&slot.ir)
			forseti.diag_list_destroy(&slot.diags)
		}
	}
	delete(w.policies)
	forseti.telemetry_destroy(&w.telemetry)
	vmem.arena_destroy(&w.arena)
	w^ = {}
}

given_external_policy :: proc(
	w: ^World,
	label: string,
	source: string,
	filename: string = "policy.forseti",
	loc := #caller_location,
) {
	arena_alloc := vmem.arena_allocator(&w.arena)
	cloned_src, err1 := strings.clone(source, arena_alloc)
	testing.expect_value(w.t, err1, nil, loc = loc)
	cloned_file, err2 := strings.clone(filename, arena_alloc)
	testing.expect_value(w.t, err2, nil, loc = loc)
	w.policies[label] = Policy_Slot{
		kind     = .External,
		source   = cloned_src,
		filename = cloned_file,
	}
}

given_internal_policy :: proc(
	w: ^World,
	label: string,
	builder: ^forseti.Ir_Builder,
) {
	w.policies[label] = Policy_Slot{
		kind    = .Internal,
		builder = builder,
	}
}

upon_compiling_policy :: proc(w: ^World, label: string, loc := #caller_location) {
	slot, ok := &w.policies[label]
	if !testing.expectf(w.t, ok, "unknown policy label %q", label, loc = loc) {
		return
	}
	if slot.compiled {
		forseti.ir_destroy(&slot.ir)
		forseti.diag_list_destroy(&slot.diags)
		slot.compiled = false
	}

	d_err := forseti.diag_list_init(&slot.diags)
	if !testing.expect_value(w.t, d_err, nil, loc = loc) {
		return
	}

	switch slot.kind {
	case .External:
		err := driver_compile_external(slot.source, slot.filename, &slot.ir, &slot.diags, &w.telemetry)
		if !testing.expect_value(w.t, err, nil, loc = loc) {
			forseti.diag_list_destroy(&slot.diags)
			return
		}
	case .Internal:
		err := driver_compile_internal(slot.builder, &slot.ir, &slot.diags, &w.telemetry)
		if !testing.expect_value(w.t, err, nil, loc = loc) {
			forseti.diag_list_destroy(&slot.diags)
			return
		}
	}
	slot.compiled = true
}

then_compilation_has_zero_diagnostics :: proc(w: ^World, label: string, loc := #caller_location) {
	slot, ok := &w.policies[label]
	if !testing.expectf(w.t, ok && slot.compiled, "policy %q must be compiled", label, loc = loc) {
		return
	}
	testing.expect_value(w.t, len(slot.diags.items), 0, loc = loc)
}

then_external_and_internal_ir_match :: proc(w: ^World, label_a, label_b: string, loc := #caller_location) {
	slot_a, ok_a := &w.policies[label_a]
	slot_b, ok_b := &w.policies[label_b]
	if !testing.expectf(w.t, ok_a && slot_a.compiled, "policy %q must be compiled", label_a, loc = loc) {
		return
	}
	if !testing.expectf(w.t, ok_b && slot_b.compiled, "policy %q must be compiled", label_b, loc = loc) {
		return
	}
	testing.expect(w.t, forseti.ir_structurally_equal(&slot_a.ir, &slot_b.ir), loc = loc)
}

@(test)
spec_harness_world_bootstrap_sanity :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	driver_record_bootstrap_telemetry(&w.telemetry)
	testing.expect_value(t, len(w.telemetry.events), 1)
}
