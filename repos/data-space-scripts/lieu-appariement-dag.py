"""DAG lieu-appariement — matching maison lieux coop ↔ records mednum (SEPT #1724, étape 3).

Alimente ``main.lieu_appariement`` (V152), la mémoire durable du rapprochement
entre les lieux gérés par la coop et les records du fichier national mednum
(silver ``staging.carto__structures``, reconstruit à chaque run du carto-dag).
Même famille que ``personne-reconciliation`` (N13).

Deux tâches, idempotentes sur le silver courant :

1. ``apparier_segments_coop`` : preuve par les segments d'id. Un record
   fusionné « Coop-numérique_<uuid>__France-Services_789 » prouve que CHAQUE
   segment de son id (dont France-Services_789) décrit le lieu coop <uuid>.
   Chaque segment est upserté avec statut 'auto'. Cette mémoire survit au
   retrait futur de la coop des sources mednum : le record redevenu
   « France-Services_789 » restera rattaché au lieu.

2. ``detecter_similarites`` : candidats entre records PUREMENT externes
   (sans segment coop) et lieux coop de la même commune, scorés
   nom/adresse/distance (repris de mednum-cli find-duplicates : moyenne des
   composantes disponibles, seuil inter-sources 83). Les candidats partent
   en file de revue humaine ('a_valider' → ``dataviz.lieu_appariements_a_valider``).
   Résorbe les ~360 doublons coop ↔ externe jamais fusionnés par mednum.

Invariants :
- les décisions humaines ('valide', 'rejete') ne sont JAMAIS écrasées ;
- une paire absente du silver courant n'est pas supprimée (mémoire) — seule
  ``derniere_detection`` cesse d'avancer ;
- les lignes dont le lieu a disparu (GC, fusion) sont purgées en fin de run.
"""
import datetime

import pendulum
from airflow import DAG
from airflow.models import Variable
from airflow.providers.common.sql.operators.sql import SQLExecuteQueryOperator
from airflow.providers.standard.operators.python import PythonOperator
from airflow.sdk import Param

from mattermost_notifier import MattermostNotifier

default_args = {
    "owner": "airflow",
    "retries": 2,
    "retry_delay": datetime.timedelta(minutes=5),
}

webhook = Variable.get("MATTERMOST_WEBHOOK_URI")
channel = Variable.get("MATTERMOST_NOTIFICATION_CHANNEL")

notifier = MattermostNotifier(webhook_url=webhook, default_channel=channel)


def dag_success_callback(context):
    notifier.notify(context, "DAG", "SUCCESS")


def dag_failure_callback(context):
    notifier.notify(context, "DAG", "FAILURE")


# Segment coop STRICT (aligné carto-dag-import.py) : « Coop-numérique_<uuid> »
# en début d'id ou précédé de « __ » — « Numi_Coop-numérique_x » est un id
# Numi, jamais un segment coop.
_COOP_SEG_RX = (
    r"(?:^|__)Coop-numérique_"
    r"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(?:__|$)"
)

with DAG(
    dag_id="lieu-appariement",
    default_args=default_args,
    start_date=pendulum.datetime(2026, 8, 19, tz="Europe/Paris"),
    catchup=False,
    max_active_runs=1,
    on_failure_callback=dag_failure_callback,
    on_success_callback=dag_success_callback,
    description=(
        "Mémoire d'appariement lieux coop ↔ records mednum : preuve par "
        "segments d'id + candidats par similarité (file de revue humaine). "
        "SEPT #1724, étape 3."
    ),
    # Quotidien après la chaîne d'ingest (carto 01:00, coop 08:00) et la
    # réconciliation personnes (11:00). Idempotent : rejouable à la demande
    # après un run manuel du carto-dag.
    schedule="0 12 * * *",
    tags=["carto", "coop", "lieu", "appariement"],
    params={
        "db_conn_id": Param(
            default="sonum-prod-db",
            type="string",
            enum=["sonum-test-db", "sonum-dev-db", "sonum-prod-db"],
            title="Airflow DB connection id",
            description="Identifiant Airflow de la connexion à la base de données PostgreSQL.",
        ),
        "seuil_score": Param(
            default=83,
            type="integer",
            minimum=50,
            maximum=100,
            title="Seuil de score global (similarité)",
            description=(
                "Score minimal (0-100) pour retenir un candidat en file de "
                "revue. 83 = seuil inter-sources de mednum-cli."
            ),
        ),
    },
) as dag:
    def _reconcilier_identites_coop(**kwargs):
        """Filet de réconciliation du contrat d'écriture synchrone (SEPT
        #1724) : tout lieu coop actif sans ligne d'identité au registre en
        reçoit une (adresse résolue par main.trouver_ou_creer_adresse_lieu).
        Chemin nominal = l'app coop écrit à la création ; ce filet répare les
        trous et les signale. Couvre aussi la transition (tant que l'app coop
        n'écrit pas encore, il joue le rôle de l'ancien ingest_structures)."""
        import logging

        from airflow.providers.postgres.hooks.postgres import PostgresHook

        hook = PostgresHook(postgres_conn_id=kwargs["params"]["db_conn_id"])
        conn = hook.get_conn()
        try:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    INSERT INTO main.lieu_inclusion
                        (structure_coop_id, adresse_id, nom, edited_by, updated_at_coop)
                    SELECT cl.id,
                           main.trouver_ou_creer_adresse_lieu(
                               cl.adresse, cl.code_postal, cl.commune,
                               cl.code_insee, cl.latitude, cl.longitude, cl.ban_id),
                           cl.nom, 'coop', cl.modification
                    FROM coop.lieu_inclusion cl
                    WHERE cl.suppression IS NULL
                      AND cl.code_insee IS NOT NULL AND btrim(cl.code_insee) <> ''
                      AND cl.code_postal IS NOT NULL AND btrim(cl.code_postal) <> ''
                      AND cl.commune IS NOT NULL AND btrim(cl.commune) <> ''
                      AND NOT EXISTS (
                          SELECT 1 FROM main.lieu_inclusion r
                          WHERE r.structure_coop_id = cl.id)
                    ON CONFLICT (structure_coop_id) DO NOTHING
                    """
                )
                repares = cur.rowcount
                cur.execute(
                    """
                    SELECT count(*) FROM coop.lieu_inclusion cl
                    WHERE cl.suppression IS NULL
                      AND (cl.code_insee IS NULL OR btrim(cl.code_insee) = ''
                           OR cl.code_postal IS NULL OR btrim(cl.code_postal) = ''
                           OR cl.commune IS NULL OR btrim(cl.commune) = '')
                      AND NOT EXISTS (
                          SELECT 1 FROM main.lieu_inclusion r
                          WHERE r.structure_coop_id = cl.id)
                    """
                )
                (inreparables,) = cur.fetchone()
            conn.commit()
        finally:
            conn.close()
        logging.info(
            "Réconciliation identités coop : %s ligne(s) registre créée(s).", repares
        )
        if repares:
            logging.warning(
                "%s lieu(x) coop sans ligne registre réparé(s) — le chemin "
                "d'écriture synchrone coop a-t-il raté ?", repares,
            )
        if inreparables:
            logging.warning(
                "%s lieu(x) coop SANS adresse exploitable (code_insee/cp/commune "
                "manquant) : non enregistrables, à remonter à la coop.", inreparables,
            )

    reconcilier_identites_coop = PythonOperator(
        task_id="reconcilier_identites_coop",
        python_callable=_reconcilier_identites_coop,
    )

    apparier_segments_coop = SQLExecuteQueryOperator(
        task_id="apparier_segments_coop",
        conn_id="{{ params['db_conn_id'] }}",
        sql=f"""
        BEGIN;
        WITH records AS (
            SELECT c.id AS record_id, c.source, c.nom, c.adresse, c.commune,
                   COALESCE(
                       c.structure_coop_id,
                       (regexp_match(c.id, '{_COOP_SEG_RX}'))[1]::uuid
                   ) AS coop_uuid
            FROM staging.carto__structures c
            WHERE c.id <> ''
        ),
        avec_lieu AS (
            SELECT r.*, l.id AS lieu_id
            FROM records r
            JOIN main.lieu_inclusion l ON l.structure_coop_id = r.coop_uuid
            WHERE r.coop_uuid IS NOT NULL
        ),
        segments AS (
            SELECT DISTINCT ON (seg, a.lieu_id)
                   seg AS carto_segment, a.lieu_id, a.record_id, a.source,
                   a.nom, a.adresse, a.commune
            FROM avec_lieu a,
                 LATERAL unnest(string_to_array(a.record_id, '__')) AS seg
            WHERE seg <> ''
            ORDER BY seg, a.lieu_id, a.record_id
        )
        INSERT INTO main.lieu_appariement
            (carto_segment, lieu_id, carto_record_id, source, methode, statut,
             carto_nom, carto_adresse, carto_commune)
        SELECT carto_segment, lieu_id, record_id, source, 'segment_coop',
               'auto', nom, adresse, commune
        FROM segments
        ON CONFLICT (carto_segment, lieu_id) DO UPDATE SET
            carto_record_id = EXCLUDED.carto_record_id,
            source          = EXCLUDED.source,
            carto_nom       = EXCLUDED.carto_nom,
            carto_adresse   = EXCLUDED.carto_adresse,
            carto_commune   = EXCLUDED.carto_commune,
            methode         = 'segment_coop',
            derniere_detection = now(),
            -- la preuve par segment promeut un candidat en 'auto', mais ne
            -- renverse jamais une décision humaine (une fusion mednum peut
            -- être fausse)
            statut = CASE WHEN main.lieu_appariement.statut IN ('valide', 'rejete')
                          THEN main.lieu_appariement.statut
                          ELSE 'auto' END;
        COMMIT;
        """,
    )

    detecter_similarites = SQLExecuteQueryOperator(
        task_id="detecter_similarites",
        conn_id="{{ params['db_conn_id'] }}",
        sql=f"""
        BEGIN;
        WITH externes AS (
            -- records purement externes : ni structure_coop_id ni segment coop
            SELECT c.id AS record_id, c.source, c.nom, c.adresse, c.commune,
                   c.code_insee, c.longitude, c.latitude
            FROM staging.carto__structures c
            WHERE c.id <> ''
              AND c.nom IS NOT NULL AND c.nom <> ''
              AND c.code_insee IS NOT NULL AND c.code_insee <> ''
              AND c.structure_coop_id IS NULL
              AND c.id !~ '{_COOP_SEG_RX}'
        ),
        lieux_coop AS (
            SELECT l.id AS lieu_id, l.nom, a.code_insee,
                   a.numero_voie, a.nom_voie, a.geom
            FROM main.lieu_inclusion l
            JOIN main.adresse a ON a.id = l.adresse_id
            WHERE l.structure_coop_id IS NOT NULL
              AND l.deleted_at IS NULL
              AND l.nom IS NOT NULL
        ),
        -- blocking par commune (code_insee), puis score par composante,
        -- repris de mednum-cli find-duplicates : moyenne des composantes
        -- disponibles (nom toujours ; adresse et distance si présentes)
        scores AS (
            SELECT e.record_id, e.source, e.nom AS carto_nom,
                   e.adresse AS carto_adresse, e.commune AS carto_commune,
                   lc.lieu_id,
                   round(public.similarity(
                       lower(public.unaccent(e.nom)),
                       lower(public.unaccent(lc.nom))) * 100)::smallint AS score_nom,
                   CASE WHEN e.adresse <> '' AND lc.nom_voie IS NOT NULL THEN
                       round(public.similarity(
                           lower(public.unaccent(e.adresse)),
                           lower(public.unaccent(concat_ws(' ',
                               lc.numero_voie::text, lc.nom_voie)))) * 100)::smallint
                   END AS score_adresse,
                   CASE WHEN e.longitude IS NOT NULL AND e.latitude IS NOT NULL
                             AND lc.geom IS NOT NULL THEN
                       round(public.ST_Distance(
                           lc.geom::public.geography,
                           public.ST_SetSRID(public.ST_MakePoint(
                               e.longitude, e.latitude), 4326)::public.geography
                       ))::integer
                   END AS distance_m
            FROM externes e
            JOIN lieux_coop lc ON lc.code_insee = e.code_insee
        ),
        candidats AS (
            SELECT s.*,
                   -- 100 à 0 m, 0 à 1 km (linéaire) — proxy simple de la
                   -- composante distance de mednum-cli
                   CASE WHEN s.distance_m IS NOT NULL THEN
                       GREATEST(0, 100 - s.distance_m / 10)::smallint
                   END AS score_distance
            FROM scores s
        ),
        retenus AS (
            SELECT c.*,
                   round(
                       (c.score_nom
                        + COALESCE(c.score_adresse, 0)
                        + COALESCE(c.score_distance, 0))::numeric
                       / (1 + (c.score_adresse IS NOT NULL)::int
                            + (c.score_distance IS NOT NULL)::int)
                   )::smallint AS score_global
            FROM candidats c
        ),
        segments AS (
            SELECT DISTINCT ON (seg, r.lieu_id)
                   seg AS carto_segment, r.*
            FROM retenus r,
                 LATERAL unnest(string_to_array(r.record_id, '__')) AS seg
            WHERE r.score_global >= {{{{ params['seuil_score'] }}}}
              AND seg <> ''
            ORDER BY seg, r.lieu_id, r.score_global DESC
        )
        INSERT INTO main.lieu_appariement
            (carto_segment, lieu_id, carto_record_id, source, methode, statut,
             score_nom, score_adresse, score_distance, score_global,
             distance_m, carto_nom, carto_adresse, carto_commune)
        SELECT carto_segment, lieu_id, record_id, source, 'similarite',
               'a_valider', score_nom, score_adresse, score_distance,
               score_global, distance_m, carto_nom, carto_adresse,
               carto_commune
        FROM segments
        ON CONFLICT (carto_segment, lieu_id) DO UPDATE SET
            carto_record_id = EXCLUDED.carto_record_id,
            source          = EXCLUDED.source,
            score_nom       = EXCLUDED.score_nom,
            score_adresse   = EXCLUDED.score_adresse,
            score_distance  = EXCLUDED.score_distance,
            score_global    = EXCLUDED.score_global,
            distance_m      = EXCLUDED.distance_m,
            carto_nom       = EXCLUDED.carto_nom,
            carto_adresse   = EXCLUDED.carto_adresse,
            carto_commune   = EXCLUDED.carto_commune,
            derniere_detection = now();
            -- statut et methode volontairement préservés : un candidat déjà
            -- promu ('auto' par preuve de segment) ou tranché par un humain
            -- ('valide'/'rejete') n'est jamais rétrogradé en 'a_valider'

        -- Purge des lignes dont le lieu a disparu (GC, fusion de lieux)
        DELETE FROM main.lieu_appariement la
        WHERE NOT EXISTS (
            SELECT 1 FROM main.lieu_inclusion l WHERE l.id = la.lieu_id
        );
        COMMIT;
        """,
    )

    def _bilan_appariement(**kwargs):
        """Logge les chiffres du run (les SQLExecuteQueryOperator n'en loggent
        aucun) : totaux par méthode/statut, taille de la file de revue,
        nouvelles paires détectées aujourd'hui."""
        import logging

        from airflow.providers.postgres.hooks.postgres import PostgresHook

        hook = PostgresHook(postgres_conn_id=kwargs["params"]["db_conn_id"])
        totaux = hook.get_records(
            """
            SELECT methode, statut, count(*),
                   count(DISTINCT lieu_id),
                   count(*) FILTER (WHERE premiere_detection::date = current_date)
            FROM main.lieu_appariement
            GROUP BY 1, 2 ORDER BY 1, 2
            """
        )
        for methode, statut, paires, lieux, nouvelles in totaux:
            logging.info(
                "lieu_appariement %s/%s : %s paires (%s lieux), %s nouvelles aujourd'hui",
                methode, statut, paires, lieux, nouvelles,
            )
        (file_revue,) = hook.get_first(
            "SELECT count(*) FROM dataviz.lieu_appariements_a_valider"
        )
        logging.info("File de revue humaine : %s candidats à valider", file_revue)

    bilan_appariement = PythonOperator(
        task_id="bilan_appariement",
        python_callable=_bilan_appariement,
    )

    reconcilier_identites_coop >> apparier_segments_coop >> detecter_similarites >> bilan_appariement
