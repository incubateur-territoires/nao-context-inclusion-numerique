"""Exécution des tests qualité SQL en mode warn (fiche 03) — shell impur.

Tâche Airflow dead-end : exécute les invariants de ``tests/quality/*.sql``
(parsés par ``etl.core.qualite``) sur la base cible du run. Chaque requête
doit renvoyer 0 ligne ; toute ligne renvoyée est loguée en WARNING avec le
nom du test et un extrait. La tâche ne lève jamais — les invariants alertent,
ils ne bloquent pas (mode warn, durcissement à l'étape 2 de la fiche 08).
"""

import logging
from pathlib import Path

from airflow.providers.postgres.hooks.postgres import PostgresHook

from etl.core.qualite import parser_tests

logger = logging.getLogger(__name__)

QUALITY_DIR = Path(__file__).resolve().parent.parent / "tests" / "quality"


def executer_tests_qualite(db_conn_id):
    """Exécute tous les fichiers de tests qualité sur la base cible.

    Args:
        db_conn_id: connexion Airflow vers la base de données du run.
    """
    try:
        hook = PostgresHook(postgres_conn_id=db_conn_id)
        nb_tests = 0
        nb_anomalies = 0
        for fichier in sorted(QUALITY_DIR.glob("*.sql")):
            for test in parser_tests(fichier.read_text()):
                nb_tests += 1
                try:
                    rows = hook.get_records(test.sql)
                except Exception:
                    nb_anomalies += 1
                    logger.error(
                        "[qualite] %s/%s : échec d'exécution de la requête",
                        fichier.stem,
                        test.nom,
                        exc_info=True,
                    )
                    continue
                if rows:
                    nb_anomalies += 1
                    logger.warning(
                        "[qualite] %s/%s (%s) : %d ligne(s) en anomalie — ex. %s",
                        fichier.stem,
                        test.nom,
                        test.severite,
                        len(rows),
                        rows[0],
                    )
        if nb_anomalies:
            logger.warning(
                "[qualite] %d/%d test(s) en anomalie", nb_anomalies, nb_tests
            )
        else:
            logger.info("[qualite] %d test(s) exécutés, aucune anomalie", nb_tests)
    except Exception:
        logger.error("[qualite] échec de la campagne de tests — ignorée", exc_info=True)
