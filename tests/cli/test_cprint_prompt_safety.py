"""Regression tests for prompt-safe CLI printing.

These tests guard against input-line corruption in prompt_toolkit sessions by
ensuring _cprint routes through StdoutProxy when patch_stdout is active.
"""

from __future__ import annotations

import io
from unittest.mock import patch

import cli


class _DummyStdoutProxy:
    def __init__(self) -> None:
        self.writes: list[str] = []
        self.flush_calls = 0

    def write(self, text: str) -> int:
        self.writes.append(text)
        return len(text)

    def flush(self) -> None:
        self.flush_calls += 1


def test_cprint_uses_stdout_proxy_when_prompt_active(monkeypatch):
    """When patch_stdout is active, _cprint should write via sys.stdout.

    This preserves the current input line and cursor position while typing.
    """
    import prompt_toolkit.patch_stdout as pt_patch_stdout

    monkeypatch.setattr(pt_patch_stdout, "StdoutProxy", _DummyStdoutProxy, raising=False)
    proxy = _DummyStdoutProxy()
    monkeypatch.setattr(cli.sys, "stdout", proxy)

    with patch.object(cli, "_pt_print") as mock_pt_print:
        cli._cprint("\x1b[31mhello\x1b[0m")

    assert "".join(proxy.writes) == "hello\n"
    assert proxy.flush_calls == 1
    mock_pt_print.assert_not_called()


def test_cprint_falls_back_to_plain_text_if_formatter_fails(monkeypatch):
    """Formatter failures should still produce visible text output."""
    sink = io.StringIO()
    monkeypatch.setattr(cli.sys, "stdout", sink)

    with patch.object(cli, "_pt_print", side_effect=RuntimeError("boom")):
        cli._cprint("\x1b[33mwarning\x1b[0m")

    assert sink.getvalue() == "warning\n"
