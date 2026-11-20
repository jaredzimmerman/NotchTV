"""Long-lived bridge between NotchTV.app and the Apple TV on the current network.

It keeps a single pyatv connection open so a click costs one round trip, and it
picks whichever *paired* Apple TV is visible on the network the Mac is on now
(say, one at home and another at a holiday place). `rescan` drops the connection
and looks again; the app sends it when the network changes or the Mac wakes.

Protocol: one command per stdin line, one JSON object per stdout line.

  commands  toggle [req] | state [req] | rescan | pair <id> | pin <code> |
            cancel_pair | quit
  replies   {"ok": true, "state": "playing|paused|idle|unknown",
             "action": "play|pause|play_pause|none", "name": ..., "req": ...}
            {"ok": false, "error": ..., "req": ...}
            (to toggle/state; `state` is the state after the action; each
            command is capped at RUN_LIMIT seconds)
  events    ready{id,name} · searching · error{error} · unpaired{devices} ·
            playstate{state} · pin_needed{id,name,step,steps} · paired{id,name} ·
            pair_failed{error} · pair_cancelled

A TV counts as paired once it has credentials for both Companion (commands)
and AirPlay (the tunnel that reports play state); pairing resumes at whichever
is missing.
"""

import argparse
import asyncio
import json
import os
import sys

import pyatv
from pyatv.const import DeviceModel, DeviceState, OperatingSystem, Protocol
from pyatv.interface import DeviceListener, PushListener
from pyatv.storage.file_storage import FileStorage

COMMAND_WAIT = 8.0  # seconds a command waits for a (re)connection (they take 5-6 s)
RUN_LIMIT = 11.0  # hard cap per command; the app gives up at 12 s
RETRY_DELAYS = [2, 5, 10, 20, 30]
UNPAIRED_RECHECK = 30.0
PAIR_PROTOCOLS = [Protocol.Companion, Protocol.AirPlay]
HOMEPODS = {DeviceModel.HomePod, DeviceModel.HomePodMini, DeviceModel.HomePodGen2}
SUPPORT = os.path.expanduser("~/Library/Application Support/NotchTV")
CONFIG = os.path.join(SUPPORT, "config.json")
PAIRINGS = os.path.join(SUPPORT, "pairings.json")  # pyatv credentials; never leaves this Mac
LEGACY_PAIRINGS = os.path.expanduser("~/.pyatv.conf")  # where atvremote (and early builds) keep them


def pairing_storage(loop: asyncio.AbstractEventLoop) -> FileStorage:
    """The app's own pyatv storage. The first run picks up pairings made with atvremote."""
    os.makedirs(SUPPORT, exist_ok=True)
    if not os.path.exists(PAIRINGS) and os.path.exists(LEGACY_PAIRINGS):
        try:
            with open(LEGACY_PAIRINGS, "rb") as src, open(PAIRINGS, "wb") as dst:
                dst.write(src.read())
            os.chmod(PAIRINGS, 0o600)
        except OSError:
            pass
    return FileStorage(PAIRINGS, loop)


def emit(obj: dict) -> None:
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def read_config() -> dict:
    try:
        with open(CONFIG) as f:
            return json.load(f)
    except Exception:
        return {}


def write_config(data: dict) -> None:
    os.makedirs(os.path.dirname(CONFIG), exist_ok=True)
    tmp = CONFIG + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, CONFIG)


def is_apple_tv(conf) -> bool:
    info = conf.device_info
    return (
        info.operating_system == OperatingSystem.TvOS
        and info.model not in HOMEPODS
        and conf.get_service(Protocol.Companion) is not None
    )


def missing_protocols(conf) -> list:
    """Protocols this Apple TV offers that we hold no credentials for yet."""
    missing = []
    for protocol in PAIR_PROTOCOLS:
        service = conf.get_service(protocol)
        if service is not None and not service.credentials:
            missing.append(protocol)
    return missing


def is_paired(conf) -> bool:
    # Companion sends the commands; AirPlay (the MRP tunnel) tells us whether it is
    # playing. Half a pairing would leave every click a blind toggle, so it doesn't count.
    return conf.get_service(Protocol.Companion) is not None and not missing_protocols(conf)


def state_name(device_state) -> str:
    """What the app needs to know: is a click going to pause, or to play?"""
    if device_state in (DeviceState.Playing, DeviceState.Seeking, DeviceState.Loading):
        return "playing"
    if device_state == DeviceState.Paused:
        return "paused"
    if device_state in (DeviceState.Idle, DeviceState.Stopped):
        return "idle"
    return "unknown"


class PlayStateListener(PushListener):
    """Forwards play/pause changes (from any remote) so the hover icon is always right."""

    def __init__(self, bridge: "Bridge", atv):
        self.bridge, self.atv = bridge, atv

    def playstatus_update(self, updater, playstatus) -> None:
        if self.atv is self.bridge.atv:
            self.bridge.publish_state(state_name(playstatus.device_state))

    def playstatus_error(self, updater, exception: Exception) -> None:
        pass


def close_quietly(atv) -> None:
    try:
        atv.close()
    except Exception:
        pass


class ConnectionListener(DeviceListener):
    """One per connection, so a late callback from an old connection can't drop the new one."""

    def __init__(self, bridge: "Bridge", atv):
        self.bridge, self.atv = bridge, atv

    def connection_lost(self, exception: Exception) -> None:
        self.bridge.on_lost(self.atv)

    def connection_closed(self) -> None:
        self.bridge.on_lost(self.atv)


class Bridge:
    def __init__(self, loop: asyncio.AbstractEventLoop):
        self.loop = loop
        self.storage = pairing_storage(loop)
        self.atv = None
        self.name = None
        self.connected = asyncio.Event()
        self.lost = asyncio.Event()
        self.wake = asyncio.Event()
        self.lock = asyncio.Lock()
        self.pairing = None  # (conf, remaining protocols, current step, total steps, handler)
        self.play_state = None  # last state sent as a playstate event

    def on_lost(self, atv) -> None:
        if atv is self.atv:
            self._drop()

    def _drop(self) -> None:
        self.atv = None
        self.play_state = None
        self.connected.clear()
        self.lost.set()

    def publish_state(self, state: str) -> None:
        if state != self.play_state:
            self.play_state = state
            emit({"event": "playstate", "state": state})

    # -- connection loop --------------------------------------------------
    async def _nap(self, seconds: float) -> None:
        """Sleep, but wake early on `rescan` or a finished pairing."""
        try:
            await asyncio.wait_for(self.wake.wait(), seconds)
        except asyncio.TimeoutError:
            pass
        self.wake.clear()

    async def scan_apple_tvs(self) -> list:
        confs = await pyatv.scan(self.loop, storage=self.storage, timeout=5)
        return [c for c in confs if is_apple_tv(c)]

    def choose(self, paired: list):
        last = read_config().get("last_device_id")
        for conf in paired:
            if last in conf.all_identifiers:
                return conf
        return paired[0]

    async def keep_connected(self) -> None:
        await self.storage.load()
        attempt = 0
        while True:
            atv, nap = None, None
            self.lost.clear()
            self.wake.clear()
            try:
                tvs = await self.scan_apple_tvs()
                paired = [c for c in tvs if is_paired(c)]
                if not tvs:
                    raise RuntimeError("No Apple TV on this network")
                if not paired:
                    emit({
                        "event": "unpaired",
                        "devices": [{"id": c.identifier, "name": c.name} for c in tvs],
                    })
                    nap = UNPAIRED_RECHECK
                else:
                    conf = self.choose(paired)
                    atv = await pyatv.connect(conf, self.loop, storage=self.storage)
                    if self.lost.is_set():
                        continue  # a rescan arrived mid-connect: this may be the old network's TV
                    # pyatv holds listeners by weak reference: these locals keep them alive
                    # for exactly as long as this connection.
                    conn_listener = ConnectionListener(self, atv)
                    push_listener = PlayStateListener(self, atv)
                    atv.listener = conn_listener
                    self.atv, self.name = atv, conf.name
                    self.connected.set()
                    attempt = 0
                    config = read_config()
                    if config.get("last_device_id") != conf.identifier:
                        config["last_device_id"] = conf.identifier
                        write_config(config)
                    emit({"event": "ready", "id": conf.identifier, "name": conf.name})
                    try:
                        atv.push_updater.listener = push_listener
                        atv.push_updater.start()  # posts the current state, then every change
                    except Exception as exc:
                        emit({"event": "error", "error": f"No live play state: {exc}"})
                    await self.lost.wait()
                    emit({"event": "searching"})
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # keep trying; the app shows it on click
                emit({"event": "error", "error": str(exc) or type(exc).__name__})
                nap = RETRY_DELAYS[min(attempt, len(RETRY_DELAYS) - 1)]
                attempt += 1
            finally:
                # This loop owns the connection: whatever ended it, close every protocol.
                if atv is not None:
                    self.on_lost(atv)
                    close_quietly(atv)
            if nap:
                await self._nap(nap)

    def rescan(self) -> None:
        self._drop()  # keep_connected wakes, closes the old connection and scans again
        self.wake.set()

    # -- playback ---------------------------------------------------------
    async def current_state(self, atv) -> str:
        try:
            playing = await asyncio.wait_for(atv.metadata.playing(), 3)
        except Exception:
            return "unknown"
        return state_name(playing.device_state)

    async def run(self, command: str, req: str) -> dict:
        try:
            reply = await asyncio.wait_for(self._run(command), RUN_LIMIT)
        except asyncio.TimeoutError:
            self.rescan()
            reply = {"ok": False, "error": "Timed out"}
        if req:
            reply["req"] = req
        return reply

    async def _run(self, command: str) -> dict:
        try:
            await asyncio.wait_for(self.connected.wait(), COMMAND_WAIT)
        except asyncio.TimeoutError:
            return {"ok": False, "error": "No Apple TV"}
        atv, name = self.atv, self.name
        if atv is None:
            return {"ok": False, "error": "No Apple TV"}
        async with self.lock:
            try:
                before = await self.current_state(atv)
                if command == "state":
                    return {"ok": True, "state": before, "action": "none", "name": name}
                rc = atv.remote_control
                if before == "playing":
                    await rc.pause()
                    return {"ok": True, "state": "paused", "action": "pause", "name": name}
                if before in ("paused", "idle"):
                    await rc.play()
                    return {"ok": True, "state": "playing", "action": "play", "name": name}
                await rc.play_pause()
                return {"ok": True, "state": "unknown", "action": "play_pause", "name": name}
            except Exception as exc:
                self.rescan()  # a failed send usually means a dead socket
                return {"ok": False, "error": str(exc) or type(exc).__name__, "name": name}

    # -- pairing ----------------------------------------------------------
    async def _begin_step(self, conf, remaining: list, step: int, steps: int) -> None:
        handler = await pyatv.pair(conf, remaining[0], self.loop, storage=self.storage)
        try:
            await handler.begin()
        except Exception:
            await self._close_handler(handler)
            raise
        self.pairing = (conf, remaining, step, steps, handler)
        emit({
            "event": "pin_needed",
            "id": conf.identifier,
            "name": conf.name,
            "step": step,
            "steps": steps,
        })

    async def pair(self, device_id: str) -> None:
        await self.cancel_pair(quiet=True)
        try:
            confs = await pyatv.scan(
                self.loop, identifier=device_id, storage=self.storage, timeout=5
            )
            if not confs:
                raise RuntimeError("That Apple TV isn't on this network")
            # Resume where an earlier attempt stopped (e.g. the AirPlay PIN was mistyped).
            remaining = missing_protocols(confs[0]) or list(PAIR_PROTOCOLS)
            await self._begin_step(confs[0], remaining, 1, len(remaining))
        except Exception as exc:
            await self.cancel_pair(quiet=True)
            emit({"event": "pair_failed", "error": str(exc) or type(exc).__name__})

    async def pin(self, code: str) -> None:
        if self.pairing is None:
            emit({"event": "pair_failed", "error": "Not pairing"})
            return
        conf, remaining, step, steps, handler = self.pairing
        try:
            handler.pin(code)
            await handler.finish()
            if not handler.has_paired:
                raise RuntimeError("Wrong PIN")
            await self._close_handler(handler)
            self.pairing = None
            await self.storage.save()
            if len(remaining) > 1:
                await self._begin_step(conf, remaining[1:], step + 1, steps)
                return
            emit({"event": "paired", "id": conf.identifier, "name": conf.name})
            config = read_config()
            config["last_device_id"] = conf.identifier
            write_config(config)
            self.rescan()
        except Exception as exc:
            await self.cancel_pair(quiet=True)
            emit({"event": "pair_failed", "error": str(exc) or type(exc).__name__})

    @staticmethod
    async def _close_handler(handler) -> None:
        try:
            await handler.close()
        except Exception:
            pass

    async def cancel_pair(self, quiet: bool = False) -> None:
        if self.pairing is not None:
            handler = self.pairing[-1]
            self.pairing = None
            await self._close_handler(handler)
            if not quiet:
                emit({"event": "pair_cancelled"})


async def main() -> None:
    argparse.ArgumentParser(description=__doc__).parse_args()
    loop = asyncio.get_running_loop()
    bridge = Bridge(loop)
    keeper = asyncio.create_task(bridge.keep_connected())

    reader = asyncio.StreamReader()
    await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin)
    while True:
        line = await reader.readline()
        if not line:  # the app went away
            break
        command, _, arg = line.decode().strip().partition(" ")
        if command == "quit":
            break
        elif command in ("toggle", "state"):
            emit(await bridge.run(command, arg.strip()))
        elif command == "rescan":
            bridge.rescan()
        elif command == "pair" and arg:
            await bridge.pair(arg.strip())
        elif command == "pin" and arg:
            await bridge.pin(arg.strip())
        elif command == "cancel_pair":
            await bridge.cancel_pair()
        elif command:
            emit({"ok": False, "error": f"unknown command: {command}"})

    keeper.cancel()
    await bridge.cancel_pair(quiet=True)
    if bridge.atv is not None:
        close_quietly(bridge.atv)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
