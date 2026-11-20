"""Exact binary64 CSV conversion to readable decimal values."""
from __future__ import annotations
import csv,hashlib,io,json,math,re,struct
from pathlib import Path
from file_utils import safe_path
from exact_numeric import decode_number,decimal_token
from validate_model_exchange import _CONTEXT_CHARS,_ROLE_CHARS
from cr2_white_archive_schema import CONTEXT_CHARS as WHITE_CONTEXT,role_chars
from aggregate_report_schema import CONTEXT as REPORT_CONTEXT,S
import inference_availability as inference
FORMAT='PY_REPR_BINARY64'
MAX_FILE=512*2**20
LOESS_MAX_FILE=1024*2**20
class Rejected(ValueError):
    pass

def need(value, code):
    if not value:
        raise Rejected(code)

def convert_csv(raw, chars, *, manifest=False):
    """Typed conversion only. Return decimal bytes, retaining all string cells.
    The only character-cell change is the explicit NumericFormat manifest label.
    """
    need(isinstance(raw, bytes) and 0 < len(raw) <= MAX_FILE and (b'\x00' not in raw), 'CSV_BYTES_INVALID')
    source = io.StringIO(raw.decode('utf-8-sig'), newline='')
    reader = csv.DictReader(source, strict=True)
    fields = reader.fieldnames or []
    fold = {name.casefold(): name for name in fields}
    need(len(fields) == len(fold) and fields, 'CSV_HEADER_INVALID')
    chars = {name.casefold() for name in chars}
    need(chars <= set(fold), 'CSV_CHARACTER_SCHEMA_INVALID')
    numeric = [name for name in fields if name.casefold() not in chars]
    out = io.StringIO(newline='')
    writer = csv.DictWriter(out, fieldnames=fields, lineterminator='\n')
    writer.writeheader()
    for row in reader:
        need(None not in row and None not in row.values(), 'CSV_ROW_INVALID')
        result = dict(row)
        for name in numeric:
            value = decode_number(row[name], allow_legacy=False, allow_missing=True)
            token = decimal_token(row[name])
            result[name] = token
            if math.isnan(value):
                need(token == '.', 'MISSING_CONVERSION_INVALID')
            else:
                need(struct.pack('>d', value) == struct.pack('>d', float(token)), 'NUMERIC_BITS_CHANGED')
        if manifest:
            name = fold.get('numericformat')
            need(name is not None and row[name] == 'HEX16_IEEE754', 'SOURCE_FORMAT_REQUIRED')
            result[name] = FORMAT
        writer.writerow(result)
    return out.getvalue().encode('utf-8')

def _stream_binding(path, limit):
    path = safe_path(path)
    before = path.stat()
    need(0 < before.st_size <= limit, 'CSV_SIZE_INVALID')
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    after = path.stat()
    need((before.st_size, before.st_mtime_ns, before.st_ino) == (after.st_size, after.st_mtime_ns, after.st_ino), 'SOURCE_CSV_CHANGED')
    return {'size': after.st_size, 'sha256': h.hexdigest()}

def convert_loess_file(source, target, expected, role):
    """Stream only the exact approved LOESS role; never load the full grid in RAM."""
    from loess_report_contract import SCHEMAS, CHARS
    need(role in SCHEMAS, 'ROLE_NOT_ALLOWED')
    source = safe_path(source)
    target = safe_path(target)
    limit = LOESS_MAX_FILE if role == 'loess_predictions' else MAX_FILE
    need(_stream_binding(source, limit) == expected, 'SOURCE_CSV_CHANGED')
    with source.open('r', encoding='utf-8-sig', newline='') as inp, target.open('x', encoding='utf-8', newline='') as out:
        reader = csv.DictReader(inp, strict=True)
        fields = reader.fieldnames or []
        need(fields == list(SCHEMAS[role]), 'LOESS_COLUMN_SCHEMA_INVALID')
        chars = set(CHARS[role])
        numeric = [x for x in fields if x not in chars]
        writer = csv.DictWriter(out, fieldnames=fields, lineterminator='\n')
        writer.writeheader()
        for row in reader:
            need(None not in row and None not in row.values(), 'CSV_ROW_INVALID')
            result = dict(row)
            need(all(('\x00' not in value for value in row.values())), 'CSV_BYTES_INVALID')
            for name in numeric:
                value = decode_number(row[name], allow_legacy=False, allow_missing=True)
                token = decimal_token(row[name])
                result[name] = token
                if math.isnan(value):
                    need(token == '.', 'MISSING_CONVERSION_INVALID')
                else:
                    need(struct.pack('>d', value) == struct.pack('>d', float(token)), 'NUMERIC_BITS_CHANGED')
            if role == 'loess_manifest':
                need(row['NumericFormat'] == 'HEX16_IEEE754', 'SOURCE_FORMAT_REQUIRED')
                result['NumericFormat'] = FORMAT
            writer.writerow(result)
        out.flush()
        import os
        os.fsync(out.fileno())
    need(_stream_binding(source, limit) == expected, 'SOURCE_CSV_CHANGED')
    return _stream_binding(target, LOESS_MAX_FILE)

def schema_chars(kind, role):
    if kind == 'WORKING':
        need(role in _ROLE_CHARS, 'ROLE_NOT_ALLOWED')
        return _CONTEXT_CHARS | set(_ROLE_CHARS[role].split())
    if kind == 'WHITE':
        try:
            chars = role_chars(role)
        except ValueError:
            need(False, 'ROLE_NOT_ALLOWED')
        return set(WHITE_CONTEXT) | set(chars)
    if kind == 'INFERENCE_UNAVAILABLE':
        try:
            chars = inference.role_chars(role)
        except ValueError:
            need(False, 'ROLE_NOT_ALLOWED')
        return set(inference.CONTEXT_CHARS) | set(chars)
    if kind == 'LOESS':
        from loess_report_contract import CHARS
        need(role in CHARS, 'ROLE_NOT_ALLOWED')
        return set(CHARS[role])
    need(kind == 'REPORT', 'KIND_INVALID')
    if role == 'aggregate_manifest':
        return set(REPORT_CONTEXT) | set('Protocol Role FileName NumericFormat TextEncoding ExportStatus'.split())
    need(role in S, 'ROLE_NOT_ALLOWED')
    return set(REPORT_CONTEXT) | set(S[role].chars)
