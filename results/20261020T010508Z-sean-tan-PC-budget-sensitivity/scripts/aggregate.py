#!/usr/bin/env python3
"""Aggregate budget-study ROW/DETAIL/NOTE lines.

usage: aggregate.py <matrix-dir> <catch.csv> <cells.txt>
Writes one CSV row per run (case, budget, salt), every column taken from the
run's output file, and a per-(case, budget) summary: salt 0's outcome and,
where salts 1-9 were run, how many of the ten seeds caught and at which cuts.
"""
import csv, glob, os, re, sys

d, csv_path, cells_path = sys.argv[1], sys.argv[2], sys.argv[3]
rows = []
for path in sorted(glob.glob(os.path.join(d, '*.txt'))):
    name = os.path.basename(path)
    if name == 'runner.log':
        continue
    text = open(path).read()
    cpu = re.match(r'CPU (\d+)', text)
    complete = text.rstrip().endswith('##-ok')
    row = None
    detail = note = cover = trace = ''
    for line in text.splitlines():
        if line.startswith('ROW '):
            row = dict(x.split('=', 1) for x in line.split()[1:])
        elif line.startswith('TRACE '):
            trace = dict(x.split('=', 1) for x in line.split()[1:])
        elif line.startswith('DETAIL '):
            detail = line.split(' ', 4)[4]
        elif line.startswith('NOTE '):
            note = line.split(' ', 4)[4]
        elif line.startswith('COVER '):
            cover = line.split(' ', 4)[4]
    if row is None:
        rows.append(dict(case=name[:-4], status='NO-ROW', file=name, complete=complete))
        continue
    row.update(trace_name=trace.get('name', ''), digest=trace.get('digest', ''), detail=detail,
               selection_note=note, coverage=cover, cpu=cpu.group(1) if cpu else '',
               complete=complete, file=name, status='ok' if complete else 'TEST-FAILED')
    rows.append(row)

cols = ['case', 'kind', 'budget', 'salt', 'caught', 'cut', 'events', 'failIndex', 'failImages',
        'failDistinct', 'failExtremes', 'failFrom', 'imagesChecked', 'cuts', 'truncatedCuts',
        'randomCuts', 'randomImages', 'maxExtremes', 'sweepUs', 'totalUs', 'detail', 'selection_note',
        'coverage', 'trace_name', 'digest', 'cpu', 'status', 'file']
rows.sort(key=lambda r: (r.get('case', ''), int(r.get('budget', 0) or 0), int(r.get('salt', 0) or 0)))
with open(csv_path, 'w', newline='') as f:
    w = csv.DictWriter(f, fieldnames=cols, extrasaction='ignore')
    w.writeheader()
    for r in rows:
        w.writerow(r)

cells = {}
for r in rows:
    if r.get('status') == 'NO-ROW':
        continue
    cells.setdefault((r['case'], int(r['budget'])), []).append(r)
out = []
for (case, b) in sorted(cells):
    rs = sorted(cells[(case, b)], key=lambda r: int(r['salt']))
    s0 = [r for r in rs if r['salt'] == '0']
    s0 = s0[0] if s0 else None
    caught = [r for r in rs if r['caught'] == '1']
    cuts = sorted(set(int(r['cut']) for r in caught))
    seeded = int(s0['randomImages']) > 0 if s0 else False
    bad = [r for r in rs if r['status'] != 'ok']
    out.append('%-24s b=%-3d salt0: %s cut=%s checked=%s fail=%s/%s(%s) randomImages=%s | salts=%d caught=%d/%d cuts=%s%s' % (
        case, b, 'CAUGHT' if s0 and s0['caught'] == '1' else 'passes', s0['cut'] if s0 else '?',
        s0['imagesChecked'] if s0 else '?', s0['failIndex'] if s0 else '?', s0['failImages'] if s0 else '?',
        s0['failFrom'] if s0 else '?', s0['randomImages'] if s0 else '?', len(rs), len(caught), len(rs),
        ','.join(map(str, cuts)) or '-', ' STATUS-PROBLEM' if bad else ''))
open(cells_path, 'w').write('\n'.join(out) + '\n')
print('\n'.join(out))
