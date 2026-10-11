#!/usr/bin/env python3
"""Adjust SwiftPM's app resource lookup after planning, immediately before compile."""
import os
from pathlib import Path
import shlex
import sys


def patch_sources(arguments):
    for argument in arguments:
        if argument.startswith('@') and Path(argument[1:]).is_file():
            patch_sources(shlex.split(Path(argument[1:]).read_text()))
        elif Path(argument).name == 'resource_bundle_accessor.swift':
            path = Path(argument)
            original = path.read_text()
            fixed = original.replace('Bundle.main.bundleURL.appendingPathComponent',
                                     'Bundle.main.resourceURL!.appendingPathComponent')
            if 'Bundle.main.resourceURL!.appendingPathComponent' not in fixed:
                raise RuntimeError(f'Unsupported SwiftPM resource accessor: {path}')
            if fixed != original:
                path.write_text(fixed)


if __name__ == '__main__':
    patch_sources(sys.argv[1:])
    compiler = os.environ['COMMANDER_REAL_SWIFTC']
    os.execv(compiler, [compiler, *sys.argv[1:]])
