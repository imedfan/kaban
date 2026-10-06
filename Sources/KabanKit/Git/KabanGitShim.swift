import Foundation

/// PATH wrapper. It asks `/git/check` and execs git only when the body says `allow: true`.
/// No answer, including a daemon that is not listening, is a denial.
public enum KabanGitShim {
    public static let defaultCheckURL = "http://127.0.0.1:9/git/check"

    public static let script = """
    #!/bin/bash
    # Fail closed. git runs only after the daemon allows this exact argv.
    set -u
    url="${KABAN_GIT_CHECK_URL:-\(defaultCheckURL)}"
    token="${KABAN_RUN_TOKEN:-}"
    gitbin="${KABAN_GIT_BIN:-/usr/bin/git}"
    message="\(GitCheck.deniedMessage)"

    deny() {
      printf '%s\\n' "$message" >&2
      exit 1
    }

    if command -v python3 >/dev/null 2>&1; then
      python3 - "$@" <<'PY'
    import json, os, sys, urllib.request
    url = os.environ.get("KABAN_GIT_CHECK_URL", "\(defaultCheckURL)")
    token = os.environ.get("KABAN_RUN_TOKEN", "")
    gitbin = os.environ.get("KABAN_GIT_BIN", "/usr/bin/git")
    message = "\(GitCheck.deniedMessage)"
    body = json.dumps({"argv": sys.argv[1:], "cwd": os.getcwd()}).encode()
    req = urllib.request.Request(url, data=body, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=2) as resp:
            payload = json.loads(resp.read().decode() or "{}")
    except Exception:
        sys.stderr.write(message + "\\n")
        sys.exit(1)
    if payload.get("allow") is True:
        os.execv(gitbin, [gitbin, *sys.argv[1:]])
    sys.stderr.write(str(payload.get("message") or message) + "\\n")
    sys.exit(1)
    PY
      exit $?
    fi

    rest="${url#http://}"
    hostport="${rest%%/*}"
    path="/${rest#*/}"
    host="${hostport%%:*}"
    port="${hostport##*:}"
    cwd_esc=$(printf '%s' "$PWD" | sed 's/\\\\/\\\\\\\\/g; s/"/\\\\"/g')
    json="{\\"cwd\\":\\"$cwd_esc\\",\\"argv\\":["
    sep=""
    for arg in "$@"; do
      esc=$(printf '%s' "$arg" | sed 's/\\\\/\\\\\\\\/g; s/"/\\\\"/g')
      json="$json$sep\\"$esc\\""
      sep=","
    done
    json="$json]}"
    exec 3<>"/dev/tcp/${host}/${port}" || deny
    printf 'POST %s HTTP/1.1\\r\\nHost: %s\\r\\nAuthorization: Bearer %s\\r\\nContent-Type: application/json\\r\\nContent-Length: %s\\r\\nConnection: close\\r\\n\\r\\n%s' "$path" "$host" "$token" "${#json}" "$json" >&3 || deny
    response=""
    while IFS= read -r -t 2 line <&3; do
      response="${response}${line}"
    done
    exec 3<&-
    case "$response" in
      *'"allow":true'*) exec "$gitbin" "$@" ;;
      *) deny ;;
    esac
    """

    public static func install(at url: URL) throws {
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
