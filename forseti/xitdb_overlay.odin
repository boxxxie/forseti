package forseti

import "base:runtime"
import xitdb "xitdb:."

// Fork_Handle wraps an O(1) copy-on-write xitdb.Core_Overlay fork for isolated counterfactual replay.
// Pinned handle (internal self-pointers): initialize in-place or heap-allocate via new(Fork_Handle) and never copy by value.
Fork_Handle :: struct {
	overlay_core:        xitdb.Core,
	overlay_db:          xitdb.Database,
	bridge:              Store_Bridge,
	base_committed_size: i64,
	base_moment_count:   i64,
	active:              bool,
}

// Creates a zero-copy CoW overlay fork of `parent` frozen at `parent`'s committed snapshot.
fork_create :: proc(
	fork: ^Fork_Handle,
	parent: ^Store_Bridge,
	allocator: runtime.Allocator = context.allocator,
) -> (err: Store_Error) {
	if fork == nil || parent == nil || parent.db == nil || parent.db.core == nil {
		return .Invalid_Config
	}
	fork^ = {}

	committed_sz, c_err := xitdb.database_committed_size(parent.db)
	if c_err != nil {
		return xitdb_to_store_err(c_err)
	}
	moment_cnt := store_bridge_moment_count(parent) or_return

	ov_core, ov_err := xitdb.core_overlay_init(parent.db.core, committed_sz, allocator)
	if ov_err != nil {
		return xitdb_to_store_err(ov_err)
	}
	fork.overlay_core = ov_core
	defer if err != nil {
		_ = xitdb.core_destroy(&fork.overlay_core)
		fork^ = {}
	}

	opts := xitdb.Database_Options{skip_memory_crc = parent.db.skip_memory_crc}
	ov_db, db_err := xitdb.database_init_with_options(&fork.overlay_core, parent.db.hasher, opts)
	if db_err != nil {
		return xitdb_to_store_err(db_err)
	}
	fork.overlay_db = ov_db
	fork.overlay_db.core = &fork.overlay_core

	if b_err := store_bridge_init_attached(&fork.bridge, &fork.overlay_db, parent.cfg, parent.telemetry); b_err != nil {
		return b_err
	}

	fork.base_committed_size = committed_sz
	fork.base_moment_count = moment_cnt
	fork.active = true
	return nil
}

fork_owned_bytes :: proc(fork: ^Fork_Handle) -> i64 {
	if fork == nil || !fork.active {
		return 0
	}
	return xitdb.core_overlay_owned_bytes(&fork.overlay_core)
}

fork_destroy :: proc(fork: ^Fork_Handle) {
	if fork == nil || !fork.active {
		return
	}
	store_bridge_destroy(&fork.bridge)
	_ = xitdb.core_destroy(&fork.overlay_core)
	fork^ = {}
}
