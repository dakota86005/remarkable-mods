# Builds a fake tablet for testing: a Vellum root with a mock `vellum`, an "official" index made from
# the public vellum package recipes (if available), and Dakota's real repo index. Usage: mkenv.py <dir> [velbuild_dir]
import os, sys, io, re, tarfile, gzip, shutil, glob
root = os.path.abspath(sys.argv[1]); vb = sys.argv[2] if len(sys.argv) > 2 else None
here = os.path.dirname(os.path.abspath(__file__)); repo = os.path.abspath(os.path.join(here, '..', '..', '..'))
shutil.rmtree(root, ignore_errors=True)
V = os.path.join(root, 'vroot'); W = os.path.join(root, 'www')
for d in ['bin', 'etc/apk/keys', 'etc/apk/cache', 'lib/apk/db', 'local-repo/aarch64']: os.makedirs(os.path.join(V, d), exist_ok=True)
os.makedirs(os.path.join(W, 'official/aarch64')); os.makedirs(os.path.join(W, 'dakota/aarch64'))
def tgz(entries):
    b = io.BytesIO()
    with tarfile.open(fileobj=b, mode='w') as t:
        for n, data in entries:
            ti = tarfile.TarInfo(n); ti.size = len(data); t.addfile(ti, io.BytesIO(data))
    return gzip.compress(b.getvalue())
off = []
if vb:
    for f in sorted(glob.glob(os.path.join(vb, '*/VELBUILD'))):
        s = open(f).read(); g = lambda k: (re.search(r'^%s="?([^"\n]*)"?' % k, s, re.M) or [None, ''])[1]
        name, ver, rel = g('pkgname'), g('pkgver'), g('pkgrel') or '0'
        if not name: continue
        off.append('P:%s\nV:%s-r%s\nA:aarch64\nT:%s\nU:%s\nD:%s\n' % (name, ver, rel, g('pkgdesc'), g('url'), g('depends')))
    # an older build of one package, as the real index keeps several
    off.append('P:bettertoc\nV:1.4.0-r0\nA:aarch64\nT:Older toc\nU:x\nD:qt-resource-rebuilder remarkable-os>=3.24 remarkable-os<3.26\n')
open(os.path.join(W, 'official/aarch64/APKINDEX.tar.gz'), 'wb').write(tgz([('DESCRIPTION', b'vellum'), ('APKINDEX', '\n'.join(off).encode())]))
shutil.copy(os.path.join(repo, 'docs/aarch64/APKINDEX.tar.gz'), os.path.join(W, 'dakota/aarch64/APKINDEX.tar.gz'))
port = os.environ.get('MU_PORT', '8765')
open(os.path.join(V, 'etc/apk/repositories'), 'w').write(
    '%s/local-repo\nhttp://127.0.0.1:%s/official\n@dakota http://127.0.0.1:%s/dakota' % (V, port, port))  # no final newline, like vellum
inst = [('remarkable-os', '3.29.1.0-r0', 'virtual', ''), ('rmpp', '1.0-r0', 'virtual', ''),
        ('qt-resource-rebuilder', '0.0.6-r0', 'qmldiff loader', 'https://github.com/asivery'),
        ('appload', '0.5.0-r1', 'XOVI extension for windowed and fullscreen apps', 'https://github.com/asivery/rm-appload'),
        ('bettertoc', '1.5.3-r1', 'Adds the ability to add, delete, and edit Table of Contents entries.', 'https://github.com/rmitchellscott/xovi-bettertoc'),
        ('nave', '3.0.0-r0', 'Two-column home screen for My files', 'https://github.com/dakota86005/remarkable-mods'),
        ('field-weather', '4.0.0-r0', 'Current weather in the home screen header', 'https://github.com/dakota86005/remarkable-mods'),
        ('note-links', '2.0.0-r0', 'Links between notebook pages', 'https://github.com/dakota86005/remarkable-mods'),
        ('sudoku', '1.0.1-r0', 'Sudoku for AppLoad', 'https://github.com/dakota86005/remarkable-mods')]
open(os.path.join(V, 'lib/apk/db/installed'), 'w').write(''.join('C:Q1x=\nP:%s\nV:%s\nA:aarch64\nT:%s\nU:%s\n\n' % i for i in inst))
open(os.path.join(V, 'etc/apk/world'), 'w').write('appload\nbettertoc\nnave@dakota\nfield-weather@dakota\nnote-links@dakota\nsudoku@dakota\nremarkable-os=3.29.1.0-r0\nrmpp\n')
mock = r'''#!/bin/sh
# mock vellum: prints apk-like output and edits the installed db
V=__V__
DB=$V/lib/apk/db/installed; WORLD=$V/etc/apk/world
cmd=$1; shift
setver() { awk -v P="$1" -v NV="$2" '$0=="P:"P{f=1} f&&/^V:/{$0="V:"NV;f=0} {print}' $DB > $DB.t && mv $DB.t $DB; }
case $cmd in
update) sleep 1; echo "fetch http://127.0.0.1/official/aarch64/APKINDEX.tar.gz"; echo "fetch http://127.0.0.1/dakota/aarch64/APKINDEX.tar.gz"; echo "OK: 214 distinct packages available" ;;
add) i=0; for p in "$@"; do i=$((i+1)); n=${p%@*}; echo "($i/$#) Installing $n (1.0.0-r0)"; sleep 1
     printf 'C:Q1x=\nP:%s\nV:1.0.0-r0\nA:aarch64\nT:installed by mock\nU:\n\n' "$n" >> $DB; echo "$p" >> $WORLD; done
     case "$*" in *@dakota*) echo t > ${MU_RESTART_FLAG:-/tmp/.dakota-mods-restart};; esac; echo "OK: 3 MiB in 40 packages" ;;
del|purge) for p in "$@"; do echo "(1/1) Purging $p (x)"; awk -v P="$p" 'BEGIN{RS="";ORS="\n\n"} $0 !~ "\nP:"P"\n" && $0 !~ "^P:"P"\n" && index($0,"P:"P"\n")==0 {print}' $DB > $DB.t && mv $DB.t $DB
     grep -v "^$p\(@.*\)\?$" $WORLD > $WORLD.t; mv $WORLD.t $WORLD; done; echo "OK" ;;
upgrade) [ "$1" = -y ] && shift; echo "Upgrading:"; echo "  nave 3.0.0-r0 -> 3.1.0-r0"; echo "  sudoku 1.0.1-r0 -> 1.0.2-r0"; echo; echo "(1/2) Upgrading nave (3.0.0-r0 -> 3.1.0-r0)"; sleep 2
     echo "(2/2) Upgrading sudoku (1.0.1-r0 -> 1.0.2-r0)"; sleep 1; setver nave 3.1.0-r0; setver sudoku 1.0.2-r0; setver appload 0.6.0-r2
     echo t > ${MU_RESTART_FLAG:-/tmp/.dakota-mods-restart}; echo "OK: 3 MiB in 40 packages" ;;
*) echo "mock: $cmd"; exit 1 ;;
esac
'''
open(os.path.join(V, 'bin/vellum'), 'w').write(mock.replace('__V__', V)); os.chmod(os.path.join(V, 'bin/vellum'), 0o755)
print(V, W)
