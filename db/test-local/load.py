"""Muat schema deklaratif satu project ke DB uji: stub Supabase, lalu file schemas/** dengan retry sampai urutan dependensi
ketemu (meniru pg-delta yang mengurutkan otomatis). Untuk mesin tanpa Docker; dengan Supabase CLI pakai `supabase test db`. Usage: python3 load.py <identity|core> <dbname> [file_tambahan.sql ...]"""
import glob, os, subprocess, sys

proj, db, extra = sys.argv[1], sys.argv[2], sys.argv[3:]
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, '..', proj, 'supabase')
PSQL = ['psql', '-h', '127.0.0.1', '-U', 'postgres', '-X', '-q', '-v', 'ON_ERROR_STOP=1']


def run(sql_file=None, sql=None, dbname=db, single=True):
    cmd = PSQL + ['-d', dbname] + (['-1'] if single else []) + (['-f', sql_file] if sql_file else ['-c', sql])
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.returncode, (r.stderr or r.stdout).strip()


run(sql=f'drop database if exists {db} with (force)', dbname='postgres', single=False)
rc, err = run(sql=f'create database {db}', dbname='postgres', single=False)
assert rc == 0, err
rc, err = run(os.path.join(HERE, 'stub_supabase.sql'))
assert rc == 0, err
run(sql=f'alter database {db} set search_path = "$user", public, extensions', dbname='postgres', single=False)

pending = sorted(glob.glob(os.path.join(ROOT, 'schemas', '**', '*.sql'), recursive=True))
errors, rounds = {}, 0
while pending:
    rounds += 1
    left = []
    for f in pending:
        rc, err = run(f)
        if rc:
            left.append(f)
            errors[f] = err
    if len(left) == len(pending):
        break
    pending = left
loaded = len(glob.glob(os.path.join(ROOT, 'schemas', '**', '*.sql'), recursive=True)) - len(pending)
print(f'{proj}: {loaded} file schema dimuat dalam {rounds} putaran; gagal {len(pending)}')
for f in pending:
    print('GAGAL', os.path.relpath(f, ROOT), '→', errors[f].splitlines()[0][:300])
for f in extra:
    rc, err = run(f)
    print(('OK   ' if rc == 0 else 'GAGAL'), os.path.relpath(f, HERE), '' if rc == 0 else '→ ' + err.splitlines()[0][:300])
    if rc:
        pending.append(f)
sys.exit(1 if pending else 0)
