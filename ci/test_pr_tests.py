import tempfile
import unittest
from pathlib import Path

from pr_tests import select

FILES = {
    "ChatViewModelTests.swift": "final class ChatViewModelTests: XCTestCase {}\nfinal class ChatViewModelMoreTests: APIClientTestCase {}\n",
    "OtherTests.swift": "final class OtherTests: XCTestCase {}\n",
    "EditorTests.swift": (
        "final class EditorTests: XCTestCase {}\n"
        "@MainActor\nfinal class EditorPhotoTests: XCTestCase { let d = env[\"FOTO_DIR\"]; let v = AgentEditorView() }\n"
    ),
}


class SelectTests(unittest.TestCase):
    def setUp(self):
        root = Path(tempfile.mkdtemp())
        self.tests = root / "HermesMobileTests"
        self.tests.mkdir()
        for name, text in FILES.items():
            (self.tests / name).write_text(text)

    def test_picks_touched_tests_named_tests_and_photos_of_touched_screens(self):
        changed = [
            "HermesMobileTests/OtherTests.swift",
            "HermesMobile/Features/Chat/ChatViewModel.swift",
            "HermesMobile/Features/Agents/AgentEditorView.swift",
            "HermesMobile/Resources/Localizable.xcstrings",
        ]
        self.assertEqual(
            select(changed, self.tests),
            ["ChatViewModelMoreTests", "ChatViewModelTests", "EditorPhotoTests", "LocalizationCatalogTests", "OtherTests"],
        )

    def test_red_branch_picks_only_the_touched_test_classes_without_photos(self):
        changed = [
            "HermesMobileTests/EditorTests.swift",
            "HermesMobile/Features/Chat/ChatViewModel.swift",
            "HermesMobile/Resources/Localizable.xcstrings",
        ]
        self.assertEqual(select(changed, self.tests, red=True), ["EditorTests"])

    def test_check_and_photo_parts_split_the_selection(self):
        changed = [
            "HermesMobileTests/OtherTests.swift",
            "HermesMobile/Features/Agents/AgentEditorView.swift",
            "HermesMobile/Resources/Localizable.xcstrings",
        ]
        self.assertEqual(select(changed, self.tests, part="test"), ["LocalizationCatalogTests", "OtherTests"])
        self.assertEqual(select(changed, self.tests, part="foto"), ["EditorPhotoTests"])

    def test_untested_change_selects_nothing(self):
        self.assertEqual(select(["docs/readme.md", "HermesMobile/Unrelated.swift"], self.tests), [])


if __name__ == "__main__":
    unittest.main()
