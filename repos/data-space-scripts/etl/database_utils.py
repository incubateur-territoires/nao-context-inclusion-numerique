import logging

import numpy as np
import pandas as pd
import psycopg2.errors
from airflow.providers.postgres.hooks.postgres import PostgresHook
from sqlalchemy.dialects.postgresql import insert

DTYPE_CARTO = {
    "id": str,
    "structure_coop_id": str,
    "pivot": str,
    "nom": str,
    "commune": str,
    "code_postal": str,
    "code_insee": str,
    "adresse": str,
    "complement_adresse": str,
    "latitude": float,
    "longitude": float,
    "typologie": str,
    "telephone": str,
    "courriels": str,
    "site_web": str,
    "horaires": str,
    "presentation_resume": str,
    "presentation_detail": str,
    "source": str,
    "itinerance": str,
    "date_maj": str,
    "services": str,
    "publics_specifiquement_adresses": str,
    "prise_en_charge_specifique": str,
    "frais_a_charge": str,
    "dispositif_programmes_nationaux": str,
    "formations_labels": str,
    "autres_formations_labels": str,
    "modalites_acces": str,
    "modalites_accompagnement": str,
    "fiche_acces_libre": str,
    "prise_rdv": str,
}


def query_postgres(
    query: str,
    params: dict = None,
    conn_id: str = "sonum-prod-db",
) -> pd.DataFrame:
    """
    Generic function to query the main database.

    Args:
        query: SQL query to execute.
        params: Dictionary of parameters for the SQL query.
        conn_id: Airflow Postgres DB connection id. Default is "sonum-prod-db".

    Returns:
        DataFrame containing the result of the query.
    """
    hook = PostgresHook(postgres_conn_id=conn_id)
    df = hook.get_pandas_df(sql=query, parameters=params)
    return df


def insert_on_conflict_nothing(table, conn, keys, data_iter):
    data = [dict(zip(keys, row)) for row in data_iter]
    if not data:
        return 0

    stmt = insert(table.table).values(data)
    if str(table.table.name) == "structure":
        try:
            stmt = stmt.on_conflict_do_nothing(
                index_elements=["id_structure_ac"],
            )
            result = conn.execute(stmt)
            return result.rowcount
        except psycopg2.errors.UniqueViolation:
            stmt = stmt.on_conflict_do_nothing(
                index_elements=["siret", "nom", "adresse_id"],
            )
            logging.info(f"Executing SQL on table: {table.table}")
            result = conn.execute(stmt)
            return result.rowcount

    elif str(table.table.name) == "personne":
        try:
            stmt = stmt.on_conflict_do_nothing(index_elements=["id_aidant_connect"])
            logging.info(f"Executing SQL on table: {table.table}")
            result = conn.execute(stmt)
            return result.rowcount
        except psycopg2.errors.UniqueViolation:
            stmt = stmt.on_conflict_do_nothing(
                index_elements=["id_conseiller_numerique"]
            )
            logging.info(f"Executing SQL on table: {table.table}")
            result = conn.execute(stmt)
            return result.rowcount


def write_postgres(
    df: pd.DataFrame,
    schema_name: str,
    table_name: str,
    conn_id: str = "sonum-prod-db",
    append: bool = False,
    conflict_do_nothing: bool = False,
) -> None:
    if not isinstance(df, pd.DataFrame) or df.empty:
        return

    df = df.replace({np.nan: None})
    dt_columns = df.select_dtypes(include=["datetime64[ns]"]).columns
    for col in dt_columns:
        df[col] = df[col].apply(lambda x: x.isoformat() if x is not None else None)

    hook = PostgresHook(postgres_conn_id=conn_id)
    engine = hook.get_sqlalchemy_engine()

    if not append:
        engine.execute(f"TRUNCATE {schema_name}.{table_name} CASCADE")

    method = insert_on_conflict_nothing if conflict_do_nothing else None

    df.to_sql(
        name=table_name,
        con=engine,
        schema=schema_name,
        index=False,
        if_exists="append",
        method=method,
    )

    engine.dispose()
