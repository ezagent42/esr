"""Fixture — adversarial 3-statement logger-only stub (reviewer C-P2)."""
import logging


async def run() -> None:
    logger = logging.getLogger("x")
    logger.info("this is a stub disguised as real work")
    logger.info("nothing actually happens")
