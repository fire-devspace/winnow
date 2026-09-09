[Back to main README](../../README.md)

# Regression tests for repository tooling

These Python tests check CI selection, public journey generation and code-size
reports. They prevent skipped checks being mistaken for evidence, missing test
mappings, and changes in counting policy that produce misleading output.

[test_ci_required.py](test_ci_required.py) checks changed-file selection and
requires successful jobs on an identical source tree before reusing PR evidence.
CI and Node integration run it on Linux before selecting their Mac jobs.

[test_build_site.py](test_build_site.py) exercises journey
validation and generation. [test_report_loc.py](test_report_loc.py)
uses temporary repositories to check file categories and historical comparisons.
Its synthetic infra paths intentionally test older trees after that directory's deletion.

From the root, run `python3 -m unittest discover -s scripts/tests -p test_build_site.py`.
For both suites, download and checksum-verify cloc 2.10 as in
[LOC CI](../../.github/workflows/loc.yml), then run
`CLOC=/path/to/cloc-2.10.pl python3 -m unittest discover -s scripts/tests`.
The LOC suite requires `CLOC`; omitting it is an error.
[Website CI](../../.github/workflows/site.yml) runs the generator regressions.
These tests validate tooling behavior, not the rendered webpage or the app itself.
