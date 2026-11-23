package forseti_actors_specs

import "core:testing"
import vmem "core:mem/virtual"
import actor "actor:."
import xitdb "xitdb:."
import "../actors"
import "../forseti"

Actor_World :: struct {
	t:     ^testing.T,
	arena: vmem.Arena,
}

actor_world_init :: proc(w: ^Actor_World, t: ^testing.T, loc := #caller_location) {
	w^ = {}
	w.t = t
	err := vmem.arena_init_growing(&w.arena)
	testing.expect_value(t, err, nil, loc = loc)
}

actor_world_destroy :: proc(w: ^Actor_World) {
	vmem.arena_check_temp(&w.arena)
	vmem.arena_destroy(&w.arena)
	w^ = {}
}

@(test)
spec_actor_runtime_plumbing_smoke :: proc(t: ^testing.T) {
	w: Actor_World
	actor_world_init(&w, t)
	defer actor_world_destroy(&w)

	_ = actor.scoped_scheduler(num_workers = 2)
	testing.expect_value(t, actors.FORSETI_ACTORS_VERSION, "0.1.0")
	_ = xitdb.Xitdb_Error.None
	_ = forseti.Compile_Error.None
}
