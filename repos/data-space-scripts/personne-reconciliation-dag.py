"""DAG personne-reconciliation — successeur strict des DAGs similarities (N13, #1824).

Deux responsabilités, chaque jour après la chaîne d'ingest (carto 01:00,
AC 05:00, coop 08:00) :

1. ``detecter_doublons_intra_source`` : photographie (TRUNCATE + INSERT) des
   doublons INTRA-source dans ``dataviz.personne_doublons_intra_source`` —
   deux identifiants distincts de la même source pour le même nom normalisé
   sur la même structure administrative. Non fusionnables côté entrepôt
   (comptes recréés à l'import suivant, constaté sur 277/640 fusions de
   l'ancien DAG) : à résoudre à la source.

2. ``fusionner_complementaires`` : fusion automatique des paires à sources
   strictement COMPLÉMENTAIRES, sous gardes strictes (cf. #1824) :
   - nom + prénom identiques après normalisation (unaccent/lower/trim) —
     pas de fuzzy ;
   - affectation d'emploi ACTIVE sur la même structure administrative des
     deux côtés (garde bien plus stricte que le "même commune" historique) ;
   - aucun chevauchement de sources (jamais deux coop_id / cn_pg_id /
     conseiller_numerique_id / aidant_connect_id) → aucun identifiant perdu ;
   - paire non ambiguë : aucune des deux personnes n'apparaît dans une autre
     paire candidate ni dans un doublon intra-source détecté.
   Winner = la ligne portant le plus d'identifiants source (à égalité :
   celle qui a un coop_id, puis la plus récemment mise à jour). Fusion
   journalisée dans ``audit.personne_merge_log`` (match_type
   'complementaire_meme_sa'), même mécanique que le curatif du 18/08
   (scripts/fusion_homonymes_ac_coop_1582.sql).
"""
from datetime import datetime

from airflow import DAG
from airflow.models import Variable
from airflow.providers.common.sql.operators.sql import SQLExecuteQueryOperator
from airflow.sdk import Param

from mattermost_notifier import MattermostNotifier

default_args = {"start_date": datetime(2026, 8, 18), "catchup": False}

webhook = Variable.get("MATTERMOST_WEBHOOK_URI")
channel = Variable.get("MATTERMOST_NOTIFICATION_CHANNEL")

notifier = MattermostNotifier(
    webhook_url=webhook,
    default_channel=channel,
)


def dag_success_callback(context):
    notifier.notify(context, "DAG", "SUCCESS")


def dag_failure_callback(context):
    notifier.notify(context, "DAG", "FAILURE")


# Population commune aux deux tâches : personnes actives (non supprimées),
# nom/prénom renseignés, avec leurs affectations d'emploi actives.
_BASE_CTE = """
        base AS (
            SELECT DISTINCT
                p.id,
                p.prenom,
                p.nom,
                lower(public.unaccent(btrim(p.nom)))    AS nom_n,
                lower(public.unaccent(btrim(p.prenom))) AS prenom_n,
                p.aidant_connect_id,
                p.coop_id,
                p.cn_pg_id,
                p.conseiller_numerique_id,
                COALESCE(p.updated_at, p.created_at)    AS ts,
                pae.structure_administrative_id         AS sa_id
            FROM main.personne p
            JOIN main.personne_affectations_emploi pae
              ON pae.personne_id = p.id AND pae.est_active
            WHERE p.deleted_at IS NULL
              AND p.nom IS NOT NULL
              AND p.prenom IS NOT NULL
        )
"""

with DAG(
    "personne-reconciliation",
    default_args=default_args,
    on_failure_callback=dag_failure_callback,
    on_success_callback=dag_success_callback,
    description=(
        "Détecte les doublons de personnes intra-source (liste dataviz) et "
        "fusionne automatiquement les paires cross-source strictement "
        "complémentaires sur la même structure administrative (#1824)."
    ),
    params={
        "db_conn_id": Param(
            default="sonum-prod-db",
            type="string",
            enum=["sonum-test-db", "sonum-dev-db", "sonum-prod-db"],
            title="Airflow DB connection id",
            description="Identifiant Airflow de la connexion à la base de données PostgreSQL.",
        ),
        "fusion_activee": Param(
            True,
            type="boolean",
            title="Fusion automatique activée",
            description="Si False, seule la détection intra-source tourne (aucune écriture main).",
        ),
    },
    schedule="0 11 * * *",
    tags=["personne", "reconciliation", "doublons"],
) as dag:
    detecter_doublons_intra_source = SQLExecuteQueryOperator(
        task_id="detecter_doublons_intra_source",
        conn_id="{{ params['db_conn_id'] }}",
        sql=f"""
        BEGIN;
        TRUNCATE dataviz.personne_doublons_intra_source;
        WITH
        {_BASE_CTE},
        intra AS (
            SELECT 'aidants-connect' AS source,
                   b1.id AS personne_id_1, b2.id AS personne_id_2,
                   b1.aidant_connect_id::text AS source_id_1,
                   b2.aidant_connect_id::text AS source_id_2,
                   b1.prenom, b1.nom, b1.sa_id
            FROM base b1
            JOIN base b2 ON b1.id < b2.id
              AND b1.sa_id = b2.sa_id
              AND b1.nom_n = b2.nom_n AND b1.prenom_n = b2.prenom_n
            WHERE b1.aidant_connect_id IS NOT NULL AND b2.aidant_connect_id IS NOT NULL
            UNION
            SELECT 'coop',
                   b1.id, b2.id, b1.coop_id::text, b2.coop_id::text,
                   b1.prenom, b1.nom, b1.sa_id
            FROM base b1
            JOIN base b2 ON b1.id < b2.id
              AND b1.sa_id = b2.sa_id
              AND b1.nom_n = b2.nom_n AND b1.prenom_n = b2.prenom_n
            WHERE b1.coop_id IS NOT NULL AND b2.coop_id IS NOT NULL
            UNION
            SELECT 'conseiller-numerique',
                   b1.id, b2.id,
                   COALESCE(b1.cn_pg_id::text, b1.conseiller_numerique_id::text),
                   COALESCE(b2.cn_pg_id::text, b2.conseiller_numerique_id::text),
                   b1.prenom, b1.nom, b1.sa_id
            FROM base b1
            JOIN base b2 ON b1.id < b2.id
              AND b1.sa_id = b2.sa_id
              AND b1.nom_n = b2.nom_n AND b1.prenom_n = b2.prenom_n
            WHERE (b1.cn_pg_id IS NOT NULL OR b1.conseiller_numerique_id IS NOT NULL)
              AND (b2.cn_pg_id IS NOT NULL OR b2.conseiller_numerique_id IS NOT NULL)
        )
        INSERT INTO dataviz.personne_doublons_intra_source
            (source, personne_id_1, personne_id_2, source_id_1, source_id_2,
             prenom, nom, structure_administrative_id, denomination_structure)
        SELECT DISTINCT i.source, i.personne_id_1, i.personne_id_2,
               i.source_id_1, i.source_id_2, i.prenom, i.nom, i.sa_id,
               COALESCE(sa.denomination_sirene, sa.denomination_antenne)
        FROM intra i
        JOIN main.structure_administrative sa ON sa.id = i.sa_id;
        COMMIT;
        """,
    )

    fusionner_complementaires = SQLExecuteQueryOperator(
        task_id="fusionner_complementaires",
        conn_id="{{ params['db_conn_id'] }}",
        sql=f"""
        {{% if params.fusion_activee %}}
        DO $$
        DECLARE
            pair record;
            p_winner main.personne;
            p_loser  main.personne;
            p_tmp    main.personne;
            n_ok int := 0;
        BEGIN
            CREATE TEMPORARY TABLE tmp_paires ON COMMIT DROP AS
            WITH
            {_BASE_CTE},
            candidates AS (
                SELECT DISTINCT least(b1.id, b2.id) AS id_a, greatest(b1.id, b2.id) AS id_b
                FROM base b1
                JOIN base b2 ON b1.id < b2.id
                  AND b1.sa_id = b2.sa_id
                  AND b1.nom_n = b2.nom_n AND b1.prenom_n = b2.prenom_n
                -- cross-source : chaque côté porte au moins un identifiant source
                WHERE (b1.aidant_connect_id IS NOT NULL OR b1.coop_id IS NOT NULL
                       OR b1.cn_pg_id IS NOT NULL OR b1.conseiller_numerique_id IS NOT NULL)
                  AND (b2.aidant_connect_id IS NOT NULL OR b2.coop_id IS NOT NULL
                       OR b2.cn_pg_id IS NOT NULL OR b2.conseiller_numerique_id IS NOT NULL)
                -- complémentarité stricte : aucun identifiant du même type des deux côtés
                  AND NOT (b1.aidant_connect_id       IS NOT NULL AND b2.aidant_connect_id       IS NOT NULL)
                  AND NOT (b1.coop_id                 IS NOT NULL AND b2.coop_id                 IS NOT NULL)
                  AND NOT (b1.cn_pg_id                IS NOT NULL AND b2.cn_pg_id                IS NOT NULL)
                  AND NOT (b1.conseiller_numerique_id IS NOT NULL AND b2.conseiller_numerique_id IS NOT NULL)
            ),
            -- garde d'ambiguïté : une personne présente dans plusieurs paires
            -- candidates ou dans un doublon intra-source détecté ce run est exclue
            ambigus AS (
                SELECT id FROM (
                    SELECT id_a AS id FROM candidates
                    UNION ALL SELECT id_b FROM candidates
                ) t GROUP BY id HAVING count(*) > 1
                UNION
                SELECT personne_id_1 FROM dataviz.personne_doublons_intra_source
                UNION
                SELECT personne_id_2 FROM dataviz.personne_doublons_intra_source
            )
            SELECT id_a, id_b FROM candidates c
            WHERE NOT EXISTS (SELECT 1 FROM ambigus a WHERE a.id IN (c.id_a, c.id_b));

            FOR pair IN SELECT id_a, id_b FROM tmp_paires ORDER BY id_a LOOP
                SELECT * INTO p_winner FROM main.personne WHERE id = pair.id_a FOR UPDATE;
                SELECT * INTO p_loser  FROM main.personne WHERE id = pair.id_b FOR UPDATE;

                -- winner = plus d'identifiants source ; égalité : coop_id, puis plus récent
                IF ROW(  (p_loser.aidant_connect_id IS NOT NULL)::int + (p_loser.coop_id IS NOT NULL)::int
                       + (p_loser.cn_pg_id IS NOT NULL)::int + (p_loser.conseiller_numerique_id IS NOT NULL)::int,
                         (p_loser.coop_id IS NOT NULL)::int,
                         COALESCE(p_loser.updated_at, p_loser.created_at))
                   > ROW((p_winner.aidant_connect_id IS NOT NULL)::int + (p_winner.coop_id IS NOT NULL)::int
                       + (p_winner.cn_pg_id IS NOT NULL)::int + (p_winner.conseiller_numerique_id IS NOT NULL)::int,
                         (p_winner.coop_id IS NOT NULL)::int,
                         COALESCE(p_winner.updated_at, p_winner.created_at)) THEN
                    p_tmp := p_winner; p_winner := p_loser; p_loser := p_tmp;
                END IF;

                -- 1. Transfert des identifiants et attributs (aucun chevauchement possible ici)
                UPDATE main.personne SET
                    aidant_connect_id = NULL, coop_id = NULL,
                    cn_pg_id = NULL, conseiller_numerique_id = NULL
                WHERE id = p_loser.id;

                UPDATE main.personne SET
                    aidant_connect_id       = COALESCE(p_winner.aidant_connect_id, p_loser.aidant_connect_id),
                    coop_id                 = COALESCE(p_winner.coop_id, p_loser.coop_id),
                    cn_pg_id                = COALESCE(p_winner.cn_pg_id, p_loser.cn_pg_id),
                    conseiller_numerique_id = COALESCE(p_winner.conseiller_numerique_id, p_loser.conseiller_numerique_id),
                    nb_accompagnements_ac   = COALESCE(p_winner.nb_accompagnements_ac, p_loser.nb_accompagnements_ac),
                    profession_ac           = COALESCE(p_winner.profession_ac, p_loser.profession_ac),
                    formation_fne_ac        = COALESCE(p_winner.formation_fne_ac, p_loser.formation_fne_ac),
                    is_referent_ac          = COALESCE(p_winner.is_referent_ac, p_loser.is_referent_ac),
                    is_mediateur            = COALESCE(p_winner.is_mediateur, p_loser.is_mediateur),
                    is_coordinateur         = COALESCE(p_winner.is_coordinateur, p_loser.is_coordinateur),
                    is_visible              = CASE
                        WHEN p_winner.is_visible = FALSE OR p_loser.is_visible = FALSE THEN FALSE
                        ELSE COALESCE(p_winner.is_visible, p_loser.is_visible)
                    END,
                    contact                 = COALESCE(p_loser.contact, '{{}}'::jsonb)
                                              || COALESCE(p_winner.contact, '{{}}'::jsonb),
                    updated_at_ac           = GREATEST(p_winner.updated_at_ac, p_loser.updated_at_ac),
                    updated_at_coop         = GREATEST(p_winner.updated_at_coop, p_loser.updated_at_coop),
                    updated_at_idposte      = GREATEST(p_winner.updated_at_idposte, p_loser.updated_at_idposte)
                WHERE id = p_winner.id;

                -- 2. Re-pointage des FK (dédup préalable sur chaque clé unique,
                --    en conservant l'activité : est_active OR)
                UPDATE main.personne_affectations_emploi w
                SET est_active = w.est_active OR l.est_active
                FROM main.personne_affectations_emploi l
                WHERE w.personne_id = p_winner.id AND l.personne_id = p_loser.id
                  AND w.structure_administrative_id = l.structure_administrative_id
                  AND w.source = l.source;
                DELETE FROM main.personne_affectations_emploi l
                USING main.personne_affectations_emploi w
                WHERE l.personne_id = p_loser.id AND w.personne_id = p_winner.id
                  AND l.structure_administrative_id = w.structure_administrative_id
                  AND l.source = w.source;
                UPDATE main.personne_affectations_emploi
                SET personne_id = p_winner.id WHERE personne_id = p_loser.id;

                UPDATE main.personne_affectations_lieu w
                SET est_active = w.est_active OR l.est_active
                FROM main.personne_affectations_lieu l
                WHERE w.personne_id = p_winner.id AND l.personne_id = p_loser.id
                  AND w.lieu_id = l.lieu_id AND w.source = l.source;
                DELETE FROM main.personne_affectations_lieu l
                USING main.personne_affectations_lieu w
                WHERE l.personne_id = p_loser.id AND w.personne_id = p_winner.id
                  AND l.lieu_id = w.lieu_id AND l.source = w.source;
                UPDATE main.personne_affectations_lieu
                SET personne_id = p_winner.id WHERE personne_id = p_loser.id;

                DELETE FROM main.poste l
                USING main.poste w
                WHERE l.personne_id = p_loser.id AND w.personne_id = p_winner.id
                  AND l.poste_conum_id IS NOT DISTINCT FROM w.poste_conum_id
                  AND l.structure_id   IS NOT DISTINCT FROM w.structure_id;
                UPDATE main.poste     SET personne_id = p_winner.id WHERE personne_id = p_loser.id;
                UPDATE main.contrat   SET personne_id = p_winner.id WHERE personne_id = p_loser.id;
                UPDATE main.formation SET personne_id = p_winner.id WHERE personne_id = p_loser.id;

                DELETE FROM main.coordination_mediation l
                USING main.coordination_mediation w
                WHERE l.mediateur_id = p_loser.id AND w.mediateur_id = p_winner.id
                  AND l.coordinateur_id = w.coordinateur_id
                  AND COALESCE(l.suppression, '1234-01-02 03:04:05+00') = COALESCE(w.suppression, '1234-01-02 03:04:05+00');
                UPDATE main.coordination_mediation
                SET mediateur_id = p_winner.id WHERE mediateur_id = p_loser.id;
                DELETE FROM main.coordination_mediation l
                USING main.coordination_mediation w
                WHERE l.coordinateur_id = p_loser.id AND w.coordinateur_id = p_winner.id
                  AND l.mediateur_id = w.mediateur_id
                  AND COALESCE(l.suppression, '1234-01-02 03:04:05+00') = COALESCE(w.suppression, '1234-01-02 03:04:05+00');
                UPDATE main.coordination_mediation
                SET coordinateur_id = p_winner.id WHERE coordinateur_id = p_loser.id;

                -- 3. Suppression du loser + journal
                DELETE FROM main.personne WHERE id = p_loser.id;

                INSERT INTO audit.personne_merge_log
                    (status, match_type, dag_id, run_id, task_id,
                     winner_id, loser_id, winner_before, loser_before,
                     winner_after, moved_identifiers)
                SELECT 'SUCCESS', 'complementaire_meme_sa',
                       '{{{{ dag.dag_id }}}}', '{{{{ run_id }}}}', '{{{{ ti.task_id }}}}',
                       p_winner.id, p_loser.id,
                       to_jsonb(p_winner), to_jsonb(p_loser), to_jsonb(p),
                       jsonb_strip_nulls(jsonb_build_object(
                           'aidant_connect_id', p_loser.aidant_connect_id,
                           'coop_id', p_loser.coop_id,
                           'cn_pg_id', p_loser.cn_pg_id,
                           'conseiller_numerique_id', p_loser.conseiller_numerique_id))
                FROM main.personne p WHERE p.id = p_winner.id;

                n_ok := n_ok + 1;
                RAISE NOTICE 'MERGE winner=% loser=% ok', p_winner.id, p_loser.id;
            END LOOP;

            RAISE NOTICE 'personne-reconciliation : % fusions complémentaires', n_ok;
        END $$;
        {{% else %}}
        SELECT 'fusion désactivée par le paramètre fusion_activee';
        {{% endif %}}
        """,
    )

    detecter_doublons_intra_source >> fusionner_complementaires
