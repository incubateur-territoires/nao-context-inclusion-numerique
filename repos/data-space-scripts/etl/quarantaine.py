"""Quarantaine des lignes écartées (fiche 03) — écriture dans staging.rejets.

Fabrique de *sink* sur le modèle de `etl/source_capture.py` : prend une
connexion psycopg2 déjà ouverte et renvoie un callable `sink(rejets)` qui
insère les ``Rejet`` (etl/core/rejets.py) retournés par les transformations
pures.

Le sink avale ses propres erreurs (rollback + log) : une quarantaine qui
échoue ne doit jamais interrompre le pipeline.
"""

import json
import logging

from psycopg2.extras import execute_values

logger = logging.getLogger(__name__)


def make_rejets_sink(conn, run_id, flux, etape):
    """Construit un sink de quarantaine vers `staging.rejets`.

    Args:
        conn: connexion psycopg2 ouverte (commit géré par le sink).
        run_id: identifiant du dag_run Airflow.
        flux: flux concerné, convention source (ex. "carto__structures").
        etape: étape du pipeline qui écarte (ex. "ingest").

    Returns:
        callable `sink(rejets: list[Rejet])`, tolérant aux erreurs.
    """

    def sink(rejets):
        if not rejets:
            return
        rows = [
            (
                run_id,
                flux,
                etape,
                r.motif,
                r.source_key,
                json.dumps(r.payload, ensure_ascii=False, default=str),
            )
            for r in rejets
        ]
        try:
            with conn.cursor() as cur:
                execute_values(
                    cur,
                    "INSERT INTO staging.rejets "
                    "(run_id, flux, etape, motif, source_key, payload) VALUES %s",
                    rows,
                )
            conn.commit()
            logger.warning(
                "[quarantaine] %d rejet(s) écrits dans staging.rejets "
                "(flux=%s, etape=%s, run_id=%s)",
                len(rows),
                flux,
                etape,
                run_id,
            )
        except Exception:
            logger.error(
                "[quarantaine] échec écriture staging.rejets "
                "(flux=%s, run_id=%s) — rejets perdus",
                flux,
                run_id,
                exc_info=True,
            )
            conn.rollback()

    return sink
