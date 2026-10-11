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

    def test_counter_uses_highest_retained_tag_across_months(self):
        self.assertEqual(feed.next_build(['v2026.9.80', 'v2026.10.81', 'other', 'v2026.8.79']), 82)
        with self.assertRaises(ValueError):
            feed.next_build([])

    def test_invalid_tag_is_rejected(self):
        for tag in ['v2026.10.81;echo bad', '2026.10.81', '../81']:
            with self.assertRaises(ValueError):
                feed.build_number(tag)


if __name__ == '__main__':
    unittest.main()
