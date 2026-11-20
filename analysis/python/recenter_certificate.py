"""Recalculate the numerical error bound around a given center."""
import numpy as np
from moment_error_certificate import Ball, add_up, up, finite

def recenter(original, ball):
    original = finite(original)
    if original.shape != ball.value.shape:
        raise ValueError('RECENTER_DIMENSION')
    difference = finite(original - ball.value)
    shift = up(np.abs(difference))
    error = add_up(ball.error, shift)
    return Ball(original.copy(), error)
