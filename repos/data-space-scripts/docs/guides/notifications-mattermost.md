Apache Airflow Mattermost Notifications
===

Le script `mattermost_notifier.py` contient la classe `MattermostNotifier`, qui permet d'envoyer des notifications dans un canal Mattermost.

Les notifications peuvent être envoyées sur succès ou échec d'un DAG et/ou des tâche(s).

# Prérequis

## Webhook Mattermost

Il est nécessaire de créer un webhook dans Mattermost.

Intégrations > Webhooks entrants

De préférence, créer préalablement un canal dédié.

Verrouiller le webhook sur le canal par défaut.

## Apache Airflow

Création des variables `MATTERMOST_WEBHOOK_URI` et `MATTERMOST_NOTIFICATION_CHANNEL`.

# Utilisation

Il est possible de définir des callback sur les `DAGs` et/ou les `tasks`, `on_success` et/ou `on_failure`.

```py
# Importer la classe
from mattermost_notifier import MattermostNotifier

# Récupérer les valeurs des variables
webhook = Variable.get("MATTERMOST_WEBHOOK_URI")
channel = Variable.get("MATTERMOST_NOTIFICATION_CHANNEL")

# Créer l'instance du notifier
notifier = MattermostNotifier(
    webhook_url= webhook,
    default_channel= channel,
)

# Ajouter les fonctions nécessaires
def dag_success_callback(context):
    notifier.notify(context, "DAG", "SUCCESS")

def dag_failure_callback(context):
    notifier.notify(context, "DAG", "FAILURE")

def task_success_callback(context):
    notifier.notify(context, "Task", "SUCCESS")

def task_failure_callback(context):
    notifier.notify(context, "Task", "FAILURE")

with DAG(
    dag_id="xxx",
    [...]
    # Au niveau du DAG, ajouter le(s) callback(s) souhaité(s)
    on_success_callback=dag_success_callback,
    on_failure_callback=dag_failure_callback,
) as dag:

    task = Operator(
        task_id="task",
        [...]
        # Au niveau des tâches, ajouter le(s) callback(s) souhaité(s)
        on_success_callback=task_success_callback,
        on_failure_callback=task_failure_callback,
    )
```
