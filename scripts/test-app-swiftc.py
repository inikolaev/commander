import importlib.util
from pathlib import Path
import shlex
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('app_swiftc', Path(__file__).with_name('app-swiftc.py'))
wrapper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wrapper)


class CompilerWrapperTests(unittest.TestCase):
    def test_regenerated_accessor_and_response_file_with_spaces(self):
        with tempfile.TemporaryDirectory(prefix='swift sources ') as directory:
            accessor = Path(directory) / 'resource_bundle_accessor.swift'
            response = Path(directory) / 'sources'
            response.write_text(shlex.quote(str(accessor)))
            # SwiftPM regenerates this on each planning pass.
            for _ in range(2):
                accessor.write_text('let mainPath = Bundle.main.bundleURL.appendingPathComponent("Example.bundle").path')
                wrapper.patch_sources(['@' + str(response), '-Xlinker', '@loader_path'])
                self.assertIn('Bundle.main.resourceURL!', accessor.read_text())
                wrapper.patch_sources([str(accessor)])
                self.assertNotIn('Bundle.main.bundleURL', accessor.read_text())

    def test_unknown_format_fails_instead_of_shipping_broken_lookup(self):
        with tempfile.TemporaryDirectory() as directory:
            accessor = Path(directory) / 'resource_bundle_accessor.swift'
            accessor.write_text('unknown future accessor format')
            with self.assertRaises(RuntimeError):
                wrapper.patch_sources([str(accessor)])


if __name__ == '__main__':
    unittest.main()
