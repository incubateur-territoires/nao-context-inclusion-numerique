"""Capture brute (couche source) du retour des APIs d'enrichissement.

Fabrique de *sink* agnostique d'Airflow : prend une connexion psycopg2 déjà
ouverte et renvoie un callable `sink(records, source_key)` qui insère les objets
bruts reçus dans une table `source.*` (append-only, JSONB).

Le sink avale ses propres erreurs (rollback + log) : une capture qui échoue ne
doit jamais interrompre le pipeline d'enrichissement.
"""

import json
import logging

from psycopg2.extras import execute_values

logger = logging.getLogger(__name__)

SIRENE_TABLE = "source.sirene__etablissements"
BAN_TABLE = "source.ban__adresses"
CARTO_TABLE = "source.carto__structures"

# Upsert du journal des captures : cumul de la volumétrie lot par lot.
_CAPTURE_RUN_UPSERT = (
    "INSERT INTO source.capture_run (run_id, table_cible, nb_lignes, derniere_capture_le) "
    "VALUES (%s, %s, %s, now()) "
    "ON CONFLICT (run_id, table_cible) DO UPDATE "
    "SET nb_lignes = capture_run.nb_lignes + EXCLUDED.nb_lignes, "
    "derniere_capture_le = EXCLUDED.derniere_capture_le"
)


def _ouvrir_capture_run(conn, run_id, table, parametres):
    """Ouvre la ligne de journal `source.capture_run` (nb_lignes = 0).

    Écrite dès la construction du sink : une ligne à 0 signifie « capture
    exécutée, rien reçu » — distinguable d'une absence totale de capture
    (échec silencieux). Erreur avalée, comme le sink.
    """
    try:
        with conn.cursor() as cur:
            cur.execute(
                "INSERT INTO source.capture_run (run_id, table_cible, parametres) "
                "VALUES (%s, %s, %s) "
                "ON CONFLICT (run_id, table_cible) DO NOTHING",
                (
                    run_id,
                    table,
                    (
                        json.dumps(parametres, ensure_ascii=False, default=str)
                        if parametres is not None
                        else None
                    ),
                ),
            )
        conn.commit()
    except Exception:
        logger.error(
            "[source] échec ouverture capture_run %s (run_id=%s) — journal ignoré",
            table,
            run_id,
            exc_info=True,
        )
        conn.rollback()


def make_source_sink(conn, run_id, table, parametres=None):
    """Construit un sink de capture brute pour `table`, réutilisant `conn`.

    Args:
        conn: connexion psycopg2 ouverte (commit géré par le sink, par lot).
        run_id: identifiant du dag_run Airflow.
        table: table cible qualifiée (ex. "source.sirene__etablissements").
        parametres: contexte du fetch (dict, optionnel), ex. le curseur d'un
            flux incrémental — journalisé dans `source.capture_run.parametres`.

    Returns:
        callable `sink(records, source_key)` append-only, tolérant aux erreurs.
    """
    _ouvrir_capture_run(conn, run_id, table, parametres)

    def sink(records, source_key):
        if not records:
            return
        rows = [
            (run_id, source_key, json.dumps(r, ensure_ascii=False, default=str))
            for r in records
        ]
        try:
            with conn.cursor() as cur:
                execute_values(
                    cur,
                    f"INSERT INTO {table} (run_id, source_key, donnee) VALUES %s",
                    rows,
                )
                # Même transaction que l'insertion : le compteur reste
                # cohérent avec les lignes réellement capturées.
                cur.execute(_CAPTURE_RUN_UPSERT, (run_id, table, len(rows)))
            conn.commit()
            logger.debug(
                "[source] %d lignes insérées dans %s (run_id=%s)",
                len(rows),
                table,
                run_id,
            )
        except Exception:
            logger.error(
                "[source] échec capture %s (run_id=%s) — capture ignorée",
                table,
                run_id,
                exc_info=True,
            )
            conn.rollback()

    return sink
