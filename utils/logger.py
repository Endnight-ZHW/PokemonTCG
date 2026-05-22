"""Centralized logging setup."""
import logging
import sys


def setup_logging(level=logging.INFO):
    """Configure the root logger with a console handler."""
    fmt = logging.Formatter(
        '%(asctime)s [%(levelname)s] %(name)s: %(message)s',
        datefmt='%H:%M:%S',
    )
    root = logging.getLogger()
    root.setLevel(level)

    if not root.handlers:
        ch = logging.StreamHandler(sys.stdout)
        ch.setFormatter(fmt)
        root.addHandler(ch)


def get_logger(name: str) -> logging.Logger:
    return logging.getLogger(name)
