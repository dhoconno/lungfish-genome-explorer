from pathlib import Path
import unittest

from scripts.release.swiftpm_build import build_options


class SwiftPMBuildOptionsTests(unittest.TestCase):
    def test_selected_sdk_is_forwarded_intact_to_the_darwin_linker(self):
        sdk = '/Applications/Xcode Test.app/SDKs/MacOSX27.0.sdk'
        args = build_options(sdk)
        self.assertEqual(args[:2], ['--build-system', 'swiftbuild'])
        forwarded = [args[i + 1] for i, arg in enumerate(args) if arg == '-Xswiftc']
        self.assertEqual(forwarded, ['-Xclang-linker', '-isysroot', '-Xclang-linker', sdk])
        self.assertNotIn('-target', args)

    def test_ambiguous_sdk_paths_are_rejected(self):
        for path in ('', 'SDKs/MacOSX.sdk', '/sdk\nother', '/sdk\r', '/sdk\0'):
            with self.subTest(path=repr(path)), self.assertRaises(ValueError):
                build_options(path)
