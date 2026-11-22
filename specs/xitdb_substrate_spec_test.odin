package forseti_specs

import "core:testing"
import xitdb "xitdb:."
import "../forseti"

@(test)
spec_standalone_and_attached_mdm_moments :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	given_standalone_store(&w, "mem")
	upon_committing_mdm_orgs(&w, "mem", {
		{
			id            = "org:1",
			name          = "ACME Corp",
			country       = "DE",
			domain        = "acme.com",
			employees     = 120,
			active        = true,
			locked_fields = {"country"},
		},
		{
			id            = "org:2",
			name          = "ACME Subsidiary",
			country       = "FR",
			domain        = "acme.org",
			employees     = 45,
			active        = true,
			locked_fields = nil,
		},
		{
			id            = "org:3",
			name          = "Beta Labs",
			country       = "US",
			domain        = "beta.io",
			employees     = 12,
			active        = false,
			locked_fields = nil,
		},
	})

	// Moment 1 updates org:1 employees & country without erasing historical Moment 0.
	upon_committing_mdm_orgs(&w, "mem", {
		{
			id            = "org:1",
			name          = "ACME Corp Global",
			country       = "CH",
			domain        = "acme.com",
			employees     = 350,
			active        = false,
			locked_fields = {"country", "domain"},
		},
	})

	then_lazy_field_equals(&w, "mem", 0, ".orgs.raw", "org:1", {"address", "country"}, "DE")
	then_lazy_field_equals(&w, "mem", 0, ".orgs.raw", "org:1", {"employees"}, i64(120))
	then_lazy_field_equals(&w, "mem", 0, ".orgs.raw", "org:1", {"active"}, true)

	then_lazy_field_equals(&w, "mem", 1, ".orgs.raw", "org:1", {"address", "country"}, "CH")
	then_lazy_field_equals(&w, "mem", 1, ".orgs.raw", "org:1", {"employees"}, i64(350))
	then_lazy_field_equals(&w, "mem", 1, ".orgs.raw", "org:1", {"active"}, false)
	then_lazy_field_equals(&w, "mem", 1, ".orgs.raw", "org:1", {"locked_fields", "domain"}, true)
	then_lazy_field_equals(&w, "mem", 1, ".orgs.raw", "org:1", {"locked_fields", "name"}, false)

	then_sorted_prefix_scan_returns(&w, "mem", ".orgs.by_domain", "acme.", {"acme.com:org:1", "acme.org:org:2"})
	then_eav_entity_attributes_match(&w, "mem", ".facts.eav", "org:2", {"country", "name"}, {"FR", "ACME Subsidiary"})

	// Attached Core_Buffered_File Safe_V2 store persists across reopen.
	given_attached_file_store(&w, "disk", "mdm_store.xit", forseti.Xitdb_Config{mode = .Safe_V2})
	upon_committing_mdm_orgs(&w, "disk", {
		{
			id            = "org:10",
			name          = "Disk HoldCo",
			country       = "NL",
			domain        = "holdco.eu",
			employees     = 500,
			active        = true,
			locked_fields = {"name"},
		},
	})
	upon_reopening_attached_file_store(&w, "disk", "disk_reopened", "mdm_store.xit", forseti.Xitdb_Config{mode = .Safe_V2})

	then_lazy_field_equals(&w, "disk_reopened", -1, ".orgs.raw", "org:10", {"address", "country"}, "NL")
	then_lazy_field_equals(&w, "disk_reopened", -1, ".orgs.raw", "org:10", {"active"}, true)
	then_lazy_field_equals(&w, "disk_reopened", -1, ".orgs.raw", "org:10", {"locked_fields", "name"}, true)
	then_sorted_prefix_scan_returns(&w, "disk_reopened", ".orgs.by_domain", "holdco.", {"holdco.eu:org:10"})
}

@(test)
spec_incremental_delta_sync_100k_records :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	given_standalone_store(&w, "scale", forseti.Xitdb_Config{mode = .Fast_Memory})
	given_watched_collection(&w, "scale", ".orgs.raw")

	upon_bulk_seeding_records(&w, "scale", ".orgs.raw", 100_000)
	upon_syncing_deltas(&w, "scale", "initial")
	then_delta_sync_counts(&w, "initial", 100_000, 0, 0, expect_compacted = false)

	upon_mutating_record_batch(
		&w,
		"scale",
		".orgs.raw",
		added   = {"org:100000", "org:100001", "org:100002"},
		updated = {"org:000010", "org:025000", "org:050000", "org:099998"},
		removed = {"org:000020", "org:060000", "org:099999"},
	)
	upon_syncing_deltas(&w, "scale", "delta10")

	then_delta_sync_counts(&w, "delta10", 3, 3, 4, expect_compacted = false)
	then_delta_sync_skipped_slots(&w, "delta10", min_slots_skipped = 300, max_blocks_compared = 120, max_keys_decoded = 25)
	then_telemetry_counter_at_least(&w, .Slots_Skipped, 300)
	then_telemetry_counter_at_least(&w, .Keys_Decoded, 10)
}

@(test)
spec_compaction_safe_logical_resync :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	given_standalone_store(&w, "comp")
	given_watched_collection(&w, "comp", ".orgs.raw")

	upon_bulk_seeding_records(&w, "comp", ".orgs.raw", 200)
	upon_syncing_deltas(&w, "comp", "s0")
	then_delta_sync_counts(&w, "s0", 200, 0, 0, expect_compacted = false)

	upon_compacting_store(&w, "comp")
	upon_mutating_record_batch(
		&w,
		"comp",
		".orgs.raw",
		added   = {"org:000200"},
		updated = {"org:000042"},
		removed = {"org:000007"},
		new_val_offset = 7777,
	)
	upon_syncing_deltas(&w, "comp", "post_compact")
	// Compaction changes file_id & resets moment slots, triggering safe logical resync with exact diff only.
	then_delta_sync_counts(&w, "post_compact", 1, 1, 1, expect_compacted = true)

	// Next incremental moment resumes incremental diff_collection slot skipping.
	upon_mutating_record_batch(&w, "comp", ".orgs.raw", nil, {"org:000100"}, nil, new_val_offset = 8888)
	upon_syncing_deltas(&w, "comp", "resumed")
	then_delta_sync_counts(&w, "resumed", 0, 0, 1, expect_compacted = false)
	then_delta_sync_skipped_slots(&w, "resumed", min_slots_skipped = 10, max_blocks_compared = 20, max_keys_decoded = 5)
}

@(test)
spec_overlay_fork_counterfactual_isolation :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	given_standalone_store(&w, "parent")
	upon_bulk_seeding_records(&w, "parent", ".orgs.raw", 500)

	upon_creating_overlay_fork(&w, "parent", "cf_fork")
	upon_mutating_overlay_fork_record(&w, "cf_fork", ".orgs.raw", "org:000001", 9001)
	upon_mutating_overlay_fork_record(&w, "cf_fork", ".orgs.raw", "org:cf_only", 4242)

	// Parent keeps evolving independently after fork without affecting fork's frozen base snapshot.
	upon_mutating_record_batch(&w, "parent", ".orgs.raw", {"org:parent_only"}, {"org:000001"}, nil, new_val_offset = 333)

	then_overlay_fork_is_isolated(
		&w,
		"parent",
		"cf_fork",
		".orgs.raw",
		"org:000001",
		expected_parent_val = i64(333),
		expected_fork_val   = i64(9001),
		max_owned_bytes     = 64 * 1024,
	)
	then_overlay_fork_is_isolated(
		&w,
		"parent",
		"cf_fork",
		".orgs.raw",
		"org:cf_only",
		expected_parent_val = nil,
		expected_fork_val   = i64(4242),
		max_owned_bytes     = 64 * 1024,
	)
	then_overlay_fork_is_isolated(
		&w,
		"parent",
		"cf_fork",
		".orgs.raw",
		"org:parent_only",
		expected_parent_val = i64(833),
		expected_fork_val   = nil,
		max_owned_bytes     = 64 * 1024,
	)
}

@(test)
spec_safe_v2_vs_fast_memory_guardrails :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	// 1. Safe_V2 rejects fast_hasher override.
	upon_attempting_invalid_memory_open(
		&w,
		forseti.Xitdb_Config{mode = .Safe_V2, custom_hasher = forseti.fast_hasher()},
		forseti.Xitdb_Config{},
		reopen_existing = false,
	)
	then_store_error_is(&w, forseti.Store_Bridge_Error.Invalid_Config)

	// 2. Disk-backed buffered file rejects Fast_Memory mode.
	upon_attempting_invalid_file_open(
		&w,
		"bad_fast.xit",
		forseti.Xitdb_Config{mode = .Fast_Memory},
		forseti.Xitdb_Config{},
		reopen_existing = false,
	)
	then_store_error_is(&w, forseti.Store_Bridge_Error.Disk_Fast_Mode_Forbidden)

	// 3. Disk-backed buffered file rejects Safe_V2 + custom fast_hasher override.
	upon_attempting_invalid_file_open(
		&w,
		"bad_crc.xit",
		forseti.Xitdb_Config{mode = .Safe_V2, custom_hasher = forseti.fast_hasher()},
		forseti.Xitdb_Config{},
		reopen_existing = false,
	)
	then_store_error_is(&w, forseti.Store_Bridge_Error.Disk_Fast_Mode_Forbidden)

	// 4. Opening a Safe_V2 SHA-1 file with Fast_Memory fast_hasher fails hash validation cleanly.
	upon_attempting_invalid_memory_open(
		&w,
		forseti.Xitdb_Config{mode = .Safe_V2},
		forseti.Xitdb_Config{mode = .Fast_Memory},
		reopen_existing = true,
	)
	then_store_error_is(&w, xitdb.Xitdb_Error.Invalid_Hash_Size)

	// 5. Opening a Fast_Memory DB with Safe_V2 SHA-1 fails hash validation cleanly.
	upon_attempting_invalid_memory_open(
		&w,
		forseti.Xitdb_Config{mode = .Fast_Memory},
		forseti.Xitdb_Config{mode = .Safe_V2},
		reopen_existing = true,
	)
	then_store_error_is(&w, xitdb.Xitdb_Error.Invalid_Hash_Size)
}

@(test)
spec_cold_disk_hydrate_nested_projection_and_incremental_resync :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	src := `module cold_hydrate_disk version "1.0"

schema Organization {
  name: string,
  domain: string,
  employees: i64,
  active: bool
}

source RawOrg : Organization at .orgs.raw[?id]
derived CanonOrg : Organization at .orgs.canon[?id]

rule canonicalize {
  when {
    ?_raw := RawOrg(name: ?nm, domain: ?dom, employees: ?emp, active: true)
    where ?emp >= 50
  }
  then {
    assert CanonOrg(name: ?nm, domain: ?dom, employees: ?emp, active: true)
  }
}`

	given_external_policy(&w, "ch", src, "cold_hydrate.forseti")
	upon_compiling_policy(&w, "ch")
	then_compilation_has_zero_diagnostics(&w, "ch")
	upon_compiling_rulebase(&w, "ch", "rb")

	given_attached_file_store(&w, "disk_seed", "hydrate_reopen.xit", forseti.Xitdb_Config{mode = .Safe_V2})
	upon_committing_mdm_orgs(&w, "disk_seed", {
		{id = "org:1", name = "Alpine AG", country = "DE", domain = "alpine.de", employees = 200, active = true, locked_fields = {"domain"}},
		{id = "org:2", name = "Boutique", country = "FR", domain = "btq.fr", employees = 12, active = true},
		{id = "org:3", name = "Pacific Ltd", country = "JP", domain = "pacific.jp", employees = 420, active = true, locked_fields = {"name"}},
	})

	// Reopen persisted disk store cleanly, watch .orgs.raw, and hydrate via transient snapshot!
	upon_reopening_attached_file_store(&w, "disk_seed", "disk", "hydrate_reopen.xit", forseti.Xitdb_Config{mode = .Safe_V2})
	given_watched_collection(&w, "disk", ".orgs.raw")
	given_session(&w, "rb", "s")
	upon_syncing_store_and_firing(&w, "disk", "s", "cold_sync", commit_derived = true)
	then_rules_fired_count_is(&w, "cold_sync", 2)
	then_session_has_derived_fact(&w, "s", "CanonOrg", {"Alpine AG", "alpine.de", i64(200), true})
	then_session_has_derived_fact(&w, "s", "CanonOrg", {"Pacific Ltd", "pacific.jp", i64(420), true})
	then_store_collection_has_record_count_and_field(&w, "disk", ".orgs.canon", 2, "name", "Alpine AG")

	// Nested fields not eagerly hydrated still resolve lazily against live bridge.db after snap_arena destruction!
	then_lazy_field_equals(&w, "disk", 0, ".orgs.raw", "org:1", {"address", "country"}, "DE")
	then_lazy_field_equals(&w, "disk", 0, ".orgs.raw", "org:1", {"locked_fields", "domain"}, true)

	// Commit an incremental update after cold disk hydration and sync again!
	upon_committing_mdm_orgs(&w, "disk", {
		{id = "org:2", name = "Boutique Grown", country = "FR", domain = "btq.fr", employees = 150, active = true},
	})
	upon_syncing_store_and_firing(&w, "disk", "s", "inc_sync", commit_derived = true)
	then_rules_fired_count_is(&w, "inc_sync", 1)
	then_session_has_derived_fact(&w, "s", "CanonOrg", {"Boutique Grown", "btq.fr", i64(150), true})
	then_store_collection_has_record_count_and_field(&w, "disk", ".orgs.canon", 3, "name", "Boutique Grown")
}
