"""Exercise the reporter against small committed repositories and real cloc."""

import csv
import importlib.util
import json
import os
import pathlib
import subprocess
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("report_loc", pathlib.Path(__file__).parents[1] / "report-loc.py")
LOC = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LOC)


class ReportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cloc = pathlib.Path(os.environ["CLOC"]).resolve()
        LOC.validate_counter(cls.cloc)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "Test Author")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "commit.gpgsign", "false")

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.root), *args], stderr=subprocess.PIPE).decode().strip()

    def put(self, path, content):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content.encode() if isinstance(content, str) else content)

    def commit(self):
        self.git("add", "--all")
        self.git("commit", "-qm", "fixture")
        return self.git("rev-parse", "HEAD")

    def report(self, base=None):
        return LOC.report(self.root, "HEAD", base, self.cloc, "example/library")

    def test_categories_and_exclusions(self):
        contents = {
            "Sources/core.swift": "// comment\n\nlet value = 1\n",
            "Sources/duplicate.swift": "// comment\n\nlet value = 1\n",
            "Tests/CoreTests/test.swift": "let testValue = 2\n",
            "Tests/CoreTests/Vectors/vector.swift": "let vector = 3\n",
            "Tests/CoreTests/Fixtures/page.html": "<p>fixture</p>\n",
            "Tests/CoreTests/Vectors/data.mediawiki": "A vector\n\nAnother vector\n",
            "scripts/run": "#!/bin/sh\n# comment\nprintf 'ok\\n'\n",
            "scripts/tests/test_policy.py": "assert True\n",
            "infra/fixture/bootstrap.sh": "#!/bin/sh\ntrue\n",
            "infra/README.md": "# Runner setup\n",
            "Package.swift": "// manifest\nlet package = 1\n",
            "Package.resolved": '{"pins": []}\n',
            "docs/page.html": "<!-- comment -->\n<p>Hello</p>\n",
            "docs/style.css": "body { color: black; }\n",
            "docs/app.js": "const value = 1;\n",
            "notes.unknown": "Unknown text\n\nMore text\n",
            "Sources/BitcoinP2P/Protocol/FallbackPeersGenerated.swift": "let generated = 1\n",
            "vendor/dependency.swift": "let dependency = 1\n",
            ".build/cache.swift": "let cache = 1\n",
            "docs/binary.png": b"\x89PNG\r\n\x1a\n\0binary",
            "docs/lfs.png": "version https://git-lfs.github.com/spec/v1\noid sha256:" + "0" * 64 + "\nsize 12\n",
            "Sources/space café|name.swift": "let unicode = 1\n",
        }
        for path, content in contents.items():
            self.put(path, content)
        (self.root / "Sources/link.swift").symlink_to("core.swift")
        self.commit()
        result = self.report()["head"]
        files = {file["path"]: file for file in result["files"]}
        self.assertEqual(len(files), len(contents) + 1)
        self.assertEqual(files["Sources/core.swift"]["source_loc"], 1)
        self.assertEqual(files["Sources/duplicate.swift"]["source_loc"], 1)
        self.assertEqual(result["categories"]["source"]["source_loc"], 3)
        self.assertEqual(result["categories"]["tests"]["source_loc"], 2)
        self.assertEqual(result["categories"]["webpages"]["source_loc"], 3)
        self.assertEqual(files["scripts/run"]["category"], "tooling")
        self.assertEqual(files["scripts/run"]["language"], "Bourne Shell")
        self.assertEqual(files["infra/fixture/bootstrap.sh"]["category"], "tooling")
        for path in ("Tests/CoreTests/Vectors/vector.swift", "Tests/CoreTests/Fixtures/page.html", "infra/README.md", "Package.resolved", "notes.unknown"):
            self.assertEqual(files[path]["category"], "other", path)
            self.assertEqual(files[path]["source_loc"], 0, path)
        self.assertEqual(files["notes.unknown"]["nonblank"], 2)
        self.assertEqual(files["docs/lfs.png"]["reason"], "LFS pointer")
        self.assertEqual(files["docs/binary.png"]["reason"], "binary/non-UTF-8")
        self.assertEqual(result["exclusions"], {"LFS pointer": 1, "binary/non-UTF-8": 1, "dependency/build output": 2, "generated source": 1, "symlink": 1})
        self.assertEqual(result["source_loc"], sum(file["source_loc"] for file in files.values()))
        self.assertEqual(LOC.category("PlatformTests/KeychainAttributeTests.swift"), "tests")
        self.assertEqual(LOC.category("PlatformTests/project.yml"), "tooling")
        self.assertEqual(LOC.category("Fuzz/Sources/WinnowFuzz/main.swift"), "tests")
        self.assertEqual(LOC.category("Fuzz/Package.swift"), "tooling")
        self.assertEqual(LOC.category("Fuzz/Package.resolved"), "other")
        self.assertEqual(LOC.category("Sources/WinnowApp/App.swift"), "source")
        self.assertEqual(LOC.category("Tests/NodeSupport/SignetMiner.swift"), "tests")
        self.assertEqual(LOC.category("Tools/Story/Sources/CLI.swift"), "tooling")
        self.assertEqual(LOC.category("Tools/Story/Tests/StoryTests.swift"), "tests")
        self.assertEqual(LOC.category("Fuzz/README.md"), "other")
        self.assertEqual(LOC.category("Fuzz/corpus/transaction.hex"), "other")
        self.assertEqual(LOC.exclusion("Fuzz/.build/checkouts/dependency.swift", "100644"), "dependency/build output")

    def test_merge_base_additions_deletions_and_renames(self):
        self.put("Sources/remove.swift", "let removed = 1\n")
        self.put("Sources/rename.swift", "let stable = 1\n")
        ancestor = self.commit()
        self.git("checkout", "-qb", "base")
        self.put("Sources/base_only.swift", "let baseOnly = 1\n")
        base_tip = self.commit()
        self.git("checkout", "-qb", "feature", ancestor)
        self.git("rm", "Sources/remove.swift")
        self.git("mv", "Sources/rename.swift", "Sources/renamed.swift")
        self.put("Sources/add.swift", "let one = 1\nlet two = 2\n")
        head = self.commit()
        result = self.report(base_tip)
        self.assertEqual(result["base"]["commit"], ancestor)
        self.assertEqual(result["base_tip"], base_tip)
        self.assertEqual(result["head"]["commit"], head)
        self.assertEqual(result["delta"]["source_loc"], 1)
        self.assertEqual(result["delta"]["categories"]["source"]["files"], 0)
        # Working-tree changes and untracked build artifacts cannot alter a report.
        self.put("Sources/add.swift", "let dirty = 100\n")
        self.put(".build/downloaded.swift", "let ignored = 1\n")
        self.assertEqual(result, self.report(base_tip))

    def test_webpage_only_comparison(self):
        self.put("README.md", "# Library\n")
        base = self.commit()
        self.put("docs/page.html", "<p>One</p>\n<p>Two</p>\n")
        self.commit()
        result = self.report(base)
        self.assertEqual(result["base"]["categories"]["webpages"]["source_loc"], 0)
        self.assertEqual(result["delta"]["categories"]["webpages"]["source_loc"], 2)

    def test_artifacts_are_deterministic_and_agree(self):
        self.put("Sources/test.swift", "// comment\n\nlet value = 1\n")
        self.put("notes.unknown", "Some text\n")
        base = self.commit()
        self.put("Sources/test.swift", "let value = 1\nlet second = 2\n")
        self.commit()
        first = self.root / "first"
        second = self.root / "second"
        LOC.write_reports(self.report(base), first)
        LOC.write_reports(self.report(base), second)
        for name in ("loc.json", "loc.csv", "loc.md"):
            self.assertEqual((first / name).read_bytes(), (second / name).read_bytes())
        result = json.loads((first / "loc.json").read_text())
        with (first / "loc.csv").open(newline="") as source:
            rows = list(csv.DictReader(source))
        for role in ("head", "base"):
            selected = [row for row in rows if row["snapshot"] == role]
            self.assertEqual(sum(int(row["source_loc"]) for row in selected), result[role]["source_loc"])
            self.assertEqual(sum(int(row["nonblank"]) for row in selected if row["category"] == "other"), result[role]["other_nonblank"])
            self.assertEqual(len(selected), len(result[role]["files"]))
        self.assertIn("**Total source** | **2** | **+1**", (first / "loc.md").read_text())

    def test_empty_repository_tree_and_unknown_only_text(self):
        self.git("commit", "--allow-empty", "-qm", "empty")
        result = self.report()
        self.assertEqual(result["head"]["source_loc"], 0)
        self.assertEqual(set(result["head"]["categories"]), set(LOC.CATEGORIES))
        self.put("note.unknown", "unrecognized\n")
        self.commit()
        self.assertEqual(self.report()["head"]["other_nonblank"], 1)

    def test_counter_checksum_is_required(self):
        counter = self.root / "cloc.pl"
        counter.write_text("modified counter")
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            LOC.validate_counter(counter)


if __name__ == "__main__":
    unittest.main()
