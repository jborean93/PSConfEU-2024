#!/usr/bin/env python
# PYTHON_ARGCOMPLETE_OK

# Copyright: (c) 2024 Jordan Borean (@jborean93) <jborean93@gmail.com>
# MIT License (see LICENSE or https://opensource.org/licenses/MIT)

from __future__ import annotations

import argparse
import logging
import os
import pathlib
import sys
import typing

from ._server import OutOfProcTransport, PipeConnection, StdioConnection, get_pipe_name

HAS_ARGCOMPLETE = True
try:
    import argcomplete
except ImportError:
    HAS_ARGCOMPLETE = False

DEFAULT_FORMAT = (
    "%(asctime)s | %(levelname)s | %(name)s:%(lineno)s | %(funcName)s() %(message)s"
)


def configure_file_logging(
    file: str,
    level: str,
    format: str | None = None,
) -> None:
    log_level = {
        "info": logging.INFO,
        "debug": logging.DEBUG,
        "warning": logging.WARNING,
        "error": logging.ERROR,
    }[level]

    fh = logging.FileHandler(file, mode="a", encoding="utf-8")
    fh.setLevel(log_level)
    fh.setFormatter(logging.Formatter(format or DEFAULT_FORMAT))

    ansibug_logger = logging.getLogger("psrp_server")
    ansibug_logger.setLevel(log_level)
    ansibug_logger.addHandler(fh)


def parse_args() -> argparse.Namespace:
    """Parse and return args."""
    parser = argparse.ArgumentParser(description="Starts a Python PSRP Server.")

    parser.add_argument(
        "--pipe",
        dest="pipe",
        action="store_true",
        help="Use named pipe for communications rather than stdin/stdout, requires psutil to be installed or --pipe-name to be used to specify the pipe name to listen on.",
    )

    parser.add_argument(
        "--pipe-name",
        dest="pipe_name",
        action="store",
        help="Use a custom pipe name to listen on when --pipe is set, defaults to how PowerShell sets up their process pipe name.",
    )

    parser.add_argument(
        "--log-file",
        action="store",
        type=lambda v: pathlib.Path(os.path.expanduser(os.path.expandvars(v))),
        help="Enable file logging to the file at this path.",
    )

    parser.add_argument(
        "--log-level",
        action="store",
        choices=["info", "debug", "warning", "error"],
        default="info",
        type=str,
        help="Set the logging filter level of the logger when --log-file is set. Defaults to info",
    )

    if HAS_ARGCOMPLETE:
        argcomplete.autocomplete(parser)

    return parser.parse_args()


def main(args: list[str]) -> None:
    args = parse_args()

    if args.log_file:
        configure_file_logging(
            str(typing.cast(pathlib.Path, args.log_file).absolute()),
            args.log_level,
        )

    conn: StdioConnection | PipeConnection
    if args.pipe:
        pipe_name = args.pipe_name or get_pipe_name()
        print(f"Starting Python PSRP Server [PID {os.getpid()} - Pipe {pipe_name}]")
        conn = PipeConnection(pipe_name)

    else:
        conn = StdioConnection()

    transport = OutOfProcTransport(conn)
    transport.run()


if __name__ == "__main__":
    main(sys.argv[1:])
