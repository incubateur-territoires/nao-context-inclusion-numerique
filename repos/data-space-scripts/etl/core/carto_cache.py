"""Reset du cache de la cartographie nationale après modification de lieux —
fonctions pures (fiche 16 FCIS). Le shell Airflow vit dans
``carto-cache-reset-lieux-modifies-dag.py`` et ``carto-cache-reset-dag.py``.

Watermark = instant du dernier reset RÉUSSI, quel que soit le déclencheur
(coop-dag, carto-dag-import, aidants-connect-dag ou le DAG planifié) : posé
par la tâche ``reset_carto_cache`` dans une Variable Airflow, faute de pouvoir
lire les DagRuns d'un autre DAG depuis une tâche en Airflow 3 (pas d'accès ORM
au métastore, et le Task SDK n'expose pas leurs dates de fin).

Fuseaux : ``updated_at_min`` / ``updated_at_coop`` sont des ``timestamp
without time zone`` écrits en UTC (Prisma sérialise tout ``DateTime`` en UTC,
MIN et coop écrivent ``new Date()``). Le watermark est stocké en ISO 8601 avec
décalage explicite, puis converti en UTC NAÏF pour la comparaison : aucune
dépendance au ``TimeZone`` de session PostgreSQL.
"""

from datetime import datetime
from datetime import timedelta
from datetime import timezone

VARIABLE_DERNIER_RESET = "CARTO_CACHE_RESET_DERNIER_SUCCES"

# Espacement minimal entre un reset quelconque et celui que déclencherait le
# DAG planifié. Inférieur à la période du DAG (10 min) pour que des éditions
# continues donnent un reset par tick, et non un tick sur deux (le watermark
# est posé quelques secondes APRÈS le début du tick qui a déclenché).
INTERVALLE_MINIMUM = timedelta(minutes=5)

# Seules les écritures MIN et coop (double écriture) sont surveillées : l'import
# carto (updated_at_carto) déclenche déjà son propre reset. Les suppressions et
# masquages MIN posent updated_at_min (et visible_pour_cartographie_nationale =
# false), les retraits/dépublications coop posent updated_at_coop : couverts.
# Pas d'index : seq scan de ~24 k lignes, ~10-20 ms, 144 fois par jour.
SQL_LIEU_MODIFIE_DEPUIS = """
SELECT 1
FROM main.lieu_inclusion
WHERE updated_at_min > %(depuis)s
   OR updated_at_coop > %(depuis)s
LIMIT 1
"""


def serialiser_watermark(instant: datetime) -> str:
    """Horodatage ISO 8601 en UTC, décalage explicite (valeur de la Variable)."""
    if instant.tzinfo is None:
        raise ValueError("instant naïf refusé : fuseau ambigu")
    return instant.astimezone(timezone.utc).isoformat()


def lire_watermark(valeur: str | None) -> datetime | None:
    """Watermark en UTC naïf (comparable aux colonnes ``timestamp without time
    zone`` écrites en UTC), ou None si absent / illisible / sans fuseau."""
    if not valeur:
        return None
    try:
        instant = datetime.fromisoformat(valeur)
    except ValueError:
        return None
    if instant.tzinfo is None:
        return None
    return instant.astimezone(timezone.utc).replace(tzinfo=None)


def trop_tot_pour_reset(watermark: datetime, maintenant: datetime) -> bool:
    """Vrai si le dernier reset est trop récent (``maintenant`` aware)."""
    maintenant_utc = maintenant.astimezone(timezone.utc).replace(tzinfo=None)
    return maintenant_utc - watermark < INTERVALLE_MINIMUM
