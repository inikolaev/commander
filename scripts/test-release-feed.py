import importlib.util
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location('release_feed', Path(__file__).with_name('release-feed.py'))
feed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(feed)


class ReleaseFeedTests(unittest.TestCase):
    def test_recall_removes_both_architectures_and_preserves_other_releases(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'appcast.xml'
            path.write_text(f'''<rss xmlns:sparkle="{feed.SPARKLE}"><channel><title>Updates</title>
                <item><sparkle:version>81</sparkle:version><title>ARM</title></item>
                <item><sparkle:version>81</sparkle:version><title>Intel</title></item>
                <item><sparkle:version>80</sparkle:version><enclosure url="older" sparkle:edSignature="keep"/></item>
                </channel></rss>''')
            self.assertEqual(feed.recall(path, 'v2026.10.81'), 2)
            remaining = ET.parse(path).findall('channel/item')
            self.assertEqual(len(remaining), 1)
            self.assertEqual(remaining[0].find('enclosure').get(f'{{{feed.SPARKLE}}}edSignature'), 'keep')
            self.assertEqual(feed.recall(path, 'v2026.10.81'), 0)

    def test_empty_feed_is_valid(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'appcast.xml'
            path.write_text(f'<rss xmlns:sparkle="{feed.SPARKLE}"><channel><item><sparkle:shortVersionString>2026.10.81</sparkle:shortVersionString></item></channel></rss>')
            self.assertEqual(feed.recall(path, 'v2026.10.81'), 1)
            self.assertEqual(ET.parse(path).findall('channel/item'), [])

    def test_invalid_feed_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'appcast.xml'
            path.write_text('<html/>')
            with self.assertRaises(ValueError):
                feed.recall(path, 'v2026.10.81')
            self.assertEqual(path.read_text(), '<html/>')

    def test_notes_skip_recalled_drafts_and_prereleases(self):
        releases = [
            {'tag_name': 'v2026.10.80', 'draft': False},
            {'tag_name': 'v2026.10.81', 'draft': True, 'body': '<!-- commander-recalled -->'},
            {'tag_name': 'v2026.10.82', 'draft': False, 'body': '<!-- commander-recalled -->'},
            {'tag_name': 'v2026.10.83', 'prerelease': True},
            {'tag_name': 'v2026.10.84', 'draft': True},
            {'tag_name': 'v2026.10.86', 'draft': False},
        ]
        self.assertEqual(feed.notes_context(releases, 'v2026.10.85'), {
            'base': 'v2026.10.80', 'recalled': ['v2026.10.81', 'v2026.10.82']})
        releases.append({'tag_name': 'v2026.10.85', 'draft': False})
        self.assertEqual(feed.notes_context(releases, 'v2026.10.86'), {
            'base': 'v2026.10.85', 'recalled': []})

    def test_notes_after_deleted_release_use_previous_public_release(self):
        self.assertEqual(feed.notes_context([{'tag_name': 'v2026.10.80'}], 'v2026.10.82'), {
            'base': 'v2026.10.80', 'recalled': []})
        with self.assertRaises(ValueError):
            feed.notes_context([], 'v2026.10.82')

    def test_latest_skips_recalled_drafts_and_prereleases(self):
        releases = [
            {'tag_name': 'v2026.9.79'},
            {'tag_name': 'v2026.10.80', 'body': None},
            {'tag_name': 'v2026.10.81', 'body': '<!-- commander-recalled -->'},
            {'tag_name': 'v2026.10.82'},
            {'tag_name': 'v2026.10.83', 'draft': True},
            {'tag_name': 'v2026.10.84', 'prerelease': True},
            {'tag_name': 'unrelated'},
        ]
        self.assertEqual(feed.latest_stable(releases, 'v2026.10.82'), 'v2026.10.80')
        # Recalling an older build must not demote a newer working release.
        self.assertEqual(feed.latest_stable(releases, 'v2026.10.81'), 'v2026.10.82')

    def test_latest_without_eligible_release(self):
        self.assertIsNone(feed.latest_stable([], 'v2026.10.81'))
        self.assertIsNone(feed.latest_stable([
            {'tag_name': 'v2026.10.81'},
            {'tag_name': 'v2026.10.80', 'body': '<!-- commander-recalled -->'},
        ], 'v2026.10.81'))

    def test_invalid_tag_is_rejected(self):
        for tag in ['v2026.10.81;echo bad', '2026.10.81', '../81']:
            with self.assertRaises(ValueError):
                feed.build_number(tag)


if __name__ == '__main__':
    unittest.main()
