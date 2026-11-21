package forseti_specs

import vmem "core:mem/virtual"
import "core:testing"
import "../forseti"

World :: struct {
	t:         ^testing.T,
	arena:     vmem.Arena,
	telemetry: forseti.Telemetry_Sink,
}

world_init :: proc(w: ^World, t: ^testing.T, loc := #caller_location) {
	w^ = {}
	w.t = t
	arena_err := vmem.arena_init_growing(&w.arena)
	testing.expect_value(t, arena_err, nil, loc = loc)

	tel_err := forseti.telemetry_init(&w.telemetry, enabled = true)
	testing.expect_value(t, tel_err, nil, loc = loc)
}

world_destroy :: proc(w: ^World) {
	vmem.arena_check_temp(&w.arena)
	forseti.telemetry_destroy(&w.telemetry)
	vmem.arena_destroy(&w.arena)
	w^ = {}
}

@(test)
spec_harness_world_bootstrap_sanity :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	driver_record_bootstrap_telemetry(&w.telemetry)
	testing.expect_value(t, len(w.telemetry.events), 1)
}
