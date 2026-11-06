#!/usr/bin/env python3
"""Build/verify Hosting with the registered production App Check site key.
Only reads Firebase configuration. Never deploys or writes Firestore.
"""
import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
PROJECT = 'jm-quick'
APP = '1:576531288403:web:b127cb70ae0f34a77811a6'


def registered_site_key():
    projects = json.loads((ROOT / '.firebaserc').read_text())
    if projects['projects']['default'] != PROJECT:
        raise RuntimeError('Unexpected Firebase project; build stopped')
    modules = subprocess.check_output(['npm', 'root', '-g'], text=True).strip()
    # Keep OAuth tokens in the child process; only return the public site key config.
    script = r'''
(async () => {
  const root = process.argv[1];
  const auth = require(root + '/firebase-tools/lib/auth');
  const api = require(root + '/firebase-tools/lib/api');
  const account = auth.getGlobalDefaultAccount();
  if (!account) throw Error('Firebase CLI login required');
  const token = await auth.getAccessToken(account.tokens.refresh_token, api.getScopes());
  const response = await fetch(process.argv[2], {headers: {Authorization: 'Bearer ' + token.access_token}});
  if (!response.ok) throw Error('App Check configuration read failed: HTTP ' + response.status);
  const config = await response.json();
  process.stdout.write(JSON.stringify({siteKey: config.siteKey}));
})().catch(e => {console.error(e.message); process.exitCode = 1;});
'''
    url = f'https://firebaseappcheck.googleapis.com/v1/projects/576531288403/apps/{APP}/recaptchaEnterpriseConfig'
    result = subprocess.run(['node', '-e', script, modules, url], text=True, capture_output=True, check=True)
    key = json.loads(result.stdout).get('siteKey', '')
    if not re.fullmatch(r'[A-Za-z0-9_-]{20,200}', key):
        raise RuntimeError('Registered App Check site key missing or invalid')
    return key


def verify_artifact(directory, key):
    if not key:
        raise RuntimeError('App Check site key required')
    js = (directory / 'main.dart.js').read_bytes()
    if key.encode() not in js:
        raise RuntimeError('Hosting artifact lacks the registered App Check site key; rebuild with scripts/build_web_release.py')
    return hashlib.sha256(js).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--verify-only', action='store_true')
    args = parser.parse_args()
    key = registered_site_key()
    output = ROOT / 'build/web'
    lock = (ROOT / 'pubspec.lock').read_bytes()
    if not args.verify_only:
        result = subprocess.run(['flutter', 'build', 'web', '--release', '--no-pub', '--no-web-resources-cdn',
                                 '--dart-define=APP_CHECK_RECAPTCHA_ENTERPRISE_SITE_KEY=' + key],
                                cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        print(result.stdout.replace(key, '[REDACTED_SITE_KEY]'), end='')
        if result.returncode:
            raise RuntimeError(f'Flutter build failed (exit {result.returncode})')
    if (ROOT / 'pubspec.lock').read_bytes() != lock:
        raise RuntimeError('pubspec.lock changed; release stopped')
    print('PASS: registered production App Check key included; main.dart.js SHA256=' + verify_artifact(output, key))


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError, OSError, ValueError) as error:
        print('Release verification failed: ' + str(error), file=sys.stderr)
        sys.exit(1)
