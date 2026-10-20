#!/usr/bin/env python3
"""Build the summary tables from catch.csv (and cost-runs.csv if given).

usage: tables.py <catch.csv> [<cost-runs.csv>[,<cost-runs.csv>...] <cost.csv>]
Catch cell: where salt 0 checked no random-stage image the selection is fixed
and the cell is salt 0's outcome ("cut N" or "passes"); otherwise it is
"k/10" seeds caught, with the cuts they caught at (salt 0's first).
"""
import csv, os, statistics, sys
from collections import defaultdict

rows = list(csv.DictReader(open(sys.argv[1])))
by = defaultdict(list)
for r in rows:
    by[(r['case'], int(r['budget']))].append(r)
MUT = ['M1_CONTROL_ELIDED', 'M2_CHECKSUM_SKIP', 'M3_BTREE_ELIDED', 'M4_EARLY_MAGIC',
       'M5_APPLY_BEFORE_COMMIT', 'M6_UNLOGGED_LINK_STORE']
MAIN = [1, 2, 4, 8, 12, 16, 32, 64]
EXTRA = [3, 6, 10, 13, 14, 15]

def cell(case, b):
    rs = sorted(by.get((case, b), []), key=lambda r: int(r['salt']))
    if not rs:
        return 'not run'
    s0 = rs[0]
    assert s0['salt'] == '0'
    if any(r['status'] != 'ok' for r in rs):
        return 'TEST-FAILED'
    if int(s0['randomImages']) == 0:
        assert len(rs) == 1, (case, b)
        return ('cut %s' % s0['cut']) if s0['caught'] == '1' else 'passes'
    k = sum(1 for r in rs if r['caught'] == '1')
    cuts = []
    for r in rs:
        if r['caught'] == '1' and r['cut'] not in cuts:
            cuts.append(r['cut'])
    s = '%d/%d' % (k, len(rs))
    if cuts:
        s += ' (cut %s)' % ','.join(cuts)
    return s

def table(cases, budgets):
    out = ['| bug | ' + ' | '.join(str(b) for b in budgets) + ' |',
           '|---|' + '---|' * len(budgets)]
    for c in cases:
        out.append('| %s | ' % c + ' | '.join(cell(c, b) for b in budgets) + ' |')
    return '\n'.join(out)

print('## catch, main budgets\n')
print(table(MUT, MAIN))
print('\n## catch, extra budgets\n')
print(table(MUT, EXTRA))
print('\n## ordinary sweeps (false-positive check)\n')
print('| sweep | runs | catches | budgets | salts run per budget |')
print('|---|---|---|---|---|')
for c in sorted(set(r['case'] for r in rows if r['kind'] == 'ordinary')):
    rs = [r for r in rows if r['case'] == c]
    bud = sorted(set(int(r['budget']) for r in rs))
    salts = ' '.join('%d:%d' % (b, len(by[(c, b)])) for b in bud)
    bad = sum(1 for r in rs if r['caught'] == '1' or r['status'] != 'ok')
    print('| %s | %d | %d | %s | %s |' % (c, len(rs), bad, ','.join(map(str, bud)), salts))

if len(sys.argv) > 3:
    cost = []
    for i, path in enumerate(sys.argv[2].split(',')):
        for r in csv.DictReader(open(path)):
            r['set'] = os.path.basename(os.path.dirname(os.path.abspath(path)))
            cost.append(r)
    g = defaultdict(list)
    for r in cost:
        g[(r['case'], int(r['budget']), r['set'])].append(r)
    cases = ['O_SIEVE', 'O_BTREE_INSERT', 'O_SPLIT_ALLOC', 'O_FORMAT_BEFORE']
    with open(sys.argv[3], 'w', newline='') as f:
        w = csv.writer(f)
        w.writerow(['scenario', 'budget', 'timing_set', 'repeats', 'all_passed', 'images_checked', 'cuts',
                    'truncated_cuts', 'sweep_s_median', 'sweep_s_min', 'sweep_s_max', 'process_wall_s_median'])
        for key in sorted(g, key=lambda k: (cases.index(k[0]), k[1], k[2])):
            rs = g[key]
            imgs = set(r['imagesChecked'] for r in rs)
            assert len(imgs) == 1, (key, imgs)
            ok = all(r['ok'] == '1' and r['caught'] == '0' and r['status'] == '0' for r in rs)
            sw = [int(r['sweepUs']) / 1e6 for r in rs]
            pw = [float(r['processWallS']) for r in rs]
            w.writerow([key[0], key[1], key[2], len(rs), int(ok), rs[0]['imagesChecked'], rs[0]['cuts'],
                        rs[0]['truncatedCuts'], '%.4f' % statistics.median(sw), '%.4f' % min(sw),
                        '%.4f' % max(sw), '%.4f' % statistics.median(pw)])
    print('\n## cost (median of 3 repeats, sweep only; images checked; main timing set)\n')
    print('| scenario | ' + ' | '.join(str(b) for b in MAIN) + ' |')
    print('|---|' + '---|' * len(MAIN))
    for c in cases:
        cells = []
        for b in MAIN:
            rs = g[(c, b, 'cost')]
            ok = all(r['ok'] == '1' and r['caught'] == '0' and r['status'] == '0' for r in rs)
            sw = statistics.median([int(r['sweepUs']) / 1e6 for r in rs])
            cells.append('%.3f s, %s%s' % (sw, format(int(rs[0]['imagesChecked']), ','), '' if ok else ' FAILED'))
        print('| %s | ' % c + ' | '.join(cells) + ' |')
