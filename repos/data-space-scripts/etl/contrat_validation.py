"""Validation de contrat de flux en mode warn (fiche 02) — shell impur.

Tâche Airflow dead-end : relit la capture brute du run courant dans une table
`source.*` et la valide contre le contrat YAML du flux (`contracts/*.yml`)
via les fonctions pures d'`etl.core.contrat`. Anomalies en WARNING dans les
logs Airflow ; la tâche ne lève jamais — le drift de schéma alerte, il ne
bloque pas (mode warn, durcissement flux par flux à l'étape 2).
"""

import logging
from pathlib import Path

import yaml
from airflow.providers.postgres.hooks.postgres import PostgresHook

from etl.core.contrat import parser_champs
from etl.core.contrat import valider_enregistrements

logger = logging.getLogger(__name__)

CONTRACTS_DIR = Path(__file__).resolve().parent.parent / "contracts"


def valider_contrat_source(table, contrat_nom, db_conn_id, run_id):
    """Valide la capture brute d'un run contre le contrat du flux.

    Args:
        table: table de capture qualifiée (ex. "source.ac__aidants").
        contrat_nom: nom du contrat dans contracts/ (ex. "ac__aidants").
        db_conn_id: connexion Airflow vers la base de données.
        run_id: identifiant du dag_run courant.
    """
    try:
        contrat = yaml.safe_load((CONTRACTS_DIR / f"{contrat_nom}.yml").read_text())
        champs = parser_champs(contrat)
        rows = PostgresHook(postgres_conn_id=db_conn_id).get_records(
            f"SELECT donnee FROM {table} WHERE run_id = %s", parameters=(run_id,)
        )
        records = [row[0] for row in rows]  # JSONB → dict (psycopg2)
        anomalies = valider_enregistrements(records, champs)
        if not anomalies:
            logger.info(
                "[contrat] %s : %d enregistrement(s) du run conformes au contrat %s",
                table,
                len(records),
                contrat_nom,
            )
            return
        for anomalie in anomalies:
            logger.warning(
                "[contrat] %s : %s '%s' sur %d/%d enregistrement(s) (contrat %s)",
                table,
                anomalie.categorie,
                anomalie.champ,
                anomalie.nb,
                anomalie.total,
                contrat_nom,
            )
    except Exception:
        logger.error(
            "[contrat] échec de la validation de %s (run_id=%s) — ignorée",
            table,
            run_id,
            exc_info=True,
        )
