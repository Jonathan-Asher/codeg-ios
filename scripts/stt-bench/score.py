"""WER / CER of stt-cli output against reference transcripts.

usage: OUT=out python3 score.py TAG:SET[:AGAINST] ...

Reads OUT/TAG/SET/<id>.txt. References: fleurs/test.tsv (FLEURS he_il,
https://huggingface.co/datasets/google/fleurs, CC-BY-4.0) or SET.tsv with
"<id>\t<text>" lines. With AGAINST, the reference is another run's output
(e.g. q8_0:fleurs:f16 counts how many words q8_0 changed). Hebrew niqqud,
punctuation and hyphens are normalized away first.
"""
import os
ROOT = os.environ.get("OUT", "out")
import csv, re, sys, unicodedata, pathlib, json
def norm(s):
    s = unicodedata.normalize("NFKC", s)
    s = re.sub(r"[֑-ׇ]", "", s)          # niqqud / cantillation
    s = s.replace("-", "").replace("־", "")    # hyphen, maqaf: join prefix + word
    s = re.sub(r"[^\w\s]", " ", s)
    return " ".join(s.lower().split())
def lev(a, b):
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i]
        for j, y in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j-1] + 1, prev[j-1] + (x != y)))
        prev = cur
    return prev[-1]
def refs(set_):
    if set_ == "fleurs":
        out = {}
        for row in csv.reader(open("fleurs/test.tsv"), delimiter="\t"):
            out[row[1].removesuffix(".wav")] = row[2]
        return out
    name = f"{set_}.tsv"
    return dict(l.rstrip("\n").split("\t", 1) for l in open(name))
def score(tag, set_, against=None):
    R = refs(set_) if against is None else {p.stem: p.read_text() for p in pathlib.Path(f"{ROOT}/{against}/{set_}").glob("*.txt")}
    we = wn = ce = cn = 0; n = 0
    for p in sorted(pathlib.Path(f"{ROOT}/{tag}/{set_}").glob("*.txt")):
        if p.stem not in R: continue
        r, h = norm(R[p.stem]), norm(p.read_text())
        we += lev(r.split(), h.split()); wn += len(r.split())
        ce += lev(r.replace(" ", ""), h.replace(" ", "")); cn += len(r.replace(" ", ""))
        n += 1
    return n, 100 * we / max(wn, 1), 100 * ce / max(cn, 1)
if __name__ == "__main__":
    for spec in sys.argv[1:]:
        tag, set_, *ag = spec.split(":")
        n, w, c = score(tag, set_, ag[0] if ag else None)
        print(f"{tag:14s} {set_:8s} {'vs ' + ag[0] if ag else 'vs ref':10s} n={n:2d}  WER {w:5.1f}%  CER {c:5.1f}%")
