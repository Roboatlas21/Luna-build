#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location(
    "native_deps_key", HERE / "native-dependency-key.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class NativeDependencyKeyTests(unittest.TestCase):
    def test_packaging_pin_changes_do_not_invalidate_native_dependencies(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for name in module.NATIVE_FILES:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("native recipe input\n")
            (root / "kernel/moonlight-vfm/bridge.c").write_text("int x;\n")
            sources = root / "packaging/coreelec-ng/vfm/sources.json"
            pins = {name: "original-" + name for name in module.SOURCE_KEYS}
            pins.update({"Luna": "a" * 40, "Luna_public_export": "b" * 40})
            sources.write_text(json.dumps(pins))
            baseline = module.fingerprint(root)
            pins["Luna"] = "c" * 40
            pins["Luna_public_export"] = "d" * 40
            sources.write_text(json.dumps(pins))
            self.assertEqual(module.fingerprint(root), baseline)

            pins["FFmpeg_sha256"] = "e" * 64
            sources.write_text(json.dumps(pins))
            self.assertNotEqual(module.fingerprint(root), baseline)

            native_change = module.fingerprint(root)
            (root / module.NATIVE_FILES[0]).write_text("changed recipe\n")
            self.assertNotEqual(module.fingerprint(root), native_change)

    def test_missing_native_build_recipe_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaisesRegex(ValueError, "Missing native dependency"):
                module.fingerprint(temp)


if __name__ == "__main__":
    unittest.main()
