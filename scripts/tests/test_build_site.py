import importlib.machinery
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

loader = importlib.machinery.SourceFileLoader("build_site", str(Path(__file__).parents[1] / "build-site"))
spec = importlib.util.spec_from_loader(loader.name, loader)
site = importlib.util.module_from_spec(spec)
loader.exec_module(site)

class JourneyOwnershipTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "docs/screenshots").mkdir(parents=True)
        (self.root / "UITests").mkdir()
        self.source = self.root / site.TEST_PATH
        self.source.write_text('    func test01Receive() {\n        Screenshots.capture(app, "receive", testCase: self)\n    }\n')
        (self.root / "docs/screenshots/receive.png").write_bytes(b"fixture")
        self.journeys = [{"id": "receive", "section": "everyday", "tests": ["test01Receive"], "image": "receive"}]
        self.save()

    def save(self):
        (self.root / "docs/journeys.json").write_text(json.dumps(self.journeys))

    def test_real_scenario_and_its_capture_are_accepted(self):
        journeys, cases = site.load_journeys(self.root)
        self.assertEqual(len(journeys), 1)
        self.assertEqual(set(cases), {"test01Receive"})

    def test_removed_test_cannot_keep_supporting_a_claim(self):
        self.source.write_text("")
        with self.assertRaisesRegex(ValueError, "missing app test"):
            site.load_journeys(self.root)

    def test_new_scenario_needs_a_documented_purpose(self):
        self.source.write_text(self.source.read_text() + "    func test02Undocumented() {}\n")
        with self.assertRaisesRegex(ValueError, "need a documented journey"):
            site.load_journeys(self.root)

    def test_capture_from_another_scenario_is_rejected(self):
        self.source.write_text("    func test01Receive() {}\n")
        with self.assertRaisesRegex(ValueError, "not captured by its app tests"):
            site.load_journeys(self.root)

    def test_duplicate_journey_and_missing_image_are_rejected(self):
        self.journeys.append(dict(self.journeys[0]))
        self.save()
        with self.assertRaisesRegex(ValueError, "duplicate or invalid"):
            site.load_journeys(self.root)
        self.journeys.pop()
        self.save()
        (self.root / "docs/screenshots/receive.png").unlink()
        with self.assertRaisesRegex(ValueError, "missing screenshot"):
            site.load_journeys(self.root)

if __name__ == "__main__":
    unittest.main()
