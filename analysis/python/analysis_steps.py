"""Select existing analysis outputs for validation or decimal conversion."""
from pathlib import Path
import re

def select_steps(output, model_ids=None):
    output=Path(output)
    if model_ids is not None:
        selected=list(model_ids)
        if not selected or len(set(selected))!=len(selected) or any(not isinstance(x,str) or not re.fullmatch(r'M(?:00[0-9]{2}|01[0-9]{2}|02[0-4][0-9]|025[0-2])',x) or x=='M0000' for x in selected):
            raise ValueError('UNKNOWN_OR_DUPLICATE_MODEL_SELECTION')
        steps=[output/'models'/key for key in selected]
        if not all(step.is_dir() and not step.is_symlink() for step in steps):
            raise ValueError('SELECTED_MODEL_OUTPUT_MISSING')
        return steps
    steps=[]
    for folder in ('models','reports'):
        if (output/folder).is_dir():
            steps.extend(p for p in sorted((output/folder).iterdir()) if p.is_dir())
    if (output/'loess').is_dir():steps.append(output/'loess')
    if not steps:raise ValueError('NO_ANALYSIS_OUTPUTS')
    return steps
