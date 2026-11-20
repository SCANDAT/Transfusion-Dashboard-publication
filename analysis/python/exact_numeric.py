"""Decode binary64 transport values and convert them to round-tripping decimal text."""
from __future__ import annotations
import math
import re
import struct
from collections.abc import Mapping, Iterable
NUMERIC_FORMAT = 'HEX16_IEEE754'
_HEX = re.compile('H[0-9A-F]{16}')
_DECIMAL = re.compile('[+-]?(?:[0-9]+(?:[.][0-9]*)?|[.][0-9]+)(?:[Ee][+-]?[0-9]+)?')

class ExactNumericError(ValueError):

    def __init__(self, code):
        self.code = code
        super().__init__(code)

def parse_number(token: str, *, allow_legacy_decimal: bool=False) -> float:
    """Decode only a schema-declared numeric cell; missing becomes NaN.

    Strict mode rejects decimal, lowercase/malformed hex, infinity/NaN bit
    patterns and all noncanonical SAS missing labels. Signed zero is retained.
    """
    if not isinstance(token, str):
        raise ExactNumericError('NUMERIC_TOKEN_TYPE')
    if token in ('', '.'):
        return math.nan
    if _HEX.fullmatch(token):
        value = struct.unpack('>d', bytes.fromhex(token[1:]))[0]
    elif allow_legacy_decimal and len(token) <= 80 and _DECIMAL.fullmatch(token):
        value = float(token)
    else:
        raise ExactNumericError('NUMERIC_TOKEN_INVALID')
    if not math.isfinite(value):
        raise ExactNumericError('NUMERIC_TOKEN_NONFINITE')
    return value

def decimal_token(token: str, *, allow_legacy_decimal: bool=False) -> str:
    """Portable shortest roundtripping decimal; '.' remains missing.

    This is a representation conversion, not a change in the stored estimator.
    Decimal release files must retain provenance to immutable hexadecimal bytes.
    """
    value = parse_number(token, allow_legacy_decimal=allow_legacy_decimal)
    return '.' if math.isnan(value) else repr(value)

def normalize_numeric_cells(row: Mapping[str, str], numeric_columns: Iterable[str], *, allow_legacy_decimal: bool=False) -> dict[str, str]:
    """Return a copy, decoding only explicitly declared numeric column names.

    Character tokens, including strings that resemble hexadecimal numbers,
    remain exactly unchanged. Headers/schema/provenance are caller obligations.
    """
    cols = tuple(numeric_columns)
    if len(cols) != len(set(cols)) or any((not isinstance(k, str) or k not in row for k in cols)):
        raise ExactNumericError('NUMERIC_SCHEMA_INVALID')
    result = dict(row)
    for key in cols:
        result[key] = decimal_token(row[key], allow_legacy_decimal=allow_legacy_decimal)
    return result

def decode_number(text: str, *, allow_legacy: bool=False, allow_missing: bool=False) -> float:
    """Consumer alias: explicit legacy policy and explicit missing policy."""
    value = parse_number(text, allow_legacy_decimal=allow_legacy)
    if math.isnan(value) and (not allow_missing):
        raise ExactNumericError('NUMERIC_MISSING_NOT_ALLOWED')
    return value

def numeric_encoding(text: str) -> str | None:
    """Classify a validated numeric token for manifest consistency checks."""
    value = parse_number(text, allow_legacy_decimal=True)
    if math.isnan(value):
        return None
    return NUMERIC_FORMAT if _HEX.fullmatch(text) else 'E32_STDIEEE'
