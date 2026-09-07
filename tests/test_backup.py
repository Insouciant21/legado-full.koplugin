from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest
import zipfile

from legado_kindle.backup import ANDROID_BACKUP_FILES, BackupBundle, BackupError
from legado_kindle.state import StateDirectory, StateError, export_state, import_bundle


class BackupTests(unittest.TestCase):
    def make_archive(self, directory: Path) -> Path:
        path = directory / "sample.zip"
        source = {
            "bookSourceType": 0,
            "bookSourceUrl": "https://example.invalid",
            "bookSourceName": "fixture",
            "exploreUrl": "/explore/{{page}}",
            "enabledCookieJar": True,
            "jsLib": "function helper() {}",
            "ruleBookInfo": {"name": "@css:h1@text"},
            "ruleContent": {"content": "@css:article@text", "nextContentUrl": "@css:a.next@href"},
            "ruleToc": {"chapterList": "@css:a", "nextTocUrl": "@css:a.next@href"},
        }
        json_members = {
            "bookshelf.json": [{"name": "fixture", "type": 0, "readConfig": {}}],
            "bookGroup.json": [{"groupId": 1, "groupName": "默认"}],
            "bookSource.json": [source],
            "rssSources.json": [],
            "readRecord.json": [],
            "readRecordDetail.json": [],
            "readRecordSession.json": [],
            "searchHistory.json": [],
            "txtTocRule.json": [],
            "httpTTS.json": [],
            "keyboardAssists.json": [],
            "dictRule.json": [],
            "readConfig.json": [],
            "shareReadConfig.json": {},
            "themeConfig.json": [],
        }
        with zipfile.ZipFile(path, "w") as archive:
            for filename in ANDROID_BACKUP_FILES:
                if filename in json_members:
                    data = json.dumps(json_members[filename], ensure_ascii=False).encode()
                elif filename == "servers.json":
                    data = b"opaque-server-state"
                else:
                    data = b'<map><boolean name="flag" value="true"/></map>'
                archive.writestr(filename, data)
        return path

    def test_summary_is_value_redacted_and_counts_rules(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = BackupBundle.load(self.make_archive(Path(temporary)))
            summary = archive.summary().as_dict()
            self.assertEqual(summary["counts"]["book_sources"], 1)
            self.assertEqual(summary["counts"]["bookshelf_books"], 1)
            self.assertEqual(summary["feature_usage"]["sources_with_js_lib"], 1)
            self.assertEqual(summary["feature_usage"]["sources_with_content_next_url"], 1)
            self.assertIn("nextContentUrl", summary["rule_keys"]["ruleContent"])
            rendered = str(summary)
            self.assertNotIn("https://example.invalid", rendered)
            self.assertNotIn("fixture", rendered)

    def test_roundtrip_preserves_opaque_member(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = self.make_archive(Path(temporary))
            original = BackupBundle.load(source)
            destination = Path(temporary) / "roundtrip.zip"
            original.write(destination)
            rewritten = BackupBundle.load(destination)
            self.assertEqual(rewritten.members["servers.json"], b"opaque-server-state")
            self.assertEqual(rewritten.members["config.xml"], original.members["config.xml"])
            self.assertEqual(rewritten.summary().missing_files, ())

    def test_zip_path_traversal_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "unsafe.zip"
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("../escape.json", "{}")
            with self.assertRaises(BackupError):
                BackupBundle.load(path)

            nested = Path(temporary) / "nested.zip"
            with zipfile.ZipFile(nested, "w") as archive:
                archive.writestr("nested/member.json", "{}")
            with self.assertRaises(BackupError):
                BackupBundle.load(nested)

    def test_state_directory_roundtrip_preserves_android_members(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = BackupBundle.load(self.make_archive(root))
            state = import_bundle(source, root / "state")
            self.assertIsInstance(state, StateDirectory)
            self.assertEqual(state.manifest()["state_schema_version"], 1)
            destination = root / "from-state.zip"
            export_state(state, destination)
            rewritten = BackupBundle.load(destination)
            self.assertEqual(rewritten.members, source.members)

    def test_state_directory_rejects_tampered_member(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = BackupBundle.load(self.make_archive(root))
            state = import_bundle(source, root / "state")
            (state.android_path / "servers.json").write_bytes(b"tampered")
            with self.assertRaises(StateError):
                state.load_bundle()


if __name__ == "__main__":
    unittest.main()
