"""Fixture — simulates a real implementation body."""
import asyncio


async def run(url: str, adapter: object) -> None:
    queue: asyncio.Queue[dict[str, object]] = asyncio.Queue()
    async with asyncio.TaskGroup() as tg:
        tg.create_task(_directive_loop(queue, adapter))
        tg.create_task(_event_loop(adapter))


async def _directive_loop(q: asyncio.Queue[dict[str, object]], adapter: object) -> None:
    while True:
        item = await q.get()
        _ = item


async def _event_loop(adapter: object) -> None:
    await asyncio.sleep(0.001)
