import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('publish_routing_pack', ROOT / 'scripts/publish_routing_pack.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class RoutingPublicationTests(unittest.TestCase):
    def test_bundled_descriptor_has_only_a_fixed_public_pack_path(self):
        source = MODULE.descriptor('netherlands')
        self.assertEqual(MODULE.public_url(source), 'https://places-app.b-cdn.net/maps/routing/netherlands/2026.10.08/valhalla.zip')
        self.assertEqual(source['bytes'], 347647021)
        with self.assertRaises(ValueError): MODULE.descriptor('../other')

    def test_immutable_objects_are_not_overwritten_and_corruption_blocks_upload(self):
        with tempfile.TemporaryDirectory() as folder:
            file = Path(folder) / 'public.zip'; file.write_bytes(b'Synthetic public archive')
            source = dict(country='synthetic', pack=dict(version='1.0'), bytes=file.stat().st_size,
                          sha256=hashlib.sha256(file.read_bytes()).hexdigest())
            class Storage:
                def __init__(self): self.calls = []
                def request(self, method, path, *args):
                    self.calls.append(method)
                    return b'[{"ObjectName":"valhalla.zip"}]'
            storage = Storage()
            with patch.object(MODULE, 'verify_public') as verify:
                MODULE.publish(file, source, storage)
                self.assertEqual(storage.calls, ['GET']); verify.assert_called_once_with(source)
            file.write_bytes(b'Changed')
            with self.assertRaises(ValueError): MODULE.publish(file, source, storage)
            self.assertEqual(storage.calls, ['GET'])

    def test_workflow_uses_existing_secret_and_only_validated_main(self):
        text = (ROOT / '.github/workflows/routing.yml').read_text()
        self.assertIn("github.ref == 'refs/heads/main'", text)
        self.assertIn('secrets.BUNNY_STORAGE_KEY', text)
        self.assertIn('python3 -m py_compile', text)
        self.assertIn('persist-credentials: false', text)
        self.assertNotIn('contents: write', text)
        self.assertNotIn('pull_request', text)


if __name__ == '__main__': unittest.main()
