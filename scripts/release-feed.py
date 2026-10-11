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


def next_build(tags):
    numbers = [build_number(tag) for tag in tags if TAG.fullmatch(tag)]
    if not numbers:
        raise ValueError('No release tags found; refusing to reset the build counter')
    return max(numbers) + 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    withdrawal = commands.add_parser('recall')
    withdrawal.add_argument('feed', type=Path)
    withdrawal.add_argument('tag')
    commands.add_parser('next-build')
    args = parser.parse_args()
    if args.command == 'recall':
        print(f'Removed {recall(args.feed, args.tag)} appcast entries for {args.tag}')
    else:
        print(next_build(json.load(sys.stdin)))
