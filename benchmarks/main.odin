package main

import hugi "hugi:."
import "core:fmt"
import "core:os"

main :: proc() {
	suite := hugi.suite_create("forseti_benchmarks")
	defer hugi.suite_destroy(&suite)

	register_table_benchmarks(&suite)

	if !hugi.suite_run(&suite) {
		fmt.eprintln("forseti benchmarks failed")
		os.exit(1)
	}
}
