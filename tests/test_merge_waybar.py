"""Offline regression tests; click commands are inert fixture data."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import tempfile
import unittest
from unittest import mock


HELPER = Path(__file__).resolve().parents[1] / "scripts-internal/merge_waybar.py"
SPEC = importlib.util.spec_from_file_location("merge_waybar", HELPER)
merge = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(merge)

COMMENTS = (
    '// "custom/claw": {"format": "old example"}',
    '/* "custom/claw" \t : {"format": "old example"} */',
    '/* example\n "custom/claw"\n : {"format": "old example"}\n */',
)
VALUES = {
    "url": "https://example.invalid/a//b",
    "delimiters": "/* ordinary text */ // still text",
    "quotes": 'say "hello" and "custom/claw": an example',
    "backslashes": 'C:\\fixtures\\ and a trailing slash\\',
    "unicode": "mañana 🐾 日本語",
}
ENV = {
    "BAR_ARRAY": "modules-right",
    "CLICK_LEFT": 'inert-left "quoted" \\ 🐾',
    "CLICK_RIGHT": "inert-right https://example.invalid/a",
    "CLICK_MIDDLE": "inert-middle /* data */ // data",
}


def parse_fixture(text, comment):
    """Independent oracle for these fixtures, not a general JSONC parser."""
    # The known comment occurs exactly once. Only an otherwise empty object
    # needs its inserted final comma removed; never normalize string values.
    text = text.replace(comment, "")
    text = re.sub(r",\s*}$", "}", text)
    pairs = []

    def object_pairs(items):
        pairs.append(items)
        return dict(items)

    result = json.loads(text, object_pairs_hook=object_pairs)
    return result, pairs[-1]


class DefinitionTests(unittest.TestCase):
    def test_import_does_not_run_merge_or_external_commands(self):
        module = importlib.util.module_from_spec(SPEC)
        with mock.patch("builtins.open", side_effect=AssertionError("config access")), \
                mock.patch("os.system", side_effect=AssertionError("external command")), \
                mock.patch("subprocess.Popen", side_effect=AssertionError("child process")), \
                mock.patch("socket.socket", side_effect=AssertionError("network")):
            SPEC.loader.exec_module(module)

    def test_commented_examples_are_not_definitions(self):
        for comment in COMMENTS:
            with self.subTest(comment=comment):
                self.assertFalse(merge.has_definition("{\n" + comment + "\n}"))

    def test_comments_beside_unrelated_member(self):
        for comment in COMMENTS:
            with self.subTest(comment=comment):
                text = '{\n' + comment + '\n "clock": {"format": "%H:%M"}\n}'
                self.assertFalse(merge.has_definition(text))

    def test_real_definition_with_whitespace_is_preserved(self):
        for whitespace in ("", " ", "\n\t "):
            with self.subTest(whitespace=whitespace):
                text = '{\n "custom/claw"' + whitespace + ': {"format": "mine"}\n}'
                self.assertTrue(merge.has_definition(text))
                self.assertEqual(merge.insert_definition(text), (text, False))

    def test_string_contents_are_data(self):
        text = json.dumps(VALUES, ensure_ascii=False)
        self.assertFalse(merge.has_definition(text))
        self.assertEqual(json.loads(merge.strip_jsonc(text)), VALUES)

    def test_comment_delimiters_in_existing_definition_are_data(self):
        text = json.dumps({"custom/claw": VALUES}, ensure_ascii=False)
        self.assertTrue(merge.has_definition(text))
        self.assertEqual(merge.insert_definition(text), (text, False))

    def test_insertion_preserves_every_original_character(self):
        for comment in COMMENTS:
            with self.subTest(comment=comment), mock.patch.dict(os.environ, ENV, clear=True):
                text = '{\n  ' + comment + '\n  "other": ' + json.dumps(VALUES) + '\n}'
                updated, changed = merge.insert_definition(text)
                self.assertTrue(changed)
                # Delete exactly the newly inserted line to recover the input.
                first, block, remainder = updated.split("\n", 2)
                self.assertEqual(first + "\n" + remainder, text)
                self.assertIn(comment, updated)
                self.assertEqual(merge.insert_definition(updated), (updated, False))


class MergeTests(unittest.TestCase):
    def run_merge(self, same_file, comment, existing=False, unrelated=True, empty_bar=False):
        with tempfile.TemporaryDirectory(prefix="merge-waybar-test-") as directory:
            root = Path(directory)
            config = root / "config.jsonc"
            modules = config if same_file else root / "modules.jsonc"
            members = []
            if existing:
                members.append('  "custom/claw" \t : ' + json.dumps(VALUES, ensure_ascii=False))
            if unrelated:
                members.append('  "other": ' + json.dumps(VALUES, ensure_ascii=False))
            if same_file:
                members.append('  "modules-right": ' + ('[]' if empty_bar else '["clock"]'))
            original = '{\n  ' + comment + '\n' + ',\n'.join(members) + '\n}\n'
            if not same_file:
                config.write_text(json.dumps({"modules-right": [] if empty_bar else ["clock"],
                                              "layer": "top"}) + '\n', encoding="utf-8")
            modules.write_text(original, encoding="utf-8")
            # This is the real helper main, confined to the two temp fixtures.
            # Trap accidental external execution or networking; commands stay data.
            real_open = open

            def fixture_open(path, *args, **kwargs):
                self.assertIn(Path(path), (config, modules))
                return real_open(path, *args, **kwargs)

            with mock.patch.dict(os.environ, ENV, clear=True), \
                    mock.patch("builtins.open", side_effect=fixture_open), \
                    mock.patch("os.system", side_effect=AssertionError("external command")), \
                    mock.patch("subprocess.Popen", side_effect=AssertionError("child process")), \
                    mock.patch("socket.socket", side_effect=AssertionError("network")), \
                    contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(merge.main([str(config), str(modules)]), 0)
                first_modules = modules.read_bytes()
                first_config = config.read_bytes()
                self.assertEqual(merge.main([str(config), str(modules)]), 0)
                self.assertEqual(modules.read_bytes(), first_modules)
                self.assertEqual(config.read_bytes(), first_config)

            output = first_modules.decode("utf-8")
            recovered = output
            if not existing:
                first, inserted, remainder = recovered.split("\n", 2)
                recovered = first + "\n" + remainder
            if same_file:
                recovered = recovered.replace('[ "custom/claw" ]', '[]') if empty_bar else \
                    recovered.replace('[ "custom/claw","clock"]', '["clock"]')
            self.assertIn(comment.encode(), first_modules)
            parsed, pairs = parse_fixture(output, comment)
            self.assertEqual([key for key, value in pairs].count("custom/claw"), 1)
            self.assertIn("custom/claw", parsed)
            self.assertEqual(recovered, original)
            if unrelated:
                self.assertEqual(parsed["other"], VALUES)
            if existing:
                self.assertEqual(parsed["custom/claw"], VALUES)
                if not same_file:
                    self.assertEqual(output, original)
            else:
                definition = parsed["custom/claw"]
                self.assertEqual(definition["on-click"], ENV["CLICK_LEFT"])
                self.assertEqual(definition["on-click-right"], ENV["CLICK_RIGHT"])
                self.assertEqual(definition["on-click-middle"], ENV["CLICK_MIDDLE"])
                self.assertEqual(definition["exec"], "clawbar-status")
            bar = parsed if same_file else json.loads(first_config)
            self.assertEqual(bar["modules-right"], ["custom/claw"] if empty_bar else ["custom/claw", "clock"])
            if not same_file:
                self.assertEqual(bar["layer"], "top")

    def test_separate_files_with_commented_examples(self):
        for comment in COMMENTS:
            for unrelated in (False, True):
                with self.subTest(comment=comment, unrelated=unrelated):
                    self.run_merge(False, comment, unrelated=unrelated)

    def test_same_file_with_commented_examples(self):
        for comment in COMMENTS:
            with self.subTest(comment=comment):
                self.run_merge(True, comment)

    def test_existing_definition_in_both_file_layouts(self):
        for same_file in (False, True):
            for comment in COMMENTS:
                with self.subTest(same_file=same_file, comment=comment):
                    self.run_merge(same_file, comment, existing=True)

    def test_empty_bar_and_comment_only_modules(self):
        for same_file in (False, True):
            for comment in COMMENTS:
                with self.subTest(same_file=same_file, comment=comment):
                    self.run_merge(same_file, comment, unrelated=False, empty_bar=True)

    def test_usage_error_is_unchanged(self):
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(merge.main([]), 2)


if __name__ == "__main__":
    unittest.main()
