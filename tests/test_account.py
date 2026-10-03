#!/usr/bin/env python3
"""Run production account boundaries on Foundation, or emit a safe device fixture."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'app/rewind_account.m').read_text()


def function(name):
    match = re.search(r'^static [^\n]*\b' + name + r'\([^;]+?\)\s*\{', SOURCE, re.M)
    assert match, name
    start = SOURCE.index('{', match.start())
    end = start + 1
    depth = 1
    while depth:
        depth += (SOURCE[end] == '{') - (SOURCE[end] == '}')
        end += 1
    return SOURCE[match.start():end]


def fixture_source():
    units = ['#import <Foundation/Foundation.h>', '#include <math.h>', '#include <stdio.h>']
    for constant in ['RewindOAuthClientID', 'RewindOAuthClientSecret', 'RewindAccountErrorDomain']:
        match = re.search(r'static NSString \* const ' + constant + r'\s*=\s*[^;]+;', SOURCE)
        assert match, constant
        units.append(match.group())
    match = re.search(r'enum \{ RewindAccountMaxDepth = [0-9]+ \};', SOURCE)
    assert match
    units.append(match.group())
    start = SOURCE.index('typedef struct {\n    BOOL loaded;')
    end = SOURCE.index('static rewind_account_state_t g_account;', start)
    end += len('static rewind_account_state_t g_account;')
    units.append(SOURCE[start:end])
    units.append('static NSString *fixture_home;\n'
                 'static NSString *RewindFixtureHomeDirectory(void) { return fixture_home; }\n'
                 '#define NSHomeDirectory RewindFixtureHomeDirectory')
    names = ['RewindAccountString', 'RewindAccountDict', 'RewindAccountArray',
             'RewindAccountSeconds', 'RewindAccountSetString', 'RewindAccountStorePath',
             'RewindAccountLoadState', 'RewindAccountWriteState', 'RewindAccountOAuthCredential',
             'RewindAccountResponseError', 'RewindTVIsID', 'RewindTVText',
             'RewindAccountSelectedItem']
    units.extend(function(name) for name in names)
    units.append((ROOT / 'tests/test_account.m').read_text())
    return '\n'.join(units)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--emit-fixture', type=Path, help='write Foundation source for device compilation')
    args = parser.parse_args()
    source = fixture_source()
    if args.emit_fixture:
        args.emit_fixture.write_text(source)
        print('wrote production account fixture:', args.emit_fixture)
        return
    if sys.platform != 'darwin':
        print('SKIP production account fixture execution: Apple Foundation host required')
        return
    with tempfile.TemporaryDirectory(prefix='rewind-account-') as temporary:
        directory = Path(temporary)
        path = directory / 'account.m'
        path.write_text(source)
        binary = directory / 'account'
        subprocess.run([os.environ.get('CC', 'clang'), '-fno-objc-arc', '-fblocks',
                        '-Wall', '-Wextra', '-framework', 'Foundation', str(path),
                        '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == '__main__':
    main()
