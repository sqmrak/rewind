#!/usr/bin/env python3
"""Run the production retry predicate on any host and parsers on a Foundation host."""
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
API = (ROOT / 'app/rewind_api.m').read_text()
STREAM = (ROOT / 'app/rewind_stream.m').read_text()


def function(name, source=API):
    match = re.search(r'^(?:static [^\n]*|int )\b' + name + r'\(', source, re.M)
    assert match, name
    start = source.index('{', match.start())
    depth = 1
    end = start + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[match.start():end]


def retry_tests(directory):
    # compile the production predicate, replacing only objc field/block syntax
    start = STREAM.index('if ((status && status != 408') + len('if (')
    predicate = STREAM[start:STREAM.index(') break;', start)]
    predicate = predicate.replace('failure.code', 'failure_code').replace('(cancelled && cancelled())', 'cancelled')
    source = '''#include <assert.h>
    enum { NSURLErrorTimedOut = -1001, NSURLErrorNetworkConnectionLost = -1005 };
    static int stop(int status, int failure, int failure_code, int cancelled) {
        return PREDICATE;
    }
    int main(void) {
        int permanent[] = {200, 206, 301, 400, 401, 403, 404, 410};
        for (unsigned i = 0; i < sizeof(permanent)/sizeof(permanent[0]); ++i)
            assert(stop(permanent[i], 0, 0, 0));
        int transient[] = {0, 408, 429, 500, 502, 503};
        for (unsigned i = 0; i < sizeof(transient)/sizeof(transient[0]); ++i)
            assert(!stop(transient[i], 0, 0, 0));
        assert(!stop(0, 1, NSURLErrorTimedOut, 0));
        assert(!stop(0, 1, NSURLErrorNetworkConnectionLost, 0));
        assert(stop(0, 1, -1202, 0));
        assert(stop(0, 1, -999, 0));
        assert(stop(0, 0, 0, 1));
        return 0;
    }'''.replace('PREDICATE', predicate)
    path = directory / 'retry.c'
    path.write_text(source)
    binary = directory / 'retry'
    subprocess.run([os.environ.get('CC', 'cc'), '-std=c99', '-Wall', '-Wextra', '-Werror', str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
    print('production retry predicate checks passed')


def parser_tests(directory):
    names = ['RewindString', 'RewindCleanText', 'RewindText', 'RewindFindValueForKey',
             'RewindCollectValuesForKey', 'RewindDict', 'RewindArray',
             'RewindWatchTabBrowseID', 'RewindUnsigned', 'RewindFormatBitrate',
             'RewindMusicVideoCounterpart', 'RewindMusicVideoCandidates',
             'RewindTimedLyrics', 'RewindPlainLyrics']
    units = ['#import "' + str(ROOT / 'app/rewind_api.h') + '"',
             '#include <stdint.h>', '#include <limits.h>',
             'enum { RewindMaxJSONDepth = 48 };',
             function('rewind_audio_video_id', (ROOT / 'core/rewind_audio.c').read_text())]
    units.extend(function(name) for name in names)
    for name in ['RewindLyricLine', 'RewindLyrics']:
        start = API.index('@implementation ' + name + '\n')
        end = API.index('@end', start) + len('@end')
        units.append(API[start:end])
    units.append((ROOT / 'tests/test_network_parsers.m').read_text())
    path = directory / 'parsers.m'
    path.write_text('\n'.join(units))
    if len(sys.argv) == 3 and sys.argv[1] == '--emit-parsers':
        Path(sys.argv[2]).write_text(path.read_text())
        print('wrote production parser probe:', sys.argv[2])
        return
    if sys.platform != 'darwin':
        print('SKIP production Objective-C parser execution: Apple Foundation host required')
        return
    binary = directory / 'parsers'
    subprocess.run(['clang', '-fno-objc-arc', '-fblocks', '-Wall', '-Wextra',
                    '-framework', 'Foundation', str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(ROOT / 'tests/network_fixtures')], check=True)


with tempfile.TemporaryDirectory(prefix='rewind-network-') as temporary:
    directory = Path(temporary)
    retry_tests(directory)
    parser_tests(directory)
