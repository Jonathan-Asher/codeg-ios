"""Revoke development certificates that a CI signing run created by itself.

Automatic signing on a fresh runner mints an "Apple Development: Created via
API" certificate whenever it finds no usable identity in the keychain, and the
account stops accepting new ones after a handful. CI signs with one long-lived
certificate (KEEP_CERT_ID); every other API-created development certificate is
an orphan whose private key died with its runner, so it is revoked here.
Certificates made from Xcode on a Mac carry the developer's name and are never
touched.

Environment: ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID, KEEP_CERT_ID.
"""

import json
import os
import sys
import time
import urllib.request

import jwt

API = "https://api.appstoreconnect.apple.com"
STRAY_NAME = "Apple Development: Created via API"


def token() -> str:
    with open(os.environ["ASC_KEY_PATH"]) as f:
        key = f.read()
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"},
        key,
        algorithm="ES256",
        headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"},
    )


def request(method: str, path: str) -> tuple[int, dict]:
    req = urllib.request.Request(API + path, method=method, headers={"Authorization": "Bearer " + token()})
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            body = resp.read()
            return resp.status, json.loads(body) if body else {}
    except urllib.error.HTTPError as err:
        return err.code, {}


def main() -> int:
    keep = os.environ["KEEP_CERT_ID"]
    status, body = request("GET", "/v1/certificates?limit=200&fields[certificates]=certificateType,name")
    if status != 200:
        print(f"::warning::could not list certificates (HTTP {status})")
        return 0
    stray = [
        c["id"]
        for c in body.get("data", [])
        if c["attributes"]["certificateType"] == "DEVELOPMENT"
        and c["attributes"]["name"] == STRAY_NAME
        and c["id"] != keep
    ]
    if not any(c["id"] == keep for c in body.get("data", [])):
        print(f"::warning::the CI signing certificate {keep} is no longer on the account")
    for cert_id in stray:
        status, _ = request("DELETE", f"/v1/certificates/{cert_id}")
        print(f"::warning::revoked stray development certificate {cert_id} (HTTP {status})")
    if not stray:
        print("no stray development certificates")
    return 0


if __name__ == "__main__":
    sys.exit(main())
