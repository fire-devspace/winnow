[Back to main README](../../README.md)

# Regression tests for repository tooling

These Python tests check the two scripts that turn repository data into public
journey pages and code-size reports. They prevent missing test mappings or changes
in counting policy from silently producing misleading output.

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
