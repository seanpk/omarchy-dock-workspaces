#!/usr/bin/python3 -I
"""Descriptor-bound reads and atomic writes for Dock Workspaces.

Walks from the passwd home with held directory descriptors, opens the
final file O_NOFOLLOW, and publishes writes with exclusive same-directory
rename. The CLI never takes a path argument.
"""
from __future__ import annotations

import json
import os
import pwd
import re
import secrets
import stat
import sys

HYPRLAND_MAX = 1048576
CONFIG_MAX = 8192
STATE_MAX = 4096
_COMPONENT = re.compile(r"[A-Za-z0-9._-]+")
_STATE_LINE = re.compile(r"[1-9][0-9]{0,4}$")
LOADER_BEGIN = "-- seanpk.dock-workspaces start"
LOADER_END = "-- seanpk.dock-workspaces end"
STATE_NAME = "dock-workspaces-laptop-ids"
LEGACY_STATE_NAME = "workspace-laptop-affinity"
CONFIG_NAME = "dock-workspaces.json"
HYPRLAND_NAME = "hyprland.lua"
MAX_STATE_IDS = 64

_OPS = {
    "read-hyprland": "read",
    "write-hyprland": "write",
    "read-config": "read",
    "write-config": "write",
    "read-state": "read",
    "write-state": "write",
}


def _ok_component(name: str) -> bool:
    return bool(_COMPONENT.fullmatch(name)) and name not in (".", "..")


def _euid() -> int:
    return os.geteuid()


def rel_parts_from_home(env_name: str, default_parts: list[str]) -> list[str]:
    home = pwd.getpwuid(_euid()).pw_dir.rstrip("/")
    value = os.environ.get(env_name, "")
    if not value:
        return list(default_parts)
    if not os.path.isabs(value):
        raise PermissionError(f"{env_name} must be absolute")
    if value.rstrip("/") == home:
        return []
    prefix = home + "/"
    if not value.startswith(prefix):
        raise PermissionError(f"{env_name} is outside the home directory")
    rel = value[len(prefix):].strip("/")
    parts = rel.split("/") if rel else []
    if not all(_ok_component(p) for p in parts):
        raise PermissionError(f"{env_name} has an unsafe component")
    return parts


def open_dir_chain(
    parts: list[str],
    *,
    anchor_fd: int | None = None,
    create_missing: bool = False,
    tighten_leaf: bool = False,
) -> int:
    if not all(_ok_component(p) for p in parts):
        raise PermissionError("refusing directory chain")
    if anchor_fd is None:
        home = pwd.getpwuid(_euid()).pw_dir
        fd = os.open(home, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    else:
        fd = os.dup(anchor_fd)
    try:
        for i, name in enumerate(parts):
            try:
                nfd = os.open(
                    name,
                    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                    dir_fd=fd,
                )
            except FileNotFoundError:
                if not create_missing:
                    raise
                try:
                    os.mkdir(name, 0o700, dir_fd=fd)
                except FileExistsError:
                    pass
                nfd = os.open(
                    name,
                    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                    dir_fd=fd,
                )
            os.close(fd)
            fd = nfd
            st = os.fstat(fd)
            if not stat.S_ISDIR(st.st_mode) or st.st_uid != _euid():
                raise PermissionError(f"untrusted directory component {name}")
            if tighten_leaf and i == len(parts) - 1 and st.st_mode & 0o077:
                os.fchmod(fd, 0o700)
        return fd
    except BaseException:
        os.close(fd)
        raise


def read_bounded(
    dirfd: int,
    name: str,
    max_bytes: int,
    *,
    require_private: bool = False,
) -> bytes | None:
    if not _ok_component(name):
        raise PermissionError("refusing file name")
    try:
        fd = os.open(
            name,
            os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
            dir_fd=dirfd,
        )
    except FileNotFoundError:
        return None
    except OSError as err:
        raise PermissionError("refusing path") from err
    try:
        st = os.fstat(fd)
        world_or_group_write = st.st_mode & 0o022
        private_bits = st.st_mode & 0o077 if require_private else 0
        if (
            not stat.S_ISREG(st.st_mode)
            or st.st_uid != _euid()
            or st.st_nlink != 1
            or world_or_group_write
            or private_bits
            or st.st_size > max_bytes
        ):
            raise PermissionError("refusing file (type/owner/mode/size)")
        os.set_blocking(fd, True)
        data = b""
        while len(data) <= max_bytes:
            chunk = os.read(fd, min(65536, max_bytes + 1 - len(data)))
            if not chunk:
                break
            data += chunk
        if len(data) > max_bytes:
            raise PermissionError("file grew past the limit")
        return data
    finally:
        os.close(fd)


def write_atomic(dirfd: int, name: str, data: bytes, max_bytes: int, mode: int) -> None:
    if not _ok_component(name):
        raise PermissionError("refusing file name")
    if len(data) > max_bytes:
        raise ValueError("payload too large")
    tmp = f".{name}.{secrets.token_hex(8)}.tmp"
    fd = os.open(
        tmp,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
        0o600,
        dir_fd=dirfd,
    )
    try:
        os.fchmod(fd, mode)
        view = memoryview(data)
        while view:
            n = os.write(fd, view)
            view = view[n:]
        os.fsync(fd)
        os.rename(tmp, name, src_dir_fd=dirfd, dst_dir_fd=dirfd)
        os.fsync(dirfd)
    except BaseException:
        try:
            os.unlink(tmp, dir_fd=dirfd)
        except OSError:
            pass
        raise
    finally:
        os.close(fd)


def _decode(data: bytes) -> str:
    return data.decode("utf-8", "strict")


def _encode(text: str) -> bytes:
    return text.encode("utf-8", "strict")


def _config_parts() -> list[str]:
    return rel_parts_from_home("XDG_CONFIG_HOME", [".config"])


def _state_parts() -> list[str]:
    return rel_parts_from_home("XDG_STATE_HOME", [".local", "state"])


def validate_config(text: str) -> str:
    raw = text.strip()
    if raw == "":
        raise ValueError("empty config")
    parsed = json.loads(raw)
    if not isinstance(parsed, dict):
        raise ValueError("config must be an object")
    laptop = parsed.get("laptop", "")
    primary = parsed.get("primary", "")
    if not isinstance(laptop, str) or not isinstance(primary, str):
        raise ValueError("selector must be a string")
    if len(laptop) > 200 or len(primary) > 200:
        raise ValueError("selector too long")
    if "\0" in laptop or "\0" in primary or "\n" in laptop or "\n" in primary:
        raise ValueError("selector has a newline")
    payload = {
        "version": 1,
        "enabled": parsed.get("enabled") is not False,
        "laptop": laptop,
        "primary": primary,
    }
    return json.dumps(payload, indent=2) + "\n"


def validate_state(text: str) -> str:
    ids: list[int] = []
    seen: set[int] = set()
    for line in text.splitlines():
        raw = line.strip()
        if raw == "":
            continue
        if not _STATE_LINE.fullmatch(raw):
            raise ValueError("state line is not a workspace id")
        n = int(raw, 10)
        if n in seen:
            continue
        seen.add(n)
        ids.append(n)
        if len(ids) > MAX_STATE_IDS:
            raise ValueError("too many workspace ids")
    ids.sort()
    return "".join(f"{n}\n" for n in ids)


def validate_hyprland(text: str) -> str:
    if text.count(LOADER_BEGIN) > 1 or text.count(LOADER_END) > 1:
        raise ValueError("duplicate loader markers")
    if "\0" in text:
        raise ValueError("NUL in hyprland.lua")
    return text


def _read_named(parts: list[str], name: str, max_bytes: int, create_missing: bool) -> bytes | None:
    dirfd = open_dir_chain(parts, create_missing=create_missing, tighten_leaf=False)
    try:
        return read_bounded(dirfd, name, max_bytes)
    finally:
        os.close(dirfd)


def _write_named(
    parts: list[str],
    name: str,
    data: bytes,
    max_bytes: int,
    mode: int,
    *,
    create_missing: bool,
    must_exist: bool,
) -> None:
    dirfd = open_dir_chain(parts, create_missing=create_missing, tighten_leaf=False)
    try:
        if must_exist:
            existing = read_bounded(dirfd, name, max_bytes)
            if existing is None:
                raise FileNotFoundError(name)
        write_atomic(dirfd, name, data, max_bytes, mode)
    finally:
        os.close(dirfd)


def read_hyprland() -> bytes | None:
    return _read_named(_config_parts() + ["hypr"], HYPRLAND_NAME, HYPRLAND_MAX, False)


def write_hyprland(text: str) -> None:
    payload = _encode(validate_hyprland(text))
    _write_named(
        _config_parts() + ["hypr"],
        HYPRLAND_NAME,
        payload,
        HYPRLAND_MAX,
        0o644,
        create_missing=False,
        must_exist=True,
    )


def read_config() -> bytes | None:
    return _read_named(_config_parts() + ["omarchy"], CONFIG_NAME, CONFIG_MAX, False)


def write_config(text: str) -> None:
    payload = _encode(validate_config(text))
    _write_named(
        _config_parts() + ["omarchy"],
        CONFIG_NAME,
        payload,
        CONFIG_MAX,
        0o600,
        create_missing=True,
        must_exist=False,
    )


def read_state() -> bytes | None:
    parts = _state_parts() + ["omarchy"]
    dirfd = open_dir_chain(parts, create_missing=False, tighten_leaf=False)
    try:
        data = read_bounded(dirfd, STATE_NAME, STATE_MAX)
        if data is None:
            data = read_bounded(dirfd, LEGACY_STATE_NAME, STATE_MAX)
        return data
    finally:
        os.close(dirfd)


def write_state(text: str) -> None:
    payload = _encode(validate_state(text))
    _write_named(
        _state_parts() + ["omarchy"],
        STATE_NAME,
        payload,
        STATE_MAX,
        0o600,
        create_missing=True,
        must_exist=False,
    )


def _emit(status: str, body: bytes = b"") -> int:
    sys.stdout.buffer.write(status.encode("ascii") + b"\n" + body)
    sys.stdout.buffer.flush()
    return 0


def _read_stdin(max_bytes: int) -> bytes:
    data = sys.stdin.buffer.read(max_bytes + 1)
    if len(data) > max_bytes:
        raise ValueError("payload too large")
    return data


def main(argv: list[str]) -> int:
    if len(argv) != 2 or argv[1] not in _OPS:
        return 2
    op = argv[1]
    try:
        if op == "read-hyprland":
            data = read_hyprland()
            return _emit("MISSING") if data is None else _emit("OK", data)
        if op == "read-config":
            data = read_config()
            return _emit("MISSING") if data is None else _emit("OK", data)
        if op == "read-state":
            data = read_state()
            return _emit("MISSING") if data is None else _emit("OK", data)
        if op == "write-hyprland":
            write_hyprland(_decode(_read_stdin(HYPRLAND_MAX)))
            return _emit("OK")
        if op == "write-config":
            write_config(_decode(_read_stdin(CONFIG_MAX)))
            return _emit("OK")
        if op == "write-state":
            write_state(_decode(_read_stdin(STATE_MAX)))
            return _emit("OK")
        return 2
    except FileNotFoundError:
        _emit("MISSING")
        return 1
    except PermissionError:
        _emit("REFUSED")
        return 4
    except (ValueError, json.JSONDecodeError, UnicodeDecodeError, OSError):
        _emit("REFUSED")
        return 4


if __name__ == "__main__":
    sys.exit(main(sys.argv))
