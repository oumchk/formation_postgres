# TP — Réplication Physique Streaming PostgreSQL 16
## Architecture : Primary → Hot Standby → Warm Standby (cascade)
## Trois clusters sur une même machine virtuelle

---

## Architecture du Lab

```
                    WAL Streaming
  ┌─────────────┐ ─────────────────► ┌─────────────────┐
  │   PRIMARY   │                    │   HOT STANDBY   │
  │  Port 5450  │                    │    Port 5451    │
  │             │                    │  Lisible (RO)   │
  └─────────────┘                    └─────────────────┘
        │                                     │
        │  Archive WAL (cp local)             │  WAL Streaming (cascade)
        ▼                                     ▼
  /var/lib/postgresql/              ┌─────────────────┐
  wal_archive/                      │   WARM STANDBY  │
  (même VM)                         │    Port 5452    │
                                    │  Non lisible    │
                                    └─────────────────┘
```

| Cluster | Port | Rôle | Lecture | Source WAL |
|---|---|---|---|---|
| `primary` | 5450 | Primaire (R/W) | Oui (écriture + lecture) | — |
| `hot` | 5451 | Hot Standby | Oui (lecture seule) | Streaming depuis Primary |
| `warm` | 5452 | Warm Standby | Non | Streaming depuis Hot (cascade) |

> **Conventions :**
> - `[PRIMARY]` → psql sur port 5450
> - `[HOT]` → psql sur port 5451
> - `[WARM]` → psql sur port 5452
> - `[SHELL]` → commandes Bash (en tant qu'utilisateur `postgres`)

---

## Prérequis

```bash
# Vérifier PostgreSQL 16
psql --version        # PostgreSQL 16.x
which pg_basebackup   # /usr/bin/pg_basebackup

# Basculer en utilisateur postgres pour tout le TP
sudo -i -u postgres
```

---

## PARTIE 0 — Initialisation du cluster PRIMARY

### 0.1 Créer le cluster primaire

```bash
# [SHELL] Créer le cluster sur le port 5450
pg_createcluster 16 primary --port=5450
pg_ctlcluster 16 primary start

pg_lsclusters
```

Résultat attendu :

```
Ver Cluster  Port Status Owner    Data directory
16  primary  5450 online postgres /var/lib/postgresql/16/primary
```

### 0.2 Créer le répertoire d'archive WAL

```bash
# [SHELL] Répertoire local d'archive (même VM)
mkdir -p /var/lib/postgresql/wal_archive
chmod 700 /var/lib/postgresql/wal_archive
ls -la /var/lib/postgresql/wal_archive
```

### 0.3 Configurer postgresql.conf du PRIMARY

```bash
nano /etc/postgresql/16/primary/postgresql.conf
```

```ini
# ─── Réplication ───────────────────────────────
wal_level              = replica
max_wal_senders        = 10
max_replication_slots  = 10
wal_keep_size          = 256

# ─── Archivage WAL (sans outil tiers, cp local) ─
archive_mode    = on
archive_command = 'test ! -f /var/lib/postgresql/wal_archive/%f && cp %p /var/lib/postgresql/wal_archive/%f'
restore_command = 'cp /var/lib/postgresql/wal_archive/%f %p'

# ─── Standby ────────────────────────────────────
hot_standby = on

# ─── Réseau ────────────────────────────────────
listen_addresses = 'localhost'
```

> **Note sur archive_command** : `test ! -f ...` empêche l'écrasement d'un fichier déjà archivé. `%p` = chemin complet, `%f` = nom du fichier WAL.

### 0.4 Configurer pg_hba.conf du PRIMARY

```bash
nano /etc/postgresql/16/primary/pg_hba.conf
```

Ajouter à la fin :

```
# Réplication — même machine, tous les clusters
host    replication     replicateur     127.0.0.1/32     scram-sha-256
```

### 0.5 Redémarrer et vérifier

```bash
# archive_mode nécessite un redémarrage complet
pg_ctlcluster 16 primary restart

psql -p 5450 -U postgres -c "SHOW wal_level;"
psql -p 5450 -U postgres -c "SHOW archive_mode;"
```

Résultat attendu :

```
 wal_level
-----------
 replica

 archive_mode
--------------
 on
```

### 0.6 Créer le rôle de réplication

```bash
psql -p 5450 -U postgres
```

```sql
CREATE ROLE replicateur
  WITH LOGIN REPLICATION
  PASSWORD 'StreamPass2024!';
\q
```

```bash
# Créer le fichier .pgpass pour éviter les saisies de mot de passe
echo "127.0.0.1:*:replication:replicateur:StreamPass2024!" \
  >> /var/lib/postgresql/.pgpass
chmod 600 /var/lib/postgresql/.pgpass
```

### 0.7 Créer la base et les données de test

```bash
psql -p 5450 -U postgres -c "CREATE DATABASE lab_stream;"
psql -p 5450 -U postgres -d lab_stream
```

```sql
CREATE TABLE employes (
    id          SERIAL PRIMARY KEY,
    nom         VARCHAR(100) NOT NULL,
    poste       VARCHAR(100),
    salaire     NUMERIC(10,2),
    actif       BOOLEAN DEFAULT true,
    created_at  TIMESTAMP DEFAULT NOW()
);

CREATE TABLE transactions (
    id          SERIAL PRIMARY KEY,
    employe_id  INTEGER REFERENCES employes(id),
    montant     NUMERIC(10,2),
    type_op     VARCHAR(20),
    created_at  TIMESTAMP DEFAULT NOW()
);

INSERT INTO employes (nom, poste, salaire) VALUES
  ('Alice Dupont',  'DBA',        4500.00),
  ('Bob Martin',    'Développeur',3800.00),
  ('Claire Lebrun', 'DevOps',     4200.00),
  ('David Moreau',  'Analyste',   3600.00),
  ('Eve Lambert',   'Manager',    5500.00);

INSERT INTO transactions (employe_id, montant, type_op) VALUES
  (1,1500.00,'prime'),(2,800.00,'prime'),
  (3,1200.00,'remboursement'),(5,2000.00,'prime');

SELECT 'employes'     AS tbl, COUNT(*) FROM employes
UNION ALL
SELECT 'transactions', COUNT(*) FROM transactions;
\q
```

### 0.8 Forcer un premier archivage et le vérifier

```bash
psql -p 5450 -U postgres -c "CHECKPOINT; SELECT pg_switch_wal();"

# Vérifier l'archive
ls -lh /var/lib/postgresql/wal_archive/

# Statistiques d'archivage
psql -p 5450 -U postgres -c \
  "SELECT archived_count, last_archived_wal,
          failed_count, last_failed_wal
   FROM pg_stat_archiver;"
```

Résultat attendu : `failed_count = 0`.

---

## PARTIE 1 — Création du HOT STANDBY (Primary → Hot)

### 1.1 Cloner le PRIMARY avec pg_basebackup

```bash
# [SHELL] pg_basebackup depuis le PRIMARY
# -R : génère standby.signal + primary_conninfo automatiquement
# -Xs : inclut les WAL en streaming pendant la sauvegarde
# --checkpoint=fast : évite d'attendre le prochain checkpoint

pg_basebackup \
  -h 127.0.0.1 -p 5450 \
  -U replicateur \
  -D /var/lib/postgresql/16/hot \
  -R -Xs -P \
  --checkpoint=fast \
  --label="hot_standby_backup"
```

Résultat attendu :

```
35075/35075 kB (100%), 1/1 tablespace
```

```bash
# Vérifier les fichiers créés par -R
ls -la /var/lib/postgresql/16/hot/standby.signal
cat /var/lib/postgresql/16/hot/postgresql.auto.conf
```

`postgresql.auto.conf` doit contenir :

```ini
primary_conninfo = 'host=127.0.0.1 port=5450 user=replicateur ...'
```

### 1.2 Adapter la configuration du HOT STANDBY

```bash
nano /var/lib/postgresql/16/hot/postgresql.conf
```

Modifier ou ajouter :

```ini
# Port du HOT STANDBY
port = 5451

# HOT STANDBY : lectures autorisées
hot_standby = on

# Ce cluster sera lui-même source pour le WARM (cascade)
wal_level             = replica
max_wal_senders       = 5
max_replication_slots = 5

# Fallback sur l'archive si le streaming est interrompu
restore_command = 'cp /var/lib/postgresql/wal_archive/%f %p'

# Gestion des conflits de requêtes
max_standby_streaming_delay = 30s
max_standby_archive_delay   = 30s
hot_standby_feedback        = on
```

S'assurer que `postgresql.auto.conf` pointe vers le PRIMARY :

```bash
cat /var/lib/postgresql/16/hot/postgresql.auto.conf
# Doit contenir : host=127.0.0.1 port=5450 user=replicateur
```

### 1.3 Configurer pg_hba.conf du HOT STANDBY

```bash
nano /var/lib/postgresql/16/hot/pg_hba.conf
```

```
# Réplication depuis le WARM STANDBY (cascade)
host    replication     replicateur     127.0.0.1/32     scram-sha-256
# Connexions applicatives en lecture
host    all             all             127.0.0.1/32     scram-sha-256
```

### 1.4 Démarrer le HOT STANDBY

```bash
pg_ctl -D /var/lib/postgresql/16/hot \
       -l /var/log/postgresql/hot.log \
       -o "-p 5451" start

sleep 5
tail -30 /var/log/postgresql/hot.log
```

Lignes attendues dans les logs :

```
LOG:  entering standby mode
LOG:  redo starts at X/X
LOG:  consistent recovery state reached at X/X
LOG:  database system is ready to accept read only connections
LOG:  started streaming WAL from primary at X/X on timeline 1
```

### 1.5 Vérifier la réplication Primary → Hot

```bash
# [PRIMARY] Le HOT doit apparaître ici
psql -p 5450 -U postgres -c \
  "SELECT pid, usename, application_name, client_addr,
          state, sent_lsn, replay_lsn, sync_state
   FROM pg_stat_replication;"
```

Résultat attendu :

```
 state     | sync_state
-----------+------------
 streaming | async
```

```bash
# [HOT] Confirmer qu'il est en recovery
psql -p 5451 -U postgres -c "SELECT pg_is_in_recovery();"
# t

psql -p 5451 -U postgres -c \
  "SELECT now() - pg_last_xact_replay_timestamp() AS lag_replication;"
# Résultat attendu : lag < 1 seconde
```

---

## PARTIE 2 — Création du WARM STANDBY (Hot → Warm, cascade)

### 2.1 Cloner le HOT STANDBY avec pg_basebackup

> La sauvegarde est prise depuis le HOT (port 5451). C'est la cascade.

```bash
pg_basebackup \
  -h 127.0.0.1 -p 5451 \
  -U replicateur \
  -D /var/lib/postgresql/16/warm \
  -R -Xs -P \
  --checkpoint=fast \
  --label="warm_standby_backup"
```

```bash
# primary_conninfo DOIT pointer vers le HOT (port 5451)
cat /var/lib/postgresql/16/warm/postgresql.auto.conf
```

Résultat attendu :

```ini
primary_conninfo = 'host=127.0.0.1 port=5451 user=replicateur ...'
```

> **C'est la cascade** : WARM suit le HOT, le HOT suit le PRIMARY.

### 2.2 Adapter la configuration du WARM STANDBY

```bash
nano /var/lib/postgresql/16/warm/postgresql.conf
```

```ini
# Port du WARM STANDBY
port = 5452

# WARM STANDBY : aucune connexion acceptée
hot_standby = off

# Fallback sur l'archive si le streaming est interrompu
restore_command = 'cp /var/lib/postgresql/wal_archive/%f %p'

max_standby_streaming_delay = 30s
max_standby_archive_delay   = 30s
```

> **Différence clé entre Hot et Warm : uniquement `hot_standby = off`.**

### 2.3 Démarrer le WARM STANDBY

```bash
pg_ctl -D /var/lib/postgresql/16/warm \
       -l /var/log/postgresql/warm.log \
       -o "-p 5452" start

sleep 5
tail -30 /var/log/postgresql/warm.log
```

### 2.4 Vérifier la cascade complète

```bash
# [HOT] Le WARM doit apparaître ici (pas sur le PRIMARY)
psql -p 5451 -U postgres -c \
  "SELECT application_name, client_addr, state, sync_state
   FROM pg_stat_replication;"

# Résumé global des 3 clusters
for PORT in 5450 5451 5452; do
  echo -n "=== Port $PORT : "
  psql -p $PORT -U postgres -c \
    "SELECT CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END AS role;" \
    2>/dev/null || echo "CONNEXION REFUSÉE (Warm Standby)"
done
```

Résultat attendu :

```
=== Port 5450 : PRIMARY
=== Port 5451 : STANDBY  (Hot — connexion acceptée)
=== Port 5452 : CONNEXION REFUSÉE (Warm Standby)
```

---

## PARTIE 3 — Vérification de l'archivage WAL

### 3.1 Observer l'archivage

```bash
# [PRIMARY] Forcer plusieurs switch WAL
for i in 1 2 3; do
  psql -p 5450 -U postgres -c "SELECT pg_switch_wal();"
done

# Lister les fichiers archivés
ls -lht /var/lib/postgresql/wal_archive/ | head -10
```

### 3.2 Statistiques d'archivage

```bash
psql -p 5450 -U postgres -c "
SELECT
    archived_count,
    last_archived_wal,
    last_archived_time,
    failed_count,
    last_failed_wal,
    last_failed_time
FROM pg_stat_archiver;"
```

### 3.3 Rôle du restore_command

Le `restore_command` est utilisé par les standby comme **fallback** : si le streaming est temporairement interrompu, le standby peut récupérer les WAL manquants depuis l'archive locale.

```bash
# Simuler une récupération depuis l'archive manuellement
WAL_FILE=$(ls /var/lib/postgresql/wal_archive/ | head -1)
cp /var/lib/postgresql/wal_archive/$WAL_FILE /tmp/test_$WAL_FILE
echo "restore_command test : code retour = $?"
```

---

## SCÉNARIO 1 — Réplication en temps réel (Primary → Hot → Warm)

### Objectif
Observer la propagation des écritures à travers toute la chaîne de réplication.

### Étape 1 : Ouvrir plusieurs terminaux de surveillance

**Terminal A — PRIMARY :**

```bash
watch -n 1 "psql -p 5450 -U postgres -d lab_stream \
  -c \"SELECT id, nom, poste, salaire FROM employes ORDER BY id;\""
```

**Terminal B — HOT STANDBY :**

```bash
watch -n 1 "psql -p 5451 -U postgres -d lab_stream \
  -c \"SELECT id, nom, poste, salaire FROM employes ORDER BY id;\""
```

### Étape 2 : Écrire sur le PRIMARY et observer la propagation

```bash
psql -p 5450 -U postgres -d lab_stream
```

```sql
-- Insérer
INSERT INTO employes (nom, poste, salaire)
VALUES ('Frank Duval', 'Architecte', 5200.00);
-- Observer : Frank apparaît sur PRIMARY puis HOT (< 1 sec)

-- Modifier
UPDATE employes SET salaire = 5000.00 WHERE nom = 'Bob Martin';
-- Observer : salaire mis à jour sur les deux

-- Supprimer
DELETE FROM employes WHERE nom = 'David Moreau';
-- Observer : David disparaît sur les deux
\q
```

### Étape 3 : Vérifier le refus d'écriture sur le HOT

```bash
psql -p 5451 -U postgres -d lab_stream -c \
  "INSERT INTO employes (nom, poste) VALUES ('Test', 'Test');"
```

Résultat attendu :

```
ERROR:  cannot execute INSERT in a read-only transaction
```

### Étape 4 : Vérifier le refus de connexion sur le WARM

```bash
psql -p 5452 -U postgres -d lab_stream -c "SELECT 1;"
```

Résultat attendu :

```
FATAL:  the database system is not yet accepting connections
```

### Étape 5 : Mesurer le lag à chaque niveau

```bash
# [PRIMARY] Lag vers le HOT
psql -p 5450 -U postgres -c "
SELECT application_name,
       state,
       pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS lag_taille,
       sync_state
FROM pg_stat_replication;"

# [HOT] Lag depuis le PRIMARY
psql -p 5451 -U postgres -c "
SELECT
  pg_is_in_recovery()                          AS en_standby,
  now() - pg_last_xact_replay_timestamp()      AS lag_temps,
  pg_last_wal_receive_lsn()                    AS lsn_recu,
  pg_last_wal_replay_lsn()                     AS lsn_applique;"

# [HOT] Lag vers le WARM
psql -p 5451 -U postgres -c "
SELECT application_name,
       pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS lag_warm
FROM pg_stat_replication;"
```

---

## SCÉNARIO 2 — Décharge des lectures sur le HOT STANDBY

### Objectif
Utiliser le HOT STANDBY pour absorber les requêtes analytiques.

### Étape 1 : Générer un volume de données

```bash
psql -p 5450 -U postgres -d lab_stream -c "
INSERT INTO transactions (employe_id, montant, type_op)
SELECT
  (RANDOM()*4+1)::INTEGER,
  ROUND((RANDOM()*5000)::NUMERIC, 2),
  CASE WHEN RANDOM() < 0.5 THEN 'prime' ELSE 'remboursement' END
FROM generate_series(1, 100000);"
```

### Étape 2 : Requête analytique sur le HOT (pas sur le PRIMARY)

```bash
# [HOT] Exécuter la requête analytique lourde
psql -p 5451 -U postgres -d lab_stream -c "
SELECT
    e.nom, e.poste,
    COUNT(t.id)     AS nb_transactions,
    SUM(t.montant)  AS total,
    AVG(t.montant)  AS moyenne
FROM employes e
JOIN transactions t ON t.employe_id = e.id
GROUP BY e.id, e.nom, e.poste
ORDER BY total DESC;"
```

### Étape 3 : Pendant ce temps, écrire sur le PRIMARY

```bash
# [PRIMARY] Le primaire reste disponible pendant la requête analytique
psql -p 5450 -U postgres -d lab_stream -c "
INSERT INTO transactions (employe_id, montant, type_op)
VALUES (1, 999.99, 'bonus');
SELECT 'PRIMARY opérationnel pendant la requête analytique' AS status;"
```

---

## SCÉNARIO 3 — Conflits de requêtes sur le HOT STANDBY

### Objectif
Observer et comprendre les conflits entre l'application des WAL et les requêtes sur le HOT STANDBY.

### Contexte
Un conflit survient quand le PRIMARY supprime des versions de lignes (VACUUM) que le HOT est en train de lire. PostgreSQL doit annuler la requête sur le HOT pour appliquer le WAL.

### Étape 1 : Provoquer un conflit

**Terminal 1 — lancer une requête longue sur le HOT :**

```bash
psql -p 5451 -U postgres -d lab_stream
```

```sql
-- [HOT] Transaction longue qui bloque l'application des WAL
BEGIN;
SELECT pg_sleep(60), COUNT(*) FROM transactions;
-- Laisser tourner...
```

**Terminal 2 — provoquer un VACUUM sur le PRIMARY :**

```bash
psql -p 5450 -U postgres -d lab_stream -c "VACUUM FULL transactions;"
```

**Terminal 1** : après `max_standby_streaming_delay` (30s), la requête sera annulée :

```
ERROR:  canceling statement due to conflict with recovery
DETAIL:  User query might have needed to see row versions that must be removed.
```

### Étape 2 : Régler les paramètres de conflit

```bash
nano /var/lib/postgresql/16/hot/postgresql.conf
```

```ini
# Augmenter si les requêtes analytiques longues sont prioritaires
max_standby_streaming_delay = 120s

# hot_standby_feedback = on : prévient le PRIMARY de ne pas
# supprimer les lignes encore lues par le HOT
hot_standby_feedback = on
```

```bash
pg_ctl -D /var/lib/postgresql/16/hot reload
```

> **Trade-off** : `hot_standby_feedback = on` peut empêcher l'autovacuum du PRIMARY de tourner normalement. À utiliser avec précaution.

---

## SCÉNARIO 4 — Réplication Synchrone

### Objectif
Configurer une réplication synchrone entre le PRIMARY et le HOT STANDBY pour garantir RPO = 0.

### Étape 1 : Configurer le PRIMARY en mode synchrone

```bash
nano /etc/postgresql/16/primary/postgresql.conf
```

```ini
# Nom du standby synchrone (doit correspondre à application_name du standby)
synchronous_standby_names = 'hot_standby_1'

# Niveau de confirmation requis
# 'on' = le WAL est écrit sur disque du standby avant COMMIT
synchronous_commit = on
```

### Étape 2 : Configurer le HOT STANDBY avec son application_name

```bash
# [HOT] Modifier primary_conninfo pour ajouter application_name
nano /var/lib/postgresql/16/hot/postgresql.auto.conf
```

```ini
primary_conninfo = 'host=127.0.0.1 port=5450 user=replicateur password=StreamPass2024! application_name=hot_standby_1'
```

```bash
# Recharger le PRIMARY et redémarrer le HOT
pg_ctlcluster 16 primary reload
pg_ctl -D /var/lib/postgresql/16/hot restart
```

### Étape 3 : Vérifier le mode synchrone

```bash
psql -p 5450 -U postgres -c "
SELECT application_name, sync_state, state
FROM pg_stat_replication;"
```

Résultat attendu :

```
 application_name | sync_state | state
------------------+------------+-----------
 hot_standby_1    | sync       | streaming
```

### Étape 4 : Tester RPO = 0

```bash
# [PRIMARY] Insérer et mesurer le temps de COMMIT
psql -p 5450 -U postgres -d lab_stream -c "
\timing on
INSERT INTO employes (nom, poste, salaire)
VALUES ('Test Sync', 'Test', 0.00);
-- Le COMMIT ne revient qu'après confirmation du HOT"

# [HOT] La ligne doit être immédiatement visible
psql -p 5451 -U postgres -d lab_stream -c \
  "SELECT nom FROM employes WHERE nom = 'Test Sync';"
```

### Étape 5 : Simuler la panne du HOT en mode synchrone

```bash
# Arrêter le HOT
pg_ctl -D /var/lib/postgresql/16/hot stop

# [PRIMARY] Tenter une écriture — elle se bloque !
psql -p 5450 -U postgres -d lab_stream -c "
INSERT INTO employes (nom, poste, salaire)
VALUES ('Test Blocage', 'Test', 0.00);"
# Cette commande NE REVIENDRA PAS tant que le HOT est arrêté
```

```bash
# Ctrl+C pour annuler, puis redémarrer le HOT
pg_ctl -D /var/lib/postgresql/16/hot \
       -l /var/log/postgresql/hot.log \
       -o "-p 5451" start
```

### Étape 6 : Revenir en mode asynchrone

```bash
nano /etc/postgresql/16/primary/postgresql.conf
```

```ini
# Revenir en asynchrone pour la suite du TP
synchronous_standby_names = ''
synchronous_commit = local
```

```bash
pg_ctlcluster 16 primary reload
```

---

## SCÉNARIO 5 — Promotion du HOT STANDBY (Failover)

### Objectif
Simuler une panne du PRIMARY et promouvoir le HOT STANDBY en nouveau primaire.

> **Attention** : la promotion est irréversible. Le WARM STANDBY devra être reconfiguré.

### Étape 1 : État initial avant la panne

```bash
# Vérifier l'état de la réplication
psql -p 5450 -U postgres -c "SELECT COUNT(*) FROM pg_stat_replication;"
psql -p 5451 -U postgres -c "SELECT pg_is_in_recovery();"

# Dernière transaction avant la panne
psql -p 5450 -U postgres -d lab_stream -c "
INSERT INTO employes (nom, poste, salaire)
VALUES ('Avant Failover', 'Test', 0.00);"
```

### Étape 2 : Simuler la panne du PRIMARY

```bash
# [SHELL] Arrêter le PRIMARY brutalement (simule un crash)
pg_ctl -D /var/lib/postgresql/16/primary stop -m immediate

# Vérifier qu'il est bien arrêté
pg_ctl -D /var/lib/postgresql/16/primary status
# Résultat attendu : pg_ctl: no server running
```

### Étape 3 : Promouvoir le HOT STANDBY

```bash
# [SHELL] Promouvoir le HOT STANDBY en nouveau PRIMARY
# Méthode 1 : pg_promote() (recommandé PG 12+)
psql -p 5451 -U postgres -c "SELECT pg_promote();"

# Méthode 2 : signal file (alternative)
# touch /var/lib/postgresql/16/hot/promote.signal
```

```bash
# Attendre quelques secondes
sleep 3

# Vérifier la promotion
psql -p 5451 -U postgres -c "SELECT pg_is_in_recovery();"
# Résultat attendu : f (false = le HOT est maintenant PRIMARY)

psql -p 5451 -U postgres -d lab_stream -c \
  "SELECT nom FROM employes WHERE nom = 'Avant Failover';"
# Résultat attendu : la ligne est présente (0 perte de données)
```

### Étape 4 : Tester les écritures sur le nouveau PRIMARY

```bash
psql -p 5451 -U postgres -d lab_stream -c "
INSERT INTO employes (nom, poste, salaire)
VALUES ('Après Failover', 'Nouveau Primary', 0.00);"

psql -p 5451 -U postgres -d lab_stream -c \
  "SELECT nom, poste FROM employes ORDER BY id DESC LIMIT 3;"
```

### Étape 5 : Vérifier les logs de promotion

```bash
tail -20 /var/log/postgresql/hot.log
```

Lignes attendues :

```
LOG:  received promote request
LOG:  redo done at X/X; shutdown up to X/X
LOG:  selected new timeline ID: 2
LOG:  archive recovery complete
LOG:  database system is ready to accept connections
```

> **Timeline ID: 2** : PostgreSQL a créé une nouvelle timeline, marquant la séparation entre l'historique du PRIMARY original et le nouveau PRIMARY promu.

---

## SCÉNARIO 6 — Reconfiguration du WARM STANDBY après failover

### Objectif
Reconnecter le WARM STANDBY au nouveau PRIMARY (ex-HOT) après la promotion.

### Contexte
Après le failover :
- Ancien PRIMARY (port 5450) : arrêté, ne redémarre plus en tant que primaire
- Nouveau PRIMARY (port 5451) : ex-HOT, maintenant R/W
- WARM STANDBY (port 5452) : toujours connecté à l'ancien primaire (5450) → connexion perdue

### Étape 1 : Observer l'état du WARM après la panne

```bash
# Le WARM essaie de se connecter au HOT (5451) qui est devenu PRIMARY
# Ses logs vont montrer des erreurs de connexion ou de timeline

tail -20 /var/log/postgresql/warm.log
```

Lignes possibles :

```
LOG:  replication terminated by primary server
DETAIL:  End of WAL reached on timeline 1 at X/X
LOG:  fetching timeline history file for timeline 2
```

### Étape 2 : Reconfigurer le WARM pour suivre le nouveau PRIMARY

```bash
# [WARM] Modifier primary_conninfo pour pointer vers le nouveau PRIMARY (port 5451)
nano /var/lib/postgresql/16/warm/postgresql.auto.conf
```

```ini
primary_conninfo = 'host=127.0.0.1 port=5451 user=replicateur password=StreamPass2024!'
```

```bash
# Redémarrer le WARM
pg_ctl -D /var/lib/postgresql/16/warm stop
pg_ctl -D /var/lib/postgresql/16/warm \
       -l /var/log/postgresql/warm.log \
       -o "-p 5452" start

sleep 5
tail -20 /var/log/postgresql/warm.log
```

### Étape 3 : Vérifier la reprise de la cascade

```bash
# [Nouveau PRIMARY — port 5451] Le WARM doit réapparaître
psql -p 5451 -U postgres -c "
SELECT application_name, state, sync_state
FROM pg_stat_replication;"
```

Résultat attendu :

```
 application_name | state     | sync_state
------------------+-----------+------------
 walreceiver      | streaming | async
```

### Étape 4 : Vérifier la cohérence des données

```bash
# Compter les employes sur le nouveau PRIMARY et sur le WARM
psql -p 5451 -U postgres -d lab_stream -c "SELECT COUNT(*) AS primary FROM employes;"
# Le WARM ne répond pas aux connexions, on vérifie via les logs uniquement
tail -5 /var/log/postgresql/warm.log
# LOG: started streaming WAL from primary at X/X on timeline 2
```

---

## SCÉNARIO 7 — Switchover planifié (sans perte de données)

### Objectif
Effectuer un basculement propre et contrôlé, sans interruption de service.

> **Note** : ce scénario utilise l'ancien PRIMARY (port 5450) si vous ne l'avez pas supprimé, ou simule le switchover entre les clusters existants.

### Procédure de switchover propre

```bash
# Étape 1 : Vérifier que le standby est à jour
psql -p 5450 -U postgres -c "
SELECT application_name,
       pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS lag
FROM pg_stat_replication;"
# Lag doit être proche de 0

# Étape 2 : Arrêter proprement le PRIMARY (flush des WAL)
pg_ctl -D /var/lib/postgresql/16/primary stop -m fast

# Étape 3 : Promouvoir le HOT STANDBY
psql -p 5451 -U postgres -c "SELECT pg_promote();"

# Étape 4 : Reconvertir l'ancien PRIMARY en standby
# Créer standby.signal dans l'ancien data dir
touch /var/lib/postgresql/16/primary/standby.signal

# Mettre à jour postgresql.auto.conf de l'ancien PRIMARY
cat >> /var/lib/postgresql/16/primary/postgresql.auto.conf << 'EOF'
primary_conninfo = 'host=127.0.0.1 port=5451 user=replicateur password=StreamPass2024!'
EOF

# Redémarrer l'ancien PRIMARY en tant que nouveau standby
pg_ctl -D /var/lib/postgresql/16/primary \
       -l /var/log/postgresql/old_primary.log \
       -o "-p 5450" start

# Étape 5 : Vérifier la nouvelle topologie
psql -p 5451 -U postgres -c "
SELECT application_name, state FROM pg_stat_replication;"
```

---

## SCÉNARIO 8 — Supervision complète de la réplication

### Étape 1 : Vue globale depuis le PRIMARY

```bash
psql -p 5450 -U postgres -c "
SELECT
    pid,
    usename,
    application_name,
    client_addr,
    state,
    sent_lsn,
    write_lsn,
    flush_lsn,
    replay_lsn,
    pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS lag,
    sync_state
FROM pg_stat_replication;"
```

### Étape 2 : Tableau de bord complet

```bash
psql -p 5450 -U postgres -c "
SELECT
    now() AS heure,
    pg_current_wal_lsn() AS wal_current,
    (SELECT COUNT(*) FROM pg_stat_replication) AS nb_standby_connectes,
    (SELECT pg_size_pretty(sum(pg_wal_lsn_diff(sent_lsn, replay_lsn)))
     FROM pg_stat_replication) AS lag_total;"
```

### Étape 3 : Superviser l'archivage

```bash
psql -p 5450 -U postgres -c "
SELECT
    archived_count          AS wals_archives,
    last_archived_wal,
    last_archived_time,
    failed_count            AS echecs_archivage,
    last_failed_wal,
    last_failed_time
FROM pg_stat_archiver;"
```

### Étape 4 : Vérifier la timeline courante

```bash
# Sur chaque cluster
for PORT in 5450 5451; do
  echo -n "Port $PORT — Timeline : "
  psql -p $PORT -U postgres \
    -c "SELECT timeline_id FROM pg_control_checkpoint();" \
    2>/dev/null
done
```

### Étape 5 : Script de supervision rapide

```bash
#!/bin/bash
# Sauvegarder dans /usr/local/bin/check_replication.sh
# chmod +x /usr/local/bin/check_replication.sh

echo "════════════════════════════════════════"
echo "  Supervision Réplication PostgreSQL 16"
echo "════════════════════════════════════════"

echo -e "\n─── PRIMARY (5450) — Standby connectés ───"
psql -p 5450 -U postgres -c \
  "SELECT application_name, state,
     pg_size_pretty(pg_wal_lsn_diff(sent_lsn,replay_lsn)) AS lag,
     sync_state
   FROM pg_stat_replication;" 2>/dev/null

echo -e "\n─── Archivage WAL ───"
psql -p 5450 -U postgres -c \
  "SELECT archived_count, failed_count,
     last_archived_wal, last_archived_time
   FROM pg_stat_archiver;" 2>/dev/null

echo -e "\n─── HOT STANDBY (5451) ───"
psql -p 5451 -U postgres -c \
  "SELECT pg_is_in_recovery() AS en_standby,
     now()-pg_last_xact_replay_timestamp() AS lag_temps;" 2>/dev/null

echo -e "\n─── Fichiers WAL archivés ───"
echo "Nombre : $(ls /var/lib/postgresql/wal_archive/ | wc -l)"
echo "Taille : $(du -sh /var/lib/postgresql/wal_archive/ | cut -f1)"
```

---

## SCÉNARIO 9 — PITR (Point-In-Time Recovery) depuis l'archive

### Objectif
Restaurer une base à un instant précis en utilisant les fichiers WAL archivés.

### Étape 1 : Prendre une sauvegarde de base (point de départ)

```bash
# [SHELL] Sauvegarde de base avec label temporel
BACKUP_DIR="/var/lib/postgresql/pitr_backup_$(date +%Y%m%d_%H%M%S)"
pg_basebackup \
  -h 127.0.0.1 -p 5450 -U replicateur \
  -D $BACKUP_DIR \
  -Xs -P --checkpoint=fast \
  --label="pitr_backup"

echo "Backup dans : $BACKUP_DIR"
```

### Étape 2 : Créer des données avec des timestamps précis

```bash
psql -p 5450 -U postgres -d lab_stream
```

```sql
-- Enregistrer l'heure avant chaque opération
SELECT now() AS t1_avant_insert;

INSERT INTO employes (nom, poste, salaire)
VALUES ('PITR Test 1', 'Test', 1000.00);

-- Attendre 2 secondes
SELECT pg_sleep(2);
SELECT now() AS t2_moment_a_retenir;
-- Noter cette heure exacte, ex: 2026-03-22 14:30:00

SELECT pg_sleep(2);

INSERT INTO employes (nom, poste, salaire)
VALUES ('PITR Test 2 - A SUPPRIMER', 'Test', 2000.00);

SELECT now() AS t3_apres_erreur;
\q
```

### Étape 3 : Configurer la recovery.conf (via postgresql.conf PG12+)

```bash
# Créer un répertoire de restauration
RESTORE_DIR="/var/lib/postgresql/pitr_restore"
cp -r $BACKUP_DIR $RESTORE_DIR

# Créer le signal de recovery
touch $RESTORE_DIR/standby.signal
```

```bash
nano $RESTORE_DIR/postgresql.conf
```

Ajouter à la fin :

```ini
# PITR : restaurer jusqu'au moment T2 (avant l'insertion de "Test 2")
restore_command = 'cp /var/lib/postgresql/wal_archive/%f %p'
recovery_target_time = '2026-03-22 14:30:00'  # Adapter à votre T2
recovery_target_action = 'promote'
port = 5435
```

```bash
# Démarrer la restauration PITR
pg_ctl -D $RESTORE_DIR \
       -l /var/log/postgresql/pitr_restore.log \
       -o "-p 5435" start

tail -f /var/log/postgresql/pitr_restore.log
# Attendre : LOG: recovery stopping before commit of transaction ...
# Puis : LOG: pausing at the end of recovery
```

### Étape 4 : Vérifier la restauration

```bash
psql -p 5435 -U postgres -d lab_stream -c \
  "SELECT nom, poste FROM employes WHERE nom LIKE 'PITR%';"
```

Résultat attendu :

```
    nom      | poste
-------------+-------
 PITR Test 1 | Test
```

> "PITR Test 2" n'est pas présent : la restauration s'est arrêtée avant son insertion.

```bash
# Nettoyer
pg_ctl -D $RESTORE_DIR stop
```

---

## SCÉNARIO 10 — Nettoyage complet du Lab

### Arrêter tous les clusters

```bash
# Arrêter dans l'ordre inverse (du plus dépendant au moins dépendant)
pg_ctl -D /var/lib/postgresql/16/warm  stop 2>/dev/null
pg_ctl -D /var/lib/postgresql/16/hot   stop 2>/dev/null
pg_ctlcluster 16 primary stop           2>/dev/null
```

### Vérifier que tout est arrêté

```bash
for PORT in 5450 5451 5452; do
  psql -p $PORT -U postgres -c "SELECT 1;" 2>&1 | grep -q "could not connect" && \
    echo "Port $PORT : OK (arrêté)" || echo "Port $PORT : encore actif"
done
```

### Supprimer les data directories (optionnel)

```bash
# ATTENTION : irréversible
rm -rf /var/lib/postgresql/16/hot
rm -rf /var/lib/postgresql/16/warm
pg_dropcluster 16 primary   # ou rm -rf /var/lib/postgresql/16/primary

# Supprimer l'archive WAL
rm -rf /var/lib/postgresql/wal_archive
```

---

## Annexe A — Paramètres clés de la réplication physique

| Paramètre | Cluster | Valeur recommandée | Rôle |
|---|---|---|---|
| `wal_level` | PRIMARY | `replica` | Active la réplication physique |
| `max_wal_senders` | PRIMARY, HOT | `10` | Nb max de processus walsender |
| `max_replication_slots` | PRIMARY, HOT | `10` | Nb max de slots de réplication |
| `wal_keep_size` | PRIMARY | `256` | WAL conservés en Mo (sans slot) |
| `archive_mode` | PRIMARY | `on` | Active l'archivage WAL |
| `archive_command` | PRIMARY | `cp %p .../wal_archive/%f` | Commande d'archivage (sans outil tiers) |
| `restore_command` | HOT, WARM | `cp .../wal_archive/%f %p` | Récupération WAL depuis archive |
| `hot_standby` | HOT | `on` | Autorise les lectures sur standby |
| `hot_standby` | WARM | `off` | Refuse les connexions (Warm) |
| `hot_standby_feedback` | HOT | `on` | Évite les conflits de vacuum |
| `synchronous_standby_names` | PRIMARY | `''` (async) ou `'hot_name'` (sync) | Mode sync/async |
| `synchronous_commit` | PRIMARY | `local` (async) ou `on` (sync) | Niveau de confirmation |

---

## Annexe B — Vues système de supervision

| Vue | Cluster | Contenu |
|---|---|---|
| `pg_stat_replication` | PRIMARY, HOT | Connexions WAL sender actives, lag, sync_state |
| `pg_stat_archiver` | PRIMARY | Statistiques d'archivage WAL |
| `pg_replication_slots` | PRIMARY, HOT | Slots actifs et lag WAL retenu |
| `pg_stat_wal_receiver` | HOT, WARM | Statut du WAL receiver côté standby |
| `pg_is_in_recovery()` | Tous | `true` si le cluster est en mode standby |
| `pg_last_wal_receive_lsn()` | HOT, WARM | Dernier LSN reçu |
| `pg_last_wal_replay_lsn()` | HOT, WARM | Dernier LSN appliqué |
| `pg_last_xact_replay_timestamp()` | HOT, WARM | Timestamp de la dernière transaction appliquée |
| `pg_control_checkpoint()` | Tous | Timeline ID, LSN du dernier checkpoint |

---

## Annexe C — Erreurs fréquentes et solutions

### Erreur : `FATAL: could not connect to the primary server`
**Cause :** `primary_conninfo` incorrect ou `pg_hba.conf` non configuré.
**Solution :**
```bash
# Vérifier primary_conninfo
cat /var/lib/postgresql/16/hot/postgresql.auto.conf
# Vérifier pg_hba.conf du PRIMARY
grep replicateur /etc/postgresql/16/primary/pg_hba.conf
# Recharger
pg_ctlcluster 16 primary reload
```

### Erreur : `FATAL: requested WAL segment has already been removed`
**Cause :** le standby est trop en retard, les WAL ont été supprimés du PRIMARY.
**Solution :**
```bash
# Refaire un pg_basebackup complet depuis le PRIMARY
pg_basebackup -h 127.0.0.1 -p 5450 -U replicateur \
  -D /var/lib/postgresql/16/hot_new -R -Xs -P
```

### Erreur : `archive_command failed` (failed_count > 0)
**Cause :** le répertoire d'archive n'existe pas ou les permissions sont incorrectes.
**Solution :**
```bash
mkdir -p /var/lib/postgresql/wal_archive
chown postgres:postgres /var/lib/postgresql/wal_archive
chmod 700 /var/lib/postgresql/wal_archive
# Tester manuellement
ls /var/lib/postgresql/wal_archive/
```

### Erreur : `canceling statement due to conflict with recovery`
**Cause :** conflit entre un VACUUM sur le PRIMARY et une requête sur le HOT.
**Solution :**
```bash
# Augmenter le délai ou activer le feedback
echo "max_standby_streaming_delay = 120s" >> /var/lib/postgresql/16/hot/postgresql.conf
echo "hot_standby_feedback = on"          >> /var/lib/postgresql/16/hot/postgresql.conf
pg_ctl -D /var/lib/postgresql/16/hot reload
```

### Erreur : WARM ne se reconnecte pas après failover
**Cause :** `primary_conninfo` du WARM pointe encore vers l'ancien PRIMARY.
**Solution :**
```bash
nano /var/lib/postgresql/16/warm/postgresql.auto.conf
# Changer port=5450 en port=5451 (nouveau PRIMARY)
pg_ctl -D /var/lib/postgresql/16/warm restart
```

---

## Annexe D — Commandes de référence rapide

```bash
# ─── Démarrer / Arrêter les clusters ───────────────────────────────
pg_ctlcluster 16 primary start
pg_ctl -D /var/lib/postgresql/16/hot  -l /var/log/postgresql/hot.log  -o "-p 5451" start
pg_ctl -D /var/lib/postgresql/16/warm -l /var/log/postgresql/warm.log -o "-p 5452" start

# ─── Vérifier les clusters ──────────────────────────────────────────
pg_lsclusters
pg_ctl -D /var/lib/postgresql/16/hot status

# ─── Superviser la réplication ──────────────────────────────────────
psql -p 5450 -U postgres -c "SELECT * FROM pg_stat_replication;"
psql -p 5451 -U postgres -c "SELECT pg_is_in_recovery(), now()-pg_last_xact_replay_timestamp();"
psql -p 5450 -U postgres -c "SELECT * FROM pg_stat_archiver;"

# ─── Forcer un switch WAL (pour tester l'archivage) ─────────────────
psql -p 5450 -U postgres -c "SELECT pg_switch_wal();"
psql -p 5450 -U postgres -c "CHECKPOINT;"

# ─── Promouvoir un standby ───────────────────────────────────────────
psql -p 5451 -U postgres -c "SELECT pg_promote();"

# ─── Vérifier les timelines ─────────────────────────────────────────
psql -p 5450 -U postgres -c "SELECT timeline_id FROM pg_control_checkpoint();"

# ─── pg_basebackup depuis le PRIMARY ────────────────────────────────
pg_basebackup -h 127.0.0.1 -p 5450 -U replicateur \
  -D /var/lib/postgresql/16/hot -R -Xs -P --checkpoint=fast

# ─── pg_basebackup depuis le HOT (cascade) ──────────────────────────
pg_basebackup -h 127.0.0.1 -p 5451 -U replicateur \
  -D /var/lib/postgresql/16/warm -R -Xs -P --checkpoint=fast

# ─── Vérifier l'archive WAL ─────────────────────────────────────────
ls -lht /var/lib/postgresql/wal_archive/ | head -10
du -sh /var/lib/postgresql/wal_archive/
```
