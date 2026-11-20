"""File checks and immutable metadata for local scientific results."""
from __future__ import annotations
import contextlib,hashlib,json,os,re,stat,time,uuid
from pathlib import Path

def private_directory(path: Path) -> bool:
    try:
        info = path.lstat()
        return stat.S_ISDIR(info.st_mode) and (not path.is_symlink()) and (not getattr(info, 'st_file_attributes', 0) & 1024)
    except OSError:
        return False

def regular_file(path: Path, max_bytes: int) -> bool:
    try:
        info = path.lstat()
        return stat.S_ISREG(info.st_mode) and (not path.is_symlink()) and (not getattr(info, 'st_file_attributes', 0) & 1024) and (info.st_size <= max_bytes)
    except OSError:
        return False

class StateError(Exception):

    def __init__(self, code):
        self.code = code
        super().__init__(code)

class ValidationRejected(StateError):
    """Explicit deterministic validator rejection; output cannot be selected."""

def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True, allow_nan=False).encode('ascii')

def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()

def safe_path(path):
    path = Path(path).absolute()
    for p in (path, *path.parents):
        try:
            s = p.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(s.st_mode) or getattr(s, 'st_file_attributes', 0) & 1024:
            raise StateError('REPARSE_PATH_REJECTED')
    return path

def read_record(path, limit=8 * 2 ** 20):
    path = safe_path(path)
    try:
        s = path.stat()
        if not stat.S_ISREG(s.st_mode) or not 0 < s.st_size <= limit:
            raise StateError('RECORD_INVALID')
        value = json.loads(path.read_text(encoding='ascii'), parse_constant=lambda value: (_ for _ in ()).throw(ValueError('NON_FINITE')))
    except StateError:
        raise
    except (OSError, ValueError, UnicodeError, RecursionError):
        raise StateError('RECORD_INVALID') from None
    if not isinstance(value, dict):
        raise StateError('RECORD_INVALID')
    return value

def write_once(path, value):
    """Fsynced temp then no-replace rename; incomplete temps remain evidence."""
    path = safe_path(path)
    safe_path(path.parent)
    if path.exists():
        raise StateError('IMMUTABLE_RECORD_EXISTS')
    raw = canonical(value) + b'\n'
    if len(raw) > 8 * 2 ** 20:
        raise StateError('RECORD_TOO_LARGE')
    temporary = path.with_name('.p' + uuid.uuid4().hex)
    if os.name == 'nt' and (not str(path).startswith(chr(92) * 2 + '?' + chr(92))) and (max(len(str(path)), len(str(temporary))) >= 260):
        raise StateError('OWNED_PATH_TOO_LONG')
    with temporary.open('xb') as f:
        f.write(raw)
        f.flush()
        os.fsync(f.fileno())
    safe_path(path)
    try:
        if os.name == 'nt':
            for retry in range(6):
                try:
                    os.rename(temporary, path)
                    break
                except OSError as error:
                    if getattr(error, 'winerror', None) not in {5, 32} or retry == 5:
                        raise
                    time.sleep(0.01 * 2 ** retry)
        else:
            os.link(temporary, path)
            temporary.unlink()
    except FileExistsError:
        raise StateError('IMMUTABLE_RECORD_EXISTS') from None
    return digest(value)
