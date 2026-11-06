import pathlib
import tempfile
import unittest
from build_web_release import verify_artifact


class HostingAppCheckGuardTest(unittest.TestCase):
    def test_rejects_missing_wrong_or_empty_key(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / 'main.dart.js').write_text('app-check: site key not configured')
            with self.assertRaises(RuntimeError):
                verify_artifact(root, 'registered-public-site-key')
            with self.assertRaises(RuntimeError):
                verify_artifact(root, '')
            (root / 'main.dart.js').write_text('different-public-site-key')
            with self.assertRaises(RuntimeError):
                verify_artifact(root, 'registered-public-site-key')

    def test_accepts_registered_key_without_changing_artifact(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / 'main.dart.js').write_text('registered-public-site-key')
            before = (root / 'main.dart.js').read_bytes()
            self.assertEqual(len(verify_artifact(root, 'registered-public-site-key')), 64)
            self.assertEqual((root / 'main.dart.js').read_bytes(), before)


if __name__ == '__main__':
    unittest.main()
