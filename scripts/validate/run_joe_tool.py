#!/usr/bin/env python3
"""Run any registered joe-task tool (winPEAS, SharpUp, ...) as User_Joe.

Replaces the per-tool wrappers `run_winpeas_as_joe.py` and
`run_sharpup_as_joe.py`. The tool name maps to a `ToolSpec` in
`joe_tool_specs.SPECS`; the rest of the argument surface is built by
`joe_task_runner.build_common_parser(spec)`.

CLI:
    python3 scripts/validate/run_joe_tool.py <tool> [--target ...] [...]
"""
from __future__ import annotations

import sys

from joe_task_runner import build_common_parser, run_as_joe
from joe_tool_specs import lookup


def main() -> int:
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        print("usage: run_joe_tool.py <tool> [tool-args...]", file=sys.stderr)
        print("  tool: winpeas | sharpup", file=sys.stderr)
        return 2

    tool = sys.argv.pop(1)
    spec = lookup(tool)
    parser = build_common_parser(spec)
    args = parser.parse_args()
    return run_as_joe(spec, args)


if __name__ == "__main__":
    sys.exit(main())
