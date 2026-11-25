#!/usr/bin/env python3
"""Independent check of dist/aarch64: splits each .apk into its gzip streams,
verifies signatures with openssl, datahash, per-file SHA1s and the index C: field."""
import base64, hashlib, io, os, subprocess, sys, tarfile, tempfile, zlib
d = sys.argv[1] if len(sys.argv) > 1 else "docs/aarch64"
pub = sys.argv[2] if len(sys.argv) > 2 else "docs/keys/dakota-mods.rsa.pub"
def streams(b):
    out, pos = [], 0
    while pos < len(b):
        z = zlib.decompressobj(16 + zlib.MAX_WBITS); data = z.decompress(b[pos:]); data += z.flush()
        used = len(b) - pos - len(z.unused_data); out.append((b[pos:pos+used], data)); pos += used
    return out
def tar_members(raw):
    t = tarfile.open(fileobj=io.BytesIO(raw + b"\0"*10240), mode="r:")
    return [(m, t.extractfile(m).read() if m.isfile() else None) for m in t]
def verify(sigraw, signed_gz):
    (m, s), = tar_members(sigraw)
    assert m.name == ".SIGN.RSA.dakota-mods.rsa.pub", m.name
    with tempfile.NamedTemporaryFile() as sf, tempfile.NamedTemporaryFile() as df:
        sf.write(s); sf.flush(); df.write(signed_gz); df.flush()
        r = subprocess.run(["openssl","dgst","-sha1","-verify",pub,"-signature",sf.name,df.name],capture_output=True,text=True)
        assert r.stdout.strip() == "Verified OK", r.stdout + r.stderr
idx = open(os.path.join(d,"APKINDEX.tar.gz"),"rb").read()
(sg, sr), (ug, ur) = streams(idx); verify(sr, ug)
index = dict(tar_members(ur).__iter__().__next__() and [(m.name, x) for m, x in tar_members(ur)])["APKINDEX"].decode()
entries = {}
for block in index.strip().split("\n\n"):
    f = dict(l.split(":",1) for l in block.splitlines()); entries[f"{f['P']}-{f['V']}.apk"] = f
for fn in sorted(x for x in os.listdir(d) if x.endswith(".apk")):
    b = open(os.path.join(d,fn),"rb").read(); st = streams(b); assert len(st)==3, len(st)
    (_, sr), (cg, cr), (dg, dr) = st; verify(sr, cg)
    ctrl = {m.name: x for m, x in tar_members(cr)}; pk = ctrl[".PKGINFO"].decode()
    assert f"datahash = {hashlib.sha256(dg).hexdigest()}" in pk
    n = 0
    for m, x in tar_members(dr):
        if m.isfile():
            assert m.pax_headers["APK-TOOLS.checksum.SHA1"] == hashlib.sha1(x).hexdigest(); n += 1
    e = entries[fn]; assert e["C"] == "Q1"+base64.b64encode(hashlib.sha1(cg).digest()).decode(); assert int(e["S"]) == len(b)
    for s in [k for k in ctrl if k != ".PKGINFO"]:
        r = subprocess.run(["sh","-n"],input=ctrl[s],capture_output=True); assert r.returncode==0, (fn,s,r.stderr)
    print(f"OK {fn}: sig, datahash, {n} file sums, index entry, scripts {sorted(k for k in ctrl if k!='.PKGINFO')}")
print("APKINDEX signature OK;", len(entries), "entries")
