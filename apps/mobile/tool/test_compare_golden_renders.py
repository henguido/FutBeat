import tempfile
import unittest
from pathlib import Path
from compare_golden_renders import compare


class ComparisonTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.head, self.base = [Path(self.directory.name) / name for name in ("head", "base")]
        for folder in (self.head, self.base):
            folder.mkdir()
            for suffix in ("test", "master"):
                (folder / f"scene_{suffix}Image.png").write_bytes(b"\x89PNG\r\n\x1a\nfixture")

    def test_exact_bytes_and_references(self):
        result, code = compare(self.head, self.base)
        self.assertEqual((result["status"], code), ("EXACT_RENDER_MATCH", 0))
        self.assertEqual(result["head_png_count"], 2)

    def test_changed_render_is_never_equivalent(self):
        (self.base / "scene_testImage.png").write_bytes(b"\x89PNG\r\n\x1a\ndifferent")
        self.assertEqual(compare(self.head, self.base)[1], 1)

    def test_changed_reference_is_never_equivalent(self):
        (self.base / "scene_masterImage.png").write_bytes(b"\x89PNG\r\n\x1a\nchanged-reference")
        self.assertEqual(compare(self.head, self.base)[1], 1)

    def test_relative_paths_not_just_names_are_compared(self):
        nested = self.base / "other-scene"
        nested.mkdir()
        for path in list(self.base.glob("*.png")):
            path.rename(nested / path.name)
        self.assertEqual(compare(self.head, self.base)[1], 1)

    def test_orphan_reference_is_incomplete(self):
        (self.base / "orphan_masterImage.png").write_bytes(b"\x89PNG\r\n\x1a\nfixture")
        self.assertEqual(compare(self.head, self.base)[1], 2)

    def test_missing_reference_is_incomplete(self):
        (self.base / "scene_masterImage.png").unlink()
        self.assertEqual(compare(self.head, self.base)[1], 2)

    def test_invalid_or_empty_file_is_incomplete(self):
        (self.base / "scene_testImage.png").write_bytes(b"")
        self.assertEqual(compare(self.head, self.base)[1], 2)

    def test_empty_set_is_never_success(self):
        for path in self.base.iterdir():
            path.unlink()
        self.assertEqual(compare(self.head, self.base)[1], 2)


if __name__ == "__main__":
    unittest.main()
