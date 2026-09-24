"""Rejet de quarantaine (fiche 03) — type pur partagé par les cores.

Une transformation qui écarte une ligne ne la droppe plus silencieusement :
elle la retourne sous forme de ``Rejet`` (ligne complète + motif). Le shell
les écrit dans ``staging.rejets`` (voir ``etl/quarantaine.py``).
"""

from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class Rejet:
    """Une ligne écartée par une transformation, avec son motif."""

    motif: str
    payload: dict[str, Any]
    source_key: str | None = None
