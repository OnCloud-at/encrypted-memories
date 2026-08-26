#!/bin/zsh
set -euo pipefail

if [[ $# -lt 5 || $# -gt 7 ]]; then
  echo "Usage: rollback-ml-model-release.sh SOURCE_PAIR NEW_SEQUENCE PRIVATE_KEY REPOSITORY_REVISION RELEASED_AT [RCLONE_REMOTE] [BUCKET]" >&2
  exit 64
fi

source_pair=$1
new_sequence=$2
private_key=$3
repository_revision=$4
released_at=$5
remote_name=${6:-r2}
bucket=${7:-encrypted-memories-models}
public_key_base64='qXMyoYhp7TbPPXPAyEKDoy+kkl8He7I5RNXWgjNc5Kk='

[[ ${#source_pair} == 64 && "$source_pair" != *[^0-9a-f]* ]] || {
  echo "SOURCE_PAIR must be 64 lowercase hexadecimal characters" >&2
  exit 64
}
[[ "$new_sequence" == <1-> ]] || { echo "NEW_SEQUENCE must be a positive integer" >&2; exit 64; }
[[ -f "$private_key" ]] || { echo "PRIVATE_KEY does not exist" >&2; exit 66; }
command -v rclone >/dev/null || { echo "rclone is required" >&2; exit 69; }
command -v python3 >/dev/null || { echo "python3 is required for signed R2 requests" >&2; exit 69; }
[[ -n "${R2_ENDPOINT:-}" ]] || { echo "R2_ENDPOINT is required" >&2; exit 64; }
[[ -n "${R2_ACCESS_KEY_ID:-}" ]] || { echo "R2_ACCESS_KEY_ID is required" >&2; exit 64; }
[[ -n "${R2_SECRET_ACCESS_KEY:-}" ]] || { echo "R2_SECRET_ACCESS_KEY is required" >&2; exit 64; }
[[ "${RCLONE_CONFIG_R2_ENDPOINT:-}" == "$R2_ENDPOINT" ]] || {
  echo "The rclone endpoint must match R2_ENDPOINT" >&2
  exit 64
}
[[ "${RCLONE_CONFIG_R2_ACCESS_KEY_ID:-}" == "$R2_ACCESS_KEY_ID" ]] || {
  echo "The rclone access key must match the signed-request configuration" >&2
  exit 64
}
[[ "${RCLONE_CONFIG_R2_SECRET_ACCESS_KEY:-}" == "$R2_SECRET_ACCESS_KEY" ]] || {
  echo "The rclone secret key must match the signed-request configuration" >&2
  exit 64
}
python3 -c '
import sys
from urllib.parse import urlsplit

endpoint = urlsplit(sys.argv[1].rstrip("/"))
if (
    endpoint.scheme != "https"
    or not endpoint.hostname
    or endpoint.username
    or endpoint.password
    or endpoint.query
    or endpoint.fragment
):
    raise SystemExit("R2_ENDPOINT must be an HTTPS URL")
' "$R2_ENDPOINT"

script_dir=${0:A:h}
rollback_tmp=$(mktemp -d)
trap 'rm -rf "$rollback_tmp"' EXIT
historical="$rollback_tmp/historical"
prepared=${ROLLBACK_OUTPUT_DIR:-$rollback_tmp/prepared}
mkdir -p "$historical" "$prepared"
remote="${remote_name}:${bucket}"
history="catalog-history/${source_pair}"

for name in catalog-v1.json catalog-v1.sig catalog-v2.json catalog-v2.sig release-pair.json; do
  rclone copyto "$remote/$history/$name" "$historical/$name"
done
python3 "$script_dir/verify-ml-release-pair.py" "$historical" --expected-pair "$source_pair"
xcrun swift "$script_dir/verify-ml-catalog-signature.swift" \
  "$historical/catalog-v1.json" "$historical/catalog-v1.sig" "$public_key_base64"
xcrun swift "$script_dir/verify-ml-catalog-signature.swift" \
  "$historical/catalog-v2.json" "$historical/catalog-v2.sig" "$public_key_base64"

xcrun swift "$script_dir/prepare-ml-model-rollback.swift" \
  --catalog-v1 "$historical/catalog-v1.json" \
  --catalog-v2 "$historical/catalog-v2.json" \
  --private-key "$private_key" \
  --output "$prepared" \
  --catalog-sequence "$new_sequence" \
  --repository-revision "$repository_revision" \
  --released-at "$released_at" \
  --source-pair "$source_pair"

new_pair=$(tr -d '\r\n' < "$prepared/release-pair.sha256")
python3 "$script_dir/verify-ml-release-pair.py" "$prepared" --expected-pair "$new_pair"
xcrun swift "$script_dir/verify-ml-catalog-signature.swift" \
  --pointer "$prepared/active-pair.json" "$public_key_base64"
xcrun swift "$script_dir/verify-ml-catalog-signature.swift" \
  "$prepared/catalog-v1.json" "$prepared/catalog-v1.sig" "$public_key_base64"
xcrun swift "$script_dir/verify-ml-catalog-signature.swift" \
  "$prepared/catalog-v2.json" "$prepared/catalog-v2.sig" "$public_key_base64"

r2_request() {
  local method=$1 key=$2 file=${3:-} immutable=${4:-0} maximum_bytes=${5:-0}
  python3 - "$method" "$bucket" "$key" "$file" "$immutable" "$maximum_bytes" <<'PY'
import datetime
import hashlib
import hmac
import mimetypes
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

method, bucket, key, file_path, immutable, maximum_bytes = sys.argv[1:]
maximum_bytes = int(maximum_bytes)
endpoint = os.environ["R2_ENDPOINT"].rstrip("/")
access_key = os.environ["R2_ACCESS_KEY_ID"]
secret_key = os.environ["R2_SECRET_ACCESS_KEY"]
parsed_endpoint = urllib.parse.urlsplit(endpoint)
if (
    parsed_endpoint.scheme != "https"
    or not parsed_endpoint.hostname
    or parsed_endpoint.username
    or parsed_endpoint.password
    or parsed_endpoint.query
    or parsed_endpoint.fragment
):
    raise SystemExit("R2_ENDPOINT must be an HTTPS URL")
encoded_bucket = urllib.parse.quote(bucket, safe="-_.~")
encoded_key = urllib.parse.quote(key, safe="/-_.~")
canonical_uri = (parsed_endpoint.path.rstrip("/") + "/" + encoded_bucket + "/" + encoded_key) or "/"
url = urllib.parse.urlunsplit((parsed_endpoint.scheme, parsed_endpoint.netloc, canonical_uri, "", ""))
def file_hash(path):
    digest = hashlib.sha256()
    with open(path, "rb") as source:
        for chunk in iter(lambda: source.read(4 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()
def file_chunks(path):
    with open(path, "rb") as source:
        for chunk in iter(lambda: source.read(4 * 1024 * 1024), b""):
            yield chunk
payload_hash = file_hash(file_path) if method == "PUT" else hashlib.sha256(b"").hexdigest()
now = datetime.datetime.now(datetime.timezone.utc)
amz_date = now.strftime("%Y%m%dT%H%M%SZ")
date = now.strftime("%Y%m%d")
headers = {
    "host": parsed_endpoint.netloc,
    "x-amz-content-sha256": payload_hash,
    "x-amz-date": amz_date,
}
if method == "PUT":
    headers["content-length"] = str(os.path.getsize(file_path))
    headers["content-type"] = mimetypes.guess_type(file_path)[0] or "application/octet-stream"
    headers["cache-control"] = "public, max-age=31536000, immutable" if immutable == "1" else "no-cache, max-age=0, must-revalidate"
    if immutable == "1":
        headers["if-none-match"] = "*"
canonical_headers = "".join(f"{name}:{headers[name].strip()}\n" for name in sorted(headers))
signed_headers = ";".join(sorted(headers))
scope = f"{date}/auto/s3/aws4_request"
canonical_request = f"{method}\n{canonical_uri}\n\n{canonical_headers}\n{signed_headers}\n{payload_hash}"
request_hash = hashlib.sha256(canonical_request.encode()).hexdigest()
string_to_sign = f"AWS4-HMAC-SHA256\n{amz_date}\n{scope}\n{request_hash}"
def sign(key_bytes, value):
    return hmac.new(key_bytes, value.encode(), hashlib.sha256).digest()
date_key = sign(("AWS4" + secret_key).encode(), date)
region_key = sign(date_key, "auto")
service_key = sign(region_key, "s3")
signing_key = sign(service_key, "aws4_request")
signature = hmac.new(signing_key, string_to_sign.encode(), hashlib.sha256).hexdigest()
headers["authorization"] = (
    "AWS4-HMAC-SHA256 Credential=" + access_key + "/" + scope
    + ", SignedHeaders=" + signed_headers + ", Signature=" + signature
)
request = urllib.request.Request(
    url,
    data=file_chunks(file_path) if method == "PUT" else None,
    method=method,
    headers=headers,
)
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, msg, headers, newurl):
        return None
opener = urllib.request.build_opener(NoRedirect)
try:
    with opener.open(request, timeout=60) as response:
        if method == "GET":
            written = 0
            try:
                with open(file_path, "wb") as output:
                    for chunk in iter(lambda: response.read(4 * 1024 * 1024), b""):
                        written += len(chunk)
                        if maximum_bytes > 0 and written > maximum_bytes:
                            raise RuntimeError("R2 response exceeds the expected object size")
                        output.write(chunk)
            except Exception:
                if os.path.exists(file_path):
                    os.remove(file_path)
                raise
except urllib.error.HTTPError as error:
    sys.stderr.write(f"R2 {method} {key} returned HTTP {error.code}\n")
    raise SystemExit(42 if error.code == 412 and immutable == "1" else 1)
PY
}

artifact_rows="$rollback_tmp/rollback-artifacts.tsv"
python3 "$script_dir/verify-ml-release-pair.py" \
  --artifact-list "$historical/catalog-v2.json" \
  > "$artifact_rows"

artifact_verify="$rollback_tmp/rollback-artifact"
while IFS=$'\t' read -r key expected_hash expected_bytes; do
  r2_request GET "$key" "$artifact_verify" 0 "$expected_bytes"
  actual_hash=$(shasum -a 256 "$artifact_verify" | awk '{print $1}')
  actual_bytes=$(stat -f %z "$artifact_verify")
  [[ "$actual_hash" == "$expected_hash" && "$actual_bytes" == "$expected_bytes" ]] || {
    echo "Rollback artifact is unavailable or corrupt: $key" >&2
    exit 1
  }
  rm -f -- "$artifact_verify"
done < "$artifact_rows"

upload_immutable() {
  local source=$1 key=$2 expected_hash expected_bytes verify actual_hash actual_bytes
  expected_hash=$(shasum -a 256 "$source" | awk '{print $1}')
  expected_bytes=$(stat -f %z "$source")
  verify="$rollback_tmp/verify-$expected_hash-$RANDOM"
  if r2_request PUT "$key" "$source" 1; then
    :
  elif [[ $? == 42 ]]; then
    echo "Conditional PutObject found existing $key; verifying its bytes" >&2
    r2_request GET "$key" "$verify" 0 "$expected_bytes" || {
      echo "Immutable object is unavailable: $key" >&2
      exit 1
    }
  else
    echo "Conditional PutObject failed for $key" >&2
    exit 1
  fi
  if [[ ! -f "$verify" ]]; then
    r2_request GET "$key" "$verify" 0 "$expected_bytes"
  fi
  actual_hash=$(shasum -a 256 "$verify" | awk '{print $1}')
  actual_bytes=$(stat -f %z "$verify")
  [[ "$actual_hash" == "$expected_hash" && "$actual_bytes" == "$expected_bytes" ]] || {
    echo "Immutable object mismatch: $key" >&2
    exit 1
  }
}

publish_mutable_verified() {
  local source=$1 key=$2 expected_hash expected_bytes verify actual_hash actual_bytes
  expected_hash=$(shasum -a 256 "$source" | awk '{print $1}')
  expected_bytes=$(stat -f %z "$source")
  verify="$rollback_tmp/mutable-$expected_hash"
  r2_request PUT "$key" "$source" 0
  r2_request GET "$key" "$verify" 0 "$expected_bytes"
  actual_hash=$(shasum -a 256 "$verify" | awk '{print $1}')
  actual_bytes=$(stat -f %z "$verify")
  [[ "$actual_hash" == "$expected_hash" && "$actual_bytes" == "$expected_bytes" ]] || {
    echo "Mutable catalog object mismatch: $key" >&2
    exit 1
  }
  rm -f -- "$verify"
}

for name in catalog-v1.sig catalog-v1.json catalog-v2.sig catalog-v2.json release-pair.json; do
  upload_immutable "$prepared/$name" "catalog-history/$new_pair/$name"
done
upload_immutable "$prepared/release-pair.json" "model-releases/$new_pair/release-pair.json"

publish_mutable_verified "$prepared/catalog-v1.sig" catalog-v1.sig
publish_mutable_verified "$prepared/catalog-v1.json" catalog-v1.json
publish_mutable_verified "$prepared/catalog-v2.sig" catalog-v2.sig
publish_mutable_verified "$prepared/catalog-v2.json" catalog-v2.json
publish_mutable_verified "$prepared/active-pair.json" active-pair.json

echo "Published rollback pair $new_pair at sequence $new_sequence from $source_pair"
print -r -- "$new_pair" > "$rollback_tmp/new-pair.sha256"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "pair_id=$new_pair" >> "$GITHUB_OUTPUT"
fi
