#ifndef FORSETI_H
#define FORSETI_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct forseti_rulebase forseti_rulebase_t;
typedef struct forseti_session forseti_session_t;
typedef struct forseti_store forseti_store_t;

typedef enum {
	FORSETI_OK = 0,
	FORSETI_ERR_INVALID_ARG = 1,
	FORSETI_ERR_COMPILE = 2,
	FORSETI_ERR_ALLOC = 3,
	FORSETI_ERR_UNKNOWN_BINDING = 4,
	FORSETI_ERR_UNKNOWN_QUERY = 5,
	FORSETI_ERR_UNKNOWN_RULE = 6,
	FORSETI_ERR_STORE = 7,
	FORSETI_ERR_LIMIT = 8,
	FORSETI_ERR_INTERNAL = 9
} forseti_status_t;

typedef enum {
	FORSETI_PROV_AUDIT_FULL = 0,
	FORSETI_PROV_SUPPORT_ONLY = 1,
	FORSETI_PROV_FAST = 2
} forseti_provenance_mode_t;

typedef enum {
	FORSETI_VAL_NIL = 0,
	FORSETI_VAL_BOOL = 1,
	FORSETI_VAL_I32 = 2,
	FORSETI_VAL_I64 = 3,
	FORSETI_VAL_F64 = 4,
	FORSETI_VAL_STRING = 5,
	FORSETI_VAL_ENTITY = 6,
	FORSETI_VAL_TIME_NS = 7,
	FORSETI_VAL_ENUM = 8
} forseti_val_kind_t;

typedef struct {
	forseti_val_kind_t kind;
	union {
		bool b;
		int32_t i32;
		int64_t i64;
		double f64;
		const char *str;
		uint64_t entity;
		int64_t time_ns;
		struct {
			uint32_t enum_id;
			uint32_t variant;
		} enum_val;
	} as;
} forseti_value_t;

const char *forseti_abi_version(void);
void forseti_free_string(const char *str);

forseti_status_t forseti_rulebase_compile(
	const char *source,
	const char *source_name,
	bool warnings_as_errors,
	forseti_rulebase_t **out_rb,
	char **out_diags_json
);
void forseti_rulebase_destroy(forseti_rulebase_t *rb);

forseti_status_t forseti_session_create(
	forseti_rulebase_t *rb,
	forseti_provenance_mode_t prov_mode,
	uint64_t max_activations,
	forseti_session_t **out_sess
);
void forseti_session_destroy(forseti_session_t *sess);

forseti_status_t forseti_session_insert_fact(
	forseti_session_t *sess,
	const char *binding,
	const char *key,
	const forseti_value_t *fields,
	size_t field_count,
	uint64_t *out_fact_id
);

forseti_status_t forseti_session_modify_fact(
	forseti_session_t *sess,
	const char *binding,
	const char *key,
	const forseti_value_t *fields,
	size_t field_count
);

forseti_status_t forseti_session_retract_fact(
	forseti_session_t *sess,
	const char *binding,
	const char *key
);

forseti_status_t forseti_session_retract_fact_id(
	forseti_session_t *sess,
	uint64_t fact_id
);

forseti_status_t forseti_session_fire(
	forseti_session_t *sess,
	uint64_t *out_fired_count
);

forseti_status_t forseti_session_query_json(
	forseti_session_t *sess,
	const char *query_name,
	const char **arg_names,
	const forseti_value_t *arg_values,
	size_t arg_count,
	char **out_json
);

forseti_status_t forseti_store_open(
	const char *path,
	forseti_store_t **out_store
);
void forseti_store_destroy(forseti_store_t *store);

forseti_status_t forseti_store_put_record(
	forseti_store_t *store,
	const char *dot_path,
	const char *key,
	const char **field_names,
	const forseti_value_t *field_values,
	size_t field_count
);

forseti_status_t forseti_session_sync_and_fire(
	forseti_session_t *sess,
	forseti_store_t *store,
	const char **watched_paths,
	size_t watched_count,
	bool commit_derived,
	uint64_t *out_fired_count
);

forseti_status_t forseti_diff_replay_json(
	forseti_store_t *store,
	forseti_rulebase_t *baseline_rb,
	forseti_rulebase_t *candidate_rb,
	const char **watched_paths,
	size_t watched_count,
	char **out_json
);

forseti_status_t forseti_session_diff_replay_json(
	forseti_session_t *sess,
	forseti_store_t *store,
	forseti_rulebase_t *candidate_rb,
	const char **watched_paths,
	size_t watched_count,
	char **out_json
);

forseti_status_t forseti_session_explain_json(
	forseti_session_t *sess,
	uint64_t fact_id,
	char **out_json
);

forseti_status_t forseti_session_impact_json(
	forseti_session_t *sess,
	const char *rule_name,
	const char *rule_version,
	char **out_json
);

forseti_status_t forseti_session_telemetry_jsonl(
	forseti_session_t *sess,
	char **out_jsonl
);

#ifdef __cplusplus
}
#endif

#endif /* FORSETI_H */
