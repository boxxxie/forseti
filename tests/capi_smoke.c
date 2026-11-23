#include "forseti.h"

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static forseti_value_t val_str(const char *s) {
	forseti_value_t v;
	memset(&v, 0, sizeof(v));
	v.kind = FORSETI_VAL_STRING;
	v.as.str = s;
	return v;
}

static forseti_value_t val_i64(int64_t n) {
	forseti_value_t v;
	memset(&v, 0, sizeof(v));
	v.kind = FORSETI_VAL_I64;
	v.as.i64 = n;
	return v;
}

static void expect_substr(const char *haystack, const char *needle, const char *label) {
	if (haystack == NULL || strstr(haystack, needle) == NULL) {
		fprintf(stderr, "assertion failed (%s): expected %s in %s\n",
			label, needle, haystack ? haystack : "(null)");
		abort();
	}
}

int main(void) {
	const char *ver = forseti_abi_version();
	assert(ver != NULL && strlen(ver) > 0);

	/* 1. Compile error returns FORSETI_ERR_COMPILE with JSON diagnostics. */
	forseti_rulebase_t *bad_rb = NULL;
	char *bad_diags = NULL;
	forseti_status_t st = forseti_rulebase_compile(
		"rule broken { when true then noop() }",
		"bad.forseti",
		false,
		&bad_rb,
		&bad_diags
	);
	assert(st == FORSETI_ERR_COMPILE);
	assert(bad_rb == NULL);
	expect_substr(bad_diags, "\"error_count\"", "bad_diags");
	forseti_free_string(bad_diags);

	/* 2. Compile valid baseline & candidate rulebases. */
	const char *base_src =
		"module capi_test version \"1.0\"\n"
		"schema Order { id: string, amount: i64 }\n"
		"schema Flag  { id: string, reason: string }\n"
		"source orders: Order at .orders[?id]\n"
		"derived flags: Flag at .flags[?id]\n"
		"rule high_value {\n"
		"  when {\n"
		"    orders(id: ?id, amount: ?amt)\n"
		"    where ?amt >= 100\n"
		"  }\n"
		"  then {\n"
		"    assert flags(id: ?id, reason: \"high_value\")\n"
		"  }\n"
		"}\n"
		"query flagged() {\n"
		"  flags(id: ?id, reason: ?reason)\n"
		"}\n";

	const char *cand_src =
		"module capi_test version \"1.1\"\n"
		"schema Order { id: string, amount: i64 }\n"
		"schema Flag  { id: string, reason: string }\n"
		"source orders: Order at .orders[?id]\n"
		"derived flags: Flag at .flags[?id]\n"
		"rule high_value {\n"
		"  when {\n"
		"    orders(id: ?id, amount: ?amt)\n"
		"    where ?amt >= 50\n"
		"  }\n"
		"  then {\n"
		"    assert flags(id: ?id, reason: \"high_value\")\n"
		"  }\n"
		"}\n"
		"query flagged() {\n"
		"  flags(id: ?id, reason: ?reason)\n"
		"}\n";

	forseti_rulebase_t *base_rb = NULL;
	char *diags_json = NULL;
	st = forseti_rulebase_compile(base_src, "base.forseti", true, &base_rb, &diags_json);
	if (st != FORSETI_OK) {
		fprintf(stderr, "base compile failed (%d): %s\n", (int)st, diags_json ? diags_json : "(null)");
	}
	assert(st == FORSETI_OK);
	assert(base_rb != NULL);
	expect_substr(diags_json, "\"ok\":true", "base_diags");
	forseti_free_string(diags_json);

	forseti_rulebase_t *cand_rb = NULL;
	st = forseti_rulebase_compile(cand_src, "cand.forseti", true, &cand_rb, NULL);
	assert(st == FORSETI_OK);
	assert(cand_rb != NULL);

	/* 3. Session lifecycle, fact CRUD, fire, query, explain, impact, telemetry. */
	forseti_session_t *sess = NULL;
	st = forseti_session_create(base_rb, FORSETI_PROV_AUDIT_FULL, 0, &sess);
	assert(st == FORSETI_OK && sess != NULL);

	forseti_value_t f1[] = { val_str("o1"), val_i64(150) };
	uint64_t o1_id = 0;
	st = forseti_session_insert_fact(sess, "orders", "o1", f1, 2, &o1_id);
	assert(st == FORSETI_OK && o1_id > 0);

	uint64_t fired = 0;
	st = forseti_session_fire(sess, &fired);
	assert(st == FORSETI_OK && fired == 1);

	char *q_json = NULL;
	st = forseti_session_query_json(sess, "flagged", NULL, NULL, 0, &q_json);
	if (st != FORSETI_OK) {
		fprintf(stderr, "query failed with st=%d\n", (int)st);
	}
	assert(st == FORSETI_OK);
	expect_substr(q_json, "\"o1\"", "query_o1");
	expect_substr(q_json, "\"high_value\"", "query_reason");
	forseti_free_string(q_json);

	/* Modify o1 below threshold -> JTMS retracts derived flag; re-raise -> re-derives. */
	forseti_value_t f1_low[] = { val_str("o1"), val_i64(25) };
	st = forseti_session_modify_fact(sess, "orders", "o1", f1_low, 2);
	assert(st == FORSETI_OK);
	st = forseti_session_fire(sess, &fired);
	assert(st == FORSETI_OK);

	q_json = NULL;
	st = forseti_session_query_json(sess, "flagged", NULL, NULL, 0, &q_json);
	assert(st == FORSETI_OK);
	expect_substr(q_json, "\"row_count\":0", "query_retracted");
	forseti_free_string(q_json);

	st = forseti_session_insert_fact(sess, "orders", "o1", f1, 2, &o1_id);
	assert(st == FORSETI_OK);
	st = forseti_session_fire(sess, &fired);
	assert(st == FORSETI_OK && fired == 1);

	char *exp_json = NULL;
	st = forseti_session_explain_json(sess, o1_id, &exp_json);
	assert(st == FORSETI_OK);
	expect_substr(exp_json, "\"binding\":\"orders\"", "explain_orders");
	forseti_free_string(exp_json);

	char *imp_json = NULL;
	st = forseti_session_impact_json(sess, "high_value", NULL, &imp_json);
	assert(st == FORSETI_OK);
	expect_substr(imp_json, "\"rule_name\":\"high_value\"", "impact_rule");
	forseti_free_string(imp_json);

	char *tel_jsonl = NULL;
	st = forseti_session_telemetry_jsonl(sess, &tel_jsonl);
	assert(st == FORSETI_OK);
	assert(tel_jsonl != NULL);
	forseti_free_string(tel_jsonl);

	st = forseti_session_retract_fact(sess, "orders", "o1");
	assert(st == FORSETI_OK);
	st = forseti_session_fire(sess, &fired);
	assert(st == FORSETI_OK);

	/* 4. Store + sync_and_fire + diff_replay JSON comparing baseline vs candidate. */
	forseti_store_t *store = NULL;
	st = forseti_store_open(NULL, &store);
	assert(st == FORSETI_OK && store != NULL);

	const char *f_names[] = { "id", "amount" };
	forseti_value_t f2[] = { val_str("o2"), val_i64(75) };
	st = forseti_store_put_record(store, ".orders", "o2", f_names, f2, 2);
	assert(st == FORSETI_OK);

	forseti_session_t *replay_sess = NULL;
	st = forseti_session_create(base_rb, FORSETI_PROV_AUDIT_FULL, 0, &replay_sess);
	assert(st == FORSETI_OK && replay_sess != NULL);

	const char *watched[] = { ".orders" };
	st = forseti_session_sync_and_fire(replay_sess, store, watched, 1, false, &fired);
	assert(st == FORSETI_OK && fired == 0);

	char *diff_json = NULL;
	st = forseti_session_diff_replay_json(replay_sess, store, cand_rb, watched, 1, &diff_json);
	if (st != FORSETI_OK) {
		fprintf(stderr, "diff_replay failed st=%d\n", (int)st);
	}
	assert(st == FORSETI_OK);
	expect_substr(diff_json, "\"added_count\":1", "diff_added_count");
	forseti_free_string(diff_json);

	char *stateless_diff = NULL;
	st = forseti_diff_replay_json(store, base_rb, cand_rb, watched, 1, &stateless_diff);
	assert(st == FORSETI_OK);
	expect_substr(stateless_diff, "\"added_count\":1", "stateless_diff_added_count");
	forseti_free_string(stateless_diff);

	st = forseti_session_retract_fact_id(sess, o1_id);
	assert(st == FORSETI_OK);

	/* Free NULL is safe no-op. */
	forseti_free_string(NULL);

	forseti_session_destroy(replay_sess);
	forseti_store_destroy(store);
	forseti_session_destroy(sess);
	forseti_rulebase_destroy(cand_rb);
	forseti_rulebase_destroy(base_rb);
	printf("CAPI_SMOKE_OK\n");
	return 0;
}
