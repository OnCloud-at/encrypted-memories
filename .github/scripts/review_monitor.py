"""Observe a slow provider without exposing response content or retrying blocked reads."""

import threading
import time
from collections.abc import Callable
from typing import Any


class ReviewTimeout(RuntimeError):
    """No complete review is available within the configured waiting policy."""


class ReviewMonitor:
    def __init__(self, deadline: float, idle_seconds: float = 600, interval: float = 60) -> None:
        self.deadline = deadline
        self.idle_seconds = idle_seconds
        self.interval = interval
        self.started = time.monotonic()
        self.transport = self.progress = self.started
        self.kind = "no model output yet"
        self.lock = threading.Lock()
        self.cancelled = threading.Event()

    def activity(self, kind: str) -> None:
        if self.cancelled.is_set():
            raise ReviewTimeout("Review monitoring stopped.")
        with self.lock:
            now = time.monotonic()
            self.transport = now
            if kind in {"reasoning", "content"}:
                self.progress = now
                self.kind = kind

    def status(self, now: float) -> tuple[str, str | None]:
        with self.lock:
            wire_idle, output_idle = now - self.transport, now - self.progress
            status = (
                f"LLM review: {int(now - self.started)}s elapsed; "
                f"network idle {int(wire_idle)}s; model output idle {int(output_idle)}s; {self.kind}."
            )
        reason = None
        if now >= self.deadline:
            reason = "Review time limit reached."
        elif output_idle >= self.idle_seconds:
            reason = "No observable model output within the waiting limit; computation status is unknown."
        return status, reason

    def run(self, operation: Callable[[], Any]) -> Any:
        done = threading.Event()
        result: list[Any] = []
        errors: list[BaseException] = []

        def work() -> None:
            try:
                result.append(operation())
            except BaseException as error:
                errors.append(error)
            finally:
                done.set()

        # Only provider HTTP runs here, never GitHub writes. A blocked buffered read cannot
        # safely resume after a socket timeout. The CLI exits after a watchdog timeout;
        # the daemon cannot prevent exit or later publish a partial/stale result.
        threading.Thread(target=work, daemon=True, name="review-provider").start()
        next_log = self.started + self.interval
        while True:
            completed = done.wait(min(1.0, self.interval))
            now = time.monotonic()
            status, reason = self.status(now)
            if reason:
                self.cancelled.set()
                raise ReviewTimeout(reason)
            if completed:
                if errors:
                    raise errors[0]
                return result[0]
            if now >= next_log:
                print(status, flush=True)
                next_log = now + self.interval
