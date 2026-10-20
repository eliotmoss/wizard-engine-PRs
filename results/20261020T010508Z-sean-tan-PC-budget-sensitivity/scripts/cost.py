#!/usr/bin/env python3
"""Time the ordinary budgeted sweeps, one at a time, pinned to one CPU.

usage: cost.py <out-dir> <cpu> <sibling-cpu> <repeats>
Runs budget_study:<case>_b<budget>_s0 for each scenario and budget, repeat by
repeat (every scenario and budget once, then again), so drift spreads over
all cells. Each run's output goes to <out-dir>/<case>_b<budget>_r<rep>.txt.
<out-dir>/cost-runs.csv has one row per run: the sweep's own time (sweepUs,
measured inside the process around the sweep alone), the process's wall time,
user and sys time, peak RSS, and images checked. <out-dir>/machine-*.txt hold
the kernel, governor, EPP, driver and load before and after; cpu-busy.txt the
busy fraction of every CPU over the whole timing window, from /proc/stat.
"""
import csv, os, re, subprocess, sys, time

out_dir, cpu, sib, reps = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
BIN = os.environ.get('STUDY_BIN', os.path.expanduser('~/.cache/budget-study-run/bin/unittest-frozen-v2'))
CASES = os.environ.get('COST_CASES', 'O_SIEVE,O_BTREE_INSERT,O_SPLIT_ALLOC,O_FORMAT_BEFORE').split(',')
BUDGETS = [int(b) for b in os.environ.get('COST_BUDGETS', '1,2,4,8,12,16,32,64').split(',')]
# COST_CELLS=case:budget,... times exactly those cells instead of CASES x BUDGETS.
CELLS = [(c.split(':')[0], int(c.split(':')[1])) for c in os.environ['COST_CELLS'].split(',')] if os.environ.get('COST_CELLS') else [(c, b) for c in CASES for b in BUDGETS]
os.makedirs(out_dir, exist_ok=True)

def sh(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True).stdout

def machine(tag):
    c = '/sys/devices/system/cpu/cpu%d/cpufreq/' % cpu
    text = []
    text.append('date: ' + time.strftime('%Y-%m-%dT%H:%M:%S%z'))
    text.append('uname: ' + sh('uname -a').strip())
    text.append('uptime: ' + sh('uptime').strip())
    for f in ['scaling_driver', 'scaling_governor', 'energy_performance_preference', 'scaling_min_freq', 'scaling_max_freq']:
        text.append('cpu%d %s: %s' % (cpu, f, sh('cat %s%s 2>&1' % (c, f)).strip()))
    text.append('governors (all cpus): ' + ' '.join(sh('sort /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor | uniq -c').split()))
    text.append('no_turbo: ' + sh('cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>&1').strip())
    text.append('thread_siblings_list cpu%d: %s' % (cpu, sh('cat /sys/devices/system/cpu/cpu%d/topology/thread_siblings_list' % cpu).strip()))
    text.append('top processes by cpu:\n' + sh('ps -eo pid,psr,pcpu,etime,comm --sort=-pcpu | head -12'))
    open(os.path.join(out_dir, 'machine-%s.txt' % tag), 'w').write('\n'.join(text) + '\n')

def stat():
    v = {}
    for line in open('/proc/stat'):
        m = re.match(r'cpu(\d*) (.*)', line)
        if m:
            f = [int(x) for x in m.group(2).split()]
            idle = f[3] + f[4]
            v[m.group(1) or 'all'] = (sum(f[:8]), idle)
    return v

machine('before')
s0 = stat()
t_begin = time.time()
rows = []
for rep in range(1, reps + 1):
    for case, b in CELLS:
        if True:
            name = '%s_b%d_s0' % (case, b)
            path = os.path.join(out_dir, '%s_b%d_r%d.txt' % (case, b, rep))
            with open(path, 'w') as out:
                out.write('CPU %d\n' % cpu)
                out.flush()
                t0 = time.monotonic()
                p = subprocess.Popen(['taskset', '-c', str(cpu), BIN, 'budget_study:' + name], stdout=out, stderr=subprocess.STDOUT)
                _, status, ru = os.wait4(p.pid, 0)
                wall = time.monotonic() - t0
            text = open(path).read()
            m = re.search(r'^ROW (.*)$', text, re.M)
            kv = dict(x.split('=', 1) for x in m.group(1).split()) if m else {}
            rows.append(dict(case=case, budget=b, rep=rep, status=status, ok=int(text.rstrip().endswith('##-ok')),
                             caught=kv.get('caught', ''), imagesChecked=kv.get('imagesChecked', ''),
                             cuts=kv.get('cuts', ''), truncatedCuts=kv.get('truncatedCuts', ''),
                             sweepUs=kv.get('sweepUs', ''), totalUs=kv.get('totalUs', ''),
                             processWallS='%.4f' % wall, userS='%.3f' % ru.ru_utime, sysS='%.3f' % ru.ru_stime,
                             maxrssKB=ru.ru_maxrss, start=time.strftime('%H:%M:%S', time.localtime(time.time() - wall))))
            print('%s rep=%d status=%d sweepUs=%s images=%s wall=%.3f' % (name, rep, status, kv.get('sweepUs'), kv.get('imagesChecked'), wall), flush=True)
s1 = stat()
t_end = time.time()
machine('after')
with open(os.path.join(out_dir, 'cost-runs.csv'), 'w', newline='') as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
    w.writeheader()
    for r in rows:
        w.writerow(r)
with open(os.path.join(out_dir, 'cpu-busy.txt'), 'w') as f:
    f.write('timing window %s to %s (%.1f s)\n' % (time.strftime('%H:%M:%S', time.localtime(t_begin)),
                                                  time.strftime('%H:%M:%S', time.localtime(t_end)), t_end - t_begin))
    for k in sorted(s0, key=lambda k: (-1 if k == 'all' else int(k))):
        tot = s1[k][0] - s0[k][0]
        idle = s1[k][1] - s0[k][1]
        f.write('cpu%s busy=%.2f%%\n' % (k, 100.0 * (tot - idle) / tot if tot else 0.0))
