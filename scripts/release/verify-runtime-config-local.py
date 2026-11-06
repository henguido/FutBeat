"""Offline Gradle validation only: no build, signing, provider or device calls."""
import argparse
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import time


def artifact_snapshot(android):
    output = android.parent / 'build/app/outputs'
    return {str(path.relative_to(output)): [path.stat().st_size, path.stat().st_mtime_ns]
            for pattern in ('*.apk', '*.aab') for path in output.rglob(pattern)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--java', help='Existing JDK executable; never downloads a JDK')
    parser.add_argument('--case', action='append', choices=['unsafe', 'safe', 'empty-api', 'credential-api', 'release-graph', 'secret-token', 'privileged-jwt', 'anon-keys', 'unsafe-auth-origin', 'auth-path', 'safe-auth-origin', 'preview-key', 'preview-flags', 'user-session-safe', 'user-session-fixed-token', 'user-session-wrong-origin', 'user-session-missing-key'])
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    java = args.java
    if not java:
        java_home = os.environ.get('JAVA_HOME')
        java = str(Path(java_home) / 'bin' / ('java.exe' if os.name == 'nt' else 'java')) if java_home else shutil.which('java')
    if not java or not Path(java).is_file():
        parser.error('Existing JDK required: pass --java or JAVA_HOME')
    android = root / 'apps/mobile/android'
    wrapper = android / 'gradle/wrapper/gradle-wrapper.jar'
    output = root / 'artifacts/mobile250/runtime-config'
    output.mkdir(parents=True, exist_ok=True)
    qa_messages = [flag + ' is QA-only' for flag in ['FUTBEAT_USE_DEMO', 'FUTBEAT_QA_LOCAL_CACHE_ONLY', 'FUTBEAT_QA_DIAGNOSTICS']]
    url_message = 'non-loopback HTTPS'
    def fixture_jwt(role):
        payload = base64.urlsafe_b64encode(json.dumps({'role': role}).encode()).decode().rstrip('=')
        return 'fixture-header.' + payload + '.fixture-signature'

    token_error = 'must be a publishable or legacy anon key'
    cases = [
        ('unsafe', ['FUTBEAT_USE_DEMO=true', 'FUTBEAT_QA_LOCAL_CACHE_ONLY=true', 'FUTBEAT_QA_DIAGNOSTICS=true', 'FUTBEAT_API_URL=http://127.0.0.1:9'], ['validateReleaseRuntimeConfig'], qa_messages + [url_message]),
        ('safe', ['FUTBEAT_USE_DEMO=false', 'FUTBEAT_QA_LOCAL_CACHE_ONLY=false', 'FUTBEAT_QA_DIAGNOSTICS=false', 'FUTBEAT_API_URL=https://api.example.test/v1'], ['validateReleaseRuntimeConfig'], []),
        ('empty-api', ['FUTBEAT_API_URL='], ['validateReleaseRuntimeConfig'], [url_message]),
        ('unsafe-auth-origin', ['FUTBEAT_SUPABASE_URL=http://127.0.0.1:9'], ['validateReleaseRuntimeConfig'], ['FUTBEAT_SUPABASE_URL must be a non-loopback HTTPS origin']),
        ('auth-path', ['FUTBEAT_SUPABASE_URL=https://auth.example.test/not-an-origin'], ['validateReleaseRuntimeConfig'], ['FUTBEAT_SUPABASE_URL must be a non-loopback HTTPS origin']),
        ('safe-auth-origin', ['FUTBEAT_SUPABASE_URL=https://auth.example.test/'], ['validateReleaseRuntimeConfig'], []),
        ('credential-api', ['FUTBEAT_API_URL=https://fixture:synthetic@api.example.test/v1'], ['validateReleaseRuntimeConfig'], [url_message]),
        # Strict dry-run: validates the real release graph, never its actions.
        ('release-graph', ['FUTBEAT_USE_DEMO=true', 'FUTBEAT_ADS_DISABLED=true'], [':app:bundleRelease', '--dry-run'], ['Release runtime configuration:', 'FUTBEAT_USE_DEMO is QA-only']),
    ]
    cases.extend([
        ('secret-token', ['FUTBEAT_API_PUBLIC_TOKEN=sb_secret_fixture_only', 'FUTBEAT_SUPABASE_PUBLISHABLE_KEY=sb_secret_fixture_alias'], ['validateReleaseRuntimeConfig'], ['FUTBEAT_API_PUBLIC_TOKEN ' + token_error, 'FUTBEAT_SUPABASE_PUBLISHABLE_KEY ' + token_error]),
        ('privileged-jwt', ['FUTBEAT_API_PUBLIC_TOKEN=' + fixture_jwt('service_role'), 'FUTBEAT_SUPABASE_PUBLISHABLE_KEY=' + fixture_jwt('authenticated')], ['validateReleaseRuntimeConfig'], ['FUTBEAT_API_PUBLIC_TOKEN ' + token_error, 'FUTBEAT_SUPABASE_PUBLISHABLE_KEY ' + token_error]),
        ('preview-key', ['FUTBEAT_PASSIVE_CLIENT_KEY=fixture-preview-read-key'], ['validateReleaseRuntimeConfig'], ['Preview client keys are not allowed in the official release']),
        ('preview-flags', ['FUTBEAT_PASSIVE_PREVIEW=true', 'FUTBEAT_PASSIVE_PREVIEW_ENABLED=true', 'FUTBEAT_OFFLINE_PREVIEW=true'], ['validateReleaseRuntimeConfig'], ['FUTBEAT_PASSIVE_PREVIEW is QA-only', 'FUTBEAT_PASSIVE_PREVIEW_ENABLED is QA-only', 'FUTBEAT_OFFLINE_PREVIEW is QA-only']),
        ('anon-keys', ['FUTBEAT_API_PUBLIC_TOKEN=' + fixture_jwt('anon'), 'FUTBEAT_SUPABASE_PUBLISHABLE_KEY=sb_publishable_fixture_only'], ['validateReleaseRuntimeConfig'], []),
    ])
    public = ['FUTBEAT_USER_SESSION_ACCESS=true', 'FUTBEAT_SUPABASE_URL=https://auth.example.test', 'FUTBEAT_SUPABASE_PUBLISHABLE_KEY=sb_publishable_fixture', 'FUTBEAT_API_URL=https://auth.example.test/functions/v1/futbeat-api']
    cases.extend([
        ('user-session-safe', public, ['validateReleaseRuntimeConfig'], []),
        ('user-session-fixed-token', public + ['FUTBEAT_API_PUBLIC_TOKEN=sb_publishable_fixture'], ['validateReleaseRuntimeConfig'], ['User-session access must not contain a fixed API token']),
        ('user-session-wrong-origin', public + ['FUTBEAT_API_URL=https://other.example.test/functions/v1/futbeat-api'], ['validateReleaseRuntimeConfig'], ['User-session API must match its Auth project and central endpoint']),
        ('user-session-missing-key', public + ['FUTBEAT_SUPABASE_PUBLISHABLE_KEY='], ['validateReleaseRuntimeConfig'], ['User-session access requires an explicit publishable key']),
    ])
    if args.case:
        cases = [case for case in cases if case[0] in args.case]
    before = artifact_snapshot(android)
    results = []
    for name, defines, tasks, messages in cases:
        encoded = ','.join(base64.b64encode(value.encode()).decode() for value in defines)
        command = [java, '-classpath', str(wrapper), 'org.gradle.wrapper.GradleWrapperMain', '--offline', '--no-daemon'] + tasks + ['-Pdart-defines=' + encoded]
        started = time.monotonic()
        try:
            result = subprocess.run(command, cwd=android, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding='utf8', errors='replace', timeout=180)
            log = result.stdout
            passed = (result.returncode == 0 and 'Release runtime configuration OK' in log and 'BUILD SUCCESSFUL' in log) if not messages else (result.returncode != 0 and 'BUILD FAILED' in log and all(message in log for message in messages))
            if name in {'secret-token', 'privileged-jwt', 'preview-key'}:
                # Synthetic values only. Even rejected credentials must never
                # be echoed by the validation error.
                passed = passed and all(value.split('=', 1)[1] not in log for value in defines)
            entry = {'case': name, 'exit': result.returncode, 'pass': passed}
        except subprocess.TimeoutExpired:
            log = 'Validation timed out; no PASS inferred. Inspect owned Gradle invocation before repeating.'
            entry = {'case': name, 'exit': None, 'pass': False, 'status': 'BLOCKED_TIMEOUT'}
        entry.update(seconds=round(time.monotonic() - started, 2), artifact_tasks_executed=False, strict_dry_run=(name == 'release-graph'))
        (output / (name + '.log')).write_text(log, encoding='utf8')
        results.append(entry)
        (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n', encoding='utf8')
        print(json.dumps(entry), flush=True)
        if entry.get('status') == 'BLOCKED_TIMEOUT':
            break
    after = artifact_snapshot(android)
    unchanged = before == after
    (output / 'artifact-observation.json').write_text(json.dumps({'before': before, 'after': after, 'unchanged': unchanged}, indent=2) + '\n', encoding='utf8')
    return 0 if unchanged and len(results) == len(cases) and all(item['pass'] for item in results) else 1


if __name__ == '__main__':
    raise SystemExit(main())
