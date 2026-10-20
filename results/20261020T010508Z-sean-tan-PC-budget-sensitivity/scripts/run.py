#!/usr/bin/env python3
"""Run budget-study unit tests, one per CPU slot, pinned with taskset.

Adapted from the 2026-10-19 selection study's runner.
usage: run.py <tasks-file> <out-dir> <cpu,cpu,...>
Each task is a test name without the 'budget_study:' prefix. Its output goes
to <out-dir>/<task>.txt, whose first line is the CPU it ran on; a task whose
output already ends in ##-ok is skipped. <out-dir>/runner.log records start,
end, CPU, exit status and the process's wall time per task.
"""
import os, subprocess, sys, time

tasks_file, out_dir, cpus = sys.argv[1], sys.argv[2], [int(c) for c in sys.argv[3].split(',')]
BIN = os.environ.get('STUDY_BIN', os.path.expanduser('~/.cache/budget-study-run/bin/unittest-frozen-v2'))
os.makedirs(out_dir, exist_ok=True)
tasks = [l.strip() for l in open(tasks_file) if l.strip() and not l.startswith('#')]

def done(name):
    p = os.path.join(out_dir, name + '.txt')
    if not os.path.exists(p):
        return False
    with open(p) as f:
        return f.read().rstrip().endswith('##-ok')

queue = [t for t in tasks if not done(t)]
free = list(cpus)
running = {}
log = open(os.path.join(out_dir, 'runner.log'), 'a')
log.write('BEGIN %s tasks=%d todo=%d cpus=%s bin=%s\n' % (time.strftime('%Y-%m-%dT%H:%M:%S'), len(tasks), len(queue), sys.argv[3], BIN))
log.flush()
while queue or running:
    while queue and free:
        name = queue.pop(0)
        cpu = free.pop(0)
        out = open(os.path.join(out_dir, name + '.txt'), 'w')
        out.write('CPU %d\n' % cpu)
        out.flush()
        p = subprocess.Popen(['taskset', '-c', str(cpu), BIN, 'budget_study:' + name],
                             stdout=out, stderr=subprocess.STDOUT)
        running[p.pid] = (p, name, cpu, time.monotonic(), out)
        log.write('START %s cpu=%d %s\n' % (name, cpu, time.strftime('%H:%M:%S')))
        log.flush()
    pid, status, ru = os.wait4(-1, 0)
    if pid in running:
        p, name, cpu, t0, out = running.pop(pid)
        out.close()
        free.append(cpu)
        log.write('END %s cpu=%d status=%d wall=%.3fs user=%.3fs sys=%.3fs maxrss_kb=%d %s\n' % (
            name, cpu, status, time.monotonic() - t0, ru.ru_utime, ru.ru_stime, ru.ru_maxrss,
            time.strftime('%H:%M:%S')))
        log.flush()
log.write('ALLDONE %s\n' % time.strftime('%Y-%m-%dT%H:%M:%S'))
log.flush()
