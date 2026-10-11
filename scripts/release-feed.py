#!/usr/bin/env python3
"""Small, dependency-free helpers for release versions and Sparkle recalls."""
import argparse
import json
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
TAG = re.compile(r'v[0-9]{4}\.[0-9]{1,2}\.([0-9]+)')
ET.register_namespace('sparkle', SPARKLE)


def build_number(tag):
    match = TAG.fullmatch(tag)
    if not match:
        raise ValueError(f'Invalid release tag: {tag}')
    return int(match[1])


def recall(path, tag):
    number = build_number(tag)
    tree = ET.parse(path)
    channel = tree.getroot().find('channel')
    if channel is None:
        raise ValueError('Appcast has no channel')
    removed = 0
    for item in list(channel.findall('item')):
        if (item.findtext(f'{{{SPARKLE}}}version') == str(number)
                or item.findtext(f'{{{SPARKLE}}}shortVersionString') == tag[1:]):
            channel.remove(item)
            removed += 1
    ET.indent(tree, space='  ')
    tree.write(path, encoding='utf-8', xml_declaration=True)
    return removed


def latest_stable(releases, excluded_tag):
    """Restore GitHub Latest without moving backward when recalling an older build."""
    build_number(excluded_tag)
    eligible = [r for r in releases if TAG.fullmatch(r.get('tag_name', ''))
                and r['tag_name'] != excluded_tag
                and not r.get('draft') and not r.get('prerelease')
                and '<!-- commander-recalled -->' not in (r.get('body') or '')]
    if not eligible:
        return None
    return max(eligible, key=lambda r: build_number(r['tag_name']))['tag_name']


def notes_context(releases, target):
    """Compare with the latest public stable release, never a recalled build."""
    target_number = build_number(target)
    earlier = [r for r in releases if TAG.fullmatch(r.get('tag_name', ''))
               and build_number(r['tag_name']) < target_number]
    stable = [r for r in earlier if not r.get('draft') and not r.get('prerelease')
              and '<!-- commander-recalled -->' not in (r.get('body') or '')]
    if not stable:
        raise ValueError('No published stable release found for release-note comparison')
    base = max(stable, key=lambda r: build_number(r['tag_name']))['tag_name']
    recalled = sorted({r['tag_name'] for r in earlier
                       if build_number(r['tag_name']) > build_number(base)
                       and '<!-- commander-recalled -->' in (r.get('body') or '')},
                      key=build_number)
    return {'base': base, 'recalled': recalled}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    withdrawal = commands.add_parser('recall')
    withdrawal.add_argument('feed', type=Path)
    withdrawal.add_argument('tag')
    notes = commands.add_parser('notes-context')
    notes.add_argument('target')
    latest = commands.add_parser('latest-stable')
    latest.add_argument('excluded_tag')
    args = parser.parse_args()
    if args.command == 'recall':
        print(f'Removed {recall(args.feed, args.tag)} appcast entries for {args.tag}')
    elif args.command == 'latest-stable':
        print(latest_stable(json.load(sys.stdin), args.excluded_tag) or '')
    else:
        print(json.dumps(notes_context(json.load(sys.stdin), args.target)))
