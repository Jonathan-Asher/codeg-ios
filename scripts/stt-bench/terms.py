"""Code-term recall: did the English/code terms in mixed Hebrew dictation survive?

usage: OUT=out python3 terms.py TAG ...

Two measures per term, over the mixed clips of the carmit and blue sets:
- written: the term appears in Latin letters (case, spaces and punctuation
  ignored; "Docker file" counts for Dockerfile, "read me" for README);
- recognizable: written, or close in Latin letters ("session continue" for
  session-continue.ts, "comit"), or a Hebrew spelling a reader (or an agent)
  would still recognize (ריבייס for rebase, דוקר פייל for Dockerfile).
The Hebrew patterns are phonetic and the same for every model.
"""
import os, re, sys, unicodedata, pathlib

ROOT = os.environ.get("OUT", "out")
S = r"\s?"
TERMS = {
    "carmit": {
        "c01": [("README", rf"רי{S}ד{S}מי"), ("main", r"מיין|מין"), ("CI", rf"סי{S}אי")],
        "c02": [("API", rf"אי?{S}פי{S}אי|אפי"), ("login", r"לו?א?גין"), ("endpoint", rf"אנד{S}פוינט")],
        "c03": [("pull request", rf"פול{S}רי?קו?ו?ס"), ("Dockerfile", rf"דו?קר{S}פי?יל")],
        "c04": [("rebase", r"ריבי?יס|ריבייז"), ("main", r"מיין|מין"), ("cargo test", rf"קא?רגו{S}טסט")],
        "c05": [("ComposeBar", rf"קומפו?וז{S}בא?ר")],
        "c06": [("build", r"בילד"), ("GitHub Actions", rf"גיטה?א?ב{S}אקש[יי]*נ[סז]")],
        "c07": [("JSON", r"ג[׳']?ייסון|גייסון|גסון"), ("YAML", r"יאמל|ימל")],
        "c08": [("commit", r"קו?מיט|כמית")],
        "c10": [("WebSocket", rf"ו?ובסוקט|וב{S}סוקט|ובסוקט")],
        "c11": [("TypeScript", rf"טייפ{S}סקריפט"), ("JavaScript", rf"ג[׳']?א?ווה{S}סקריפט|גאווה{S}סקריפט")],
        "c12": [("linter", r"לינטר"), ("merge", r"מרג|מרג[׳']")],
    },
    "blue": {
        "b01": [("session-continue.ts", rf"סשן{S}קונטיניו"), ("push", r"פוש"), ("feat/quick-ask", rf"קוויק{S}אסק")],
        "b02": [("pnpm test", rf"פי{S}אן{S}פי{S}אם"), ("ChatInput.test.tsx", rf"צ[׳']?אט{S}אינפוט"),
                ("mock", r"מוק"), ("useSessionStore", rf"סשן{S}סטור"), ("state", r"סטייט")],
        "b03": [("Dockerfile", rf"דו?קר{S}פי?יל"), ("buildx", rf"בילד{S}אקס"), ("linux/amd64", r"לינוקס"),
                ("registry", r"רגיסטרי|רג[׳']יסטרי")],
        "b04": [("parseAgentEvent", rf"פרס{S}אייג[׳']?נט"), ("null", r"נאל|נול"), ("WebSocket", rf"ו?וב{S}סוקט"),
                ("commit", r"קו?מיט|כמית")],
        "b05": [("Pull Request", rf"פול{S}רי?קו?ו?ס"), ("README", rf"רי{S}ד{S}מי"), ("CHANGELOG", rf"צ?[׳']?יינג[׳']?{S}לוג|שנגלוג|חנגלוג"),
                ("CI", rf"סי{S}אי"), ("merge", r"מרג")],
        "b10": [("voice input", rf"וויס{S}אינפוט"), ("Whisper", r"ו?ויספר"), ("AudioContext", rf"אודיו{S}קונטקסט"),
                ("listener", r"ליסנר"), ("visibilitychange", rf"ויזיביליטי"), ("voice-recorder.test.ts", rf"וויס{S}רקורדר"),
                ("feat/voice-input", rf"פיט{S}סלאש"), ("Pull Request", rf"פול{S}רי?קו?ו?ס")],
    },
}

def norm(s):
    s = unicodedata.normalize("NFKC", s).lower()
    s = re.sub(r"[֑-ׇ]", "", s)
    s = s.replace("״", "").replace('"', "").replace("׳", "").replace("'", "").replace("־", " ")
    return " ".join(re.sub(r"[^\w]+", " ", s).split())

def latin_tokens(s):
    return re.findall(r"[a-z0-9]+", unicodedata.normalize("NFKC", s).lower())

def written(term, hyp):
    want = "".join(latin_tokens(term))
    toks = latin_tokens(hyp)
    for i in range(len(toks)):
        joined = ""
        for j in range(i, len(toks)):
            joined += toks[j]
            if joined == want: return True
            if len(joined) >= len(want): break
    return False

def lev(a, b):
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i]
        for j, y in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x != y)))
        prev = cur
    return prev[-1]

def latin_close(term, hyp):
    """Every word of the term (camelCase split, 3+ letters) is in the
    hypothesis in Latin letters, allowing one wrong letter in words of 5+."""
    words = [w.lower() for w in re.findall(r"[A-Z]?[a-z]+|[A-Z]+(?![a-z])|\d+", term) if len(w) >= 3]
    toks = latin_tokens(hyp)
    if not words: return False
    return all(any(t == w or (len(w) >= 5 and lev(t, w) <= 1) for t in toks) for w in words)

def score(tag):
    w = r = n = 0
    misses = []
    for set_, clips in TERMS.items():
        for cid, terms in clips.items():
            p = pathlib.Path(f"{ROOT}/{tag}/{set_}/{cid}.txt")
            if not p.exists(): continue
            hyp = p.read_text()
            h = norm(hyp)
            for term, pattern in terms:
                n += 1
                ok_w = written(term, hyp)
                ok_r = ok_w or latin_close(term, hyp) or re.search(pattern, h) is not None
                w += ok_w; r += ok_r
                if not ok_r: misses.append(term)
    return n, w, r, misses

if __name__ == "__main__":
    for tag in sys.argv[1:]:
        n, w, r, misses = score(tag)
        if n == 0: print(f"{tag:22s} no output"); continue
        print(f"{tag:22s} terms={n:2d}  written {100*w/n:5.1f}%  recognizable {100*r/n:5.1f}%")
