#!/usr/bin/env python3
"""Bounded HTTP helpers for GitHub automation that calls an external LLM."""

from __future__ import annotations

import json
import re
import time
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener


GITHUB_API_VERSION = "2026-03-10"
MAX_LLM_REQUEST_BYTES = 128_000
MAX_LLM_RESPONSE_BYTES = 64_000
MAX_GITHUB_LIST_PAGES = 20
TRUNCATION_MARKER = "\n[truncated]"

_PRIVATE_KEY_BLOCK_RE = re.compile(
    r"-----BEGIN [^-\r\n]{0,80}PRIVATE KEY-----.*?-----END [^-\r\n]{0,80}PRIVATE KEY-----",
    flags=re.IGNORECASE | re.DOTALL,
)
_CREDENTIAL_URL_RE = re.compile(
    r"(?P<scheme>\b[a-z][a-z0-9+.-]*://)(?P<userinfo>[^/\s?#@]+@)(?P<host>[^/\s?#]+)",
    flags=re.IGNORECASE,
)
_AUTHORIZATION_RE = re.compile(
    r"(?i)(\b(?:proxy-)?authorization\b\s*[:=]\s*)"
    r"(?:\"[^\"\r\n]*\"|'[^'\r\n]*'|[^\s,;}\]]+(?:\s+[^\s,;}\]]+)?)"
)
_SECRET_ASSIGNMENT_RE = re.compile(
    r"(?i)(\b(?:[a-z0-9]+[_-])*"
    r"(?:api[_-]?(?:key|token|secret)|access[_-]?(?:key|token|secret)|"
    r"refresh[_-]?(?:key|token|secret)|auth[_-]?(?:key|token|secret)|"
    r"bearer[_-]?(?:key|token|secret)|session[_-]?(?:key|token|secret)|"
    r"client[_-]?(?:key|token|secret)|private[_-]?(?:key|token|secret)|"
    r"public[_-]?(?:key|token|secret)|signing[_-]?(?:key|token|secret)|"
    r"key|token|secret|password|passwd|credentials?)"
    r"(?:[_-](?:access|id|key|token|secret)){0,2}\b\s*[:=]\s*)"
    r"(?:\"[^\"]*\"|'[^']*'|[^\s,;}\]]+(?:\s+[^\s,;}\]]+)?)"
)
_EMAIL_RE = re.compile(
    r"(?i)(?<![\w.+-])[\w.!#$%&'*+/=?^_`{|}~-]+@(?:[a-z0-9-]+\.)+[a-z]{2,}(?![\w-])"
)
_JWT_RE = re.compile(
    r"(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}(?![A-Za-z0-9_-])"
)
_KNOWN_TOKEN_RE = re.compile(
    r"(?i)(?<![A-Za-z0-9_])(?:"
    r"sk-[A-Za-z0-9]{16,}|rk-[A-Za-z0-9]{16,}|"
    r"gh[pousr]_[A-Za-z0-9_]{16,}|github_pat_[A-Za-z0-9_]{16,}|"
    r"xox[baprs]-[A-Za-z0-9-]{16,}|AIza[A-Za-z0-9_-]{20,}|"
    r"AKIA[A-Z0-9]{16}|glpat-[A-Za-z0-9_-]{16,}|npm_[A-Za-z0-9_-]{16,}|"
    r"pypi-[A-Za-z0-9_-]{16,})(?![A-Za-z0-9_])"
)
_LONG_TOKEN_RE = re.compile(
    r"(?<![A-Za-z0-9])([A-Za-z0-9][A-Za-z0-9_+/=-]{31,})(?![A-Za-z0-9])"
)
_UUID_RE = re.compile(
    r"(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
)


class RequestFailure(RuntimeError):
    def __init__(self, service: str, status: int | None, path: str) -> None:
        self.service = service
        self.status = status
        self.path = path
        detail = f"HTTP {status}" if status is not None else "network error"
        super().__init__(f"{service} request failed with {detail}: {path}")


class RejectAuthenticatedRedirects(HTTPRedirectHandler):
    def redirect_request(
        self,
        req: Request,
        fp: Any,
        code: int,
        msg: str,
        headers: Any,
        newurl: str,
    ) -> None:
        return None


AUTHENTICATED_OPENER = build_opener(RejectAuthenticatedRedirects)


def bounded_text(value: object, limit: int) -> str:
    text = str(value or "")
    if len(text) <= limit:
        return text
    if limit <= len(TRUNCATION_MARKER):
        return TRUNCATION_MARKER[:limit]
    return text[: limit - len(TRUNCATION_MARKER)] + TRUNCATION_MARKER


def _looks_like_long_token(value: str) -> bool:
    if len(value) < 32 or _UUID_RE.fullmatch(value) or re.fullmatch(r"[0-9a-fA-F]{32,}", value):
        return False
    classes = sum(
        bool(re.search(pattern, value))
        for pattern in (r"[a-z]", r"[A-Z]", r"[0-9]", r"[_+/=-]")
    )
    return classes >= 3 or (len(value) >= 40 and classes >= 2)


def redact_text(value: object, limit: int) -> str:
    text = str(value or "")
    text = _PRIVATE_KEY_BLOCK_RE.sub("[REDACTED PRIVATE KEY]", text)
    text = _CREDENTIAL_URL_RE.sub(r"\g<scheme>[REDACTED]@\g<host>", text)
    text = _AUTHORIZATION_RE.sub(r"\1[REDACTED]", text)
    text = _SECRET_ASSIGNMENT_RE.sub(r"\1[REDACTED]", text)
    text = _EMAIL_RE.sub("[REDACTED EMAIL]", text)
    text = _JWT_RE.sub("[REDACTED TOKEN]", text)
    text = _KNOWN_TOKEN_RE.sub("[REDACTED TOKEN]", text)
    text = _LONG_TOKEN_RE.sub(
        lambda match: "[REDACTED TOKEN]" if _looks_like_long_token(match.group(1)) else match.group(1),
        text,
    )
    return bounded_text(text, limit)


def request_json(
    method: str,
    url: str,
    *,
    token: str,
    payload: dict[str, Any] | None = None,
    service: str,
    retry_transient_failures: bool = True,
) -> Any:
    body = None if payload is None else json.dumps(payload).encode("utf-8")
    if service == "LLM API" and body is not None and len(body) > MAX_LLM_REQUEST_BYTES:
        raise RuntimeError("LLM request exceeded the configured input limit")
    headers = {
        "Accept": "application/vnd.github+json" if service == "GitHub" else "text/event-stream",
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
        "User-Agent": "encrypted-memories-automation/1",
    }
    if service == "GitHub":
        headers["X-GitHub-Api-Version"] = GITHUB_API_VERSION

    attempts = 3 if retry_transient_failures else 1
    for attempt in range(attempts):
        try:
            with AUTHENTICATED_OPENER.open(
                Request(url, data=body, headers=headers, method=method),
                timeout=60,
            ) as response:
                raw_bytes = response.read(MAX_LLM_RESPONSE_BYTES + 1) if service == "LLM API" else response.read()
                if service == "LLM API" and len(raw_bytes) > MAX_LLM_RESPONSE_BYTES:
                    raise RuntimeError("LLM API response exceeded the configured output limit")
                raw = raw_bytes.decode("utf-8")
                if service == "LLM API":
                    return raw
                return json.loads(raw) if raw else None
        except HTTPError as error:
            if error.code not in {429, 500, 502, 503, 504} or attempt == attempts - 1:
                raise RequestFailure(service, error.code, urlsplit(url).path) from None
            retry_after = error.headers.get("Retry-After", "")
            delay = int(retry_after) if retry_after.isdigit() else 2**attempt
            time.sleep(min(delay, 10))
        except (URLError, TimeoutError):
            if attempt == attempts - 1:
                raise RequestFailure(service, None, urlsplit(url).path) from None
            time.sleep(2**attempt)

    raise AssertionError("request retry loop ended unexpectedly")


def github_request(
    method: str,
    path: str,
    *,
    token: str,
    api_url: str,
    payload: dict[str, Any] | None = None,
) -> Any:
    return request_json(
        method,
        f"{api_url.rstrip('/')}{path}",
        token=token,
        payload=payload,
        service="GitHub",
        retry_transient_failures=method.upper() != "POST",
    )


def github_paginated_list(
    path: str,
    *,
    token: str,
    api_url: str,
) -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []
    separator = "&" if "?" in path else "?"
    for page in range(1, MAX_GITHUB_LIST_PAGES + 1):
        result = github_request(
            "GET",
            f"{path}{separator}per_page=100&page={page}",
            token=token,
            api_url=api_url,
        )
        if not isinstance(result, list) or any(not isinstance(item, dict) for item in result):
            raise RuntimeError("GitHub returned an invalid paginated list")
        items.extend(result)
        if len(result) < 100:
            return items
    raise RuntimeError("GitHub list exceeded the safe pagination limit")


def streamed_content(raw: str) -> str:
    chunks: list[str] = []
    for line in raw.splitlines():
        if not line.startswith("data: "):
            continue
        data = line[6:].strip()
        if not data or data == "[DONE]":
            continue
        try:
            event = json.loads(data)
        except json.JSONDecodeError:
            continue
        choices = event.get("choices") if isinstance(event, dict) else None
        if not isinstance(choices, list):
            continue
        for choice in choices:
            if not isinstance(choice, dict):
                continue
            delta = choice.get("delta") or {}
            if not isinstance(delta, dict):
                continue
            content = delta.get("content")
            if isinstance(content, str):
                chunks.append(content)
    return "".join(chunks)
