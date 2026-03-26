# LAB — PgBouncer avec PostgreSQL 16 sur Ubuntu 24.04
## Installation · Configuration · Test de charge avec pgbench

> **Document autonome** — toutes les commandes sont incluses, aucune recherche externe nécessaire.  
> Durée estimée : **2 à 3 heures** · Niveau : Intermédiaire DBA

---

## Environnement du Lab

| Élément | Valeur |
|---|---|
| Système | Ubuntu 24.04 LTS |
| PostgreSQL | 16.x (port 5432) |
| PgBouncer | 1.22.x (port 6432) |
| Base de test | benchdb |
| Utilisateur de test | benchuser |

---

## Architecture cible

```
Application / pgbench
        │
        ▼
  PgBouncer :6432          ← pool de connexions
  (transaction pooling)
        │
        ▼
  PostgreSQL :5432         ← base de données
  (max_connections = 100)
```

---

## PARTIE 0 — Vérification et prérequis système

### 0.1 Mise à jour du système

```bash
sudo apt update && sudo apt upgrade -y
```

### 0.2 Vérifier que PostgreSQL 16 est installé et actif

```bash
# Vérifier la version
psql --version
# → psql (PostgreSQL) 16.x

# Vérifier que le service tourne
sudo systemctl status postgresql
# → Active: active (running)

# Si PostgreSQL n'est pas installé, l'installer depuis le dépôt PGDG
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  | sudo gpg --dearmor -o /usr/share/keyrings/postgresql.gpg

echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] \
  https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
  | sudo tee /etc/apt/sources.list.d/pgdg.list

sudo apt update
sudo apt install -y postgresql-16 postgresql-client-16
```

### 0.3 Vérifier les paramètres PostgreSQL actuels

```bash
# Se connecter à PostgreSQL
sudo -u postgres psql

-- Voir le port actif
SHOW port;
-- → 5432

-- Voir max_connections actuel
SHOW max_connections;
-- → 100 (valeur par défaut)

-- Voir shared_buffers
SHOW shared_buffers;

-- Quitter
\q
```

### 0.4 Installer les outils utiles

```bash
sudo apt install -y htop net-tools tree vim wget curl
```

---

## PARTIE 1 — Préparer PostgreSQL pour le Lab

### 1.1 Créer la base de données et l'utilisateur de test

```bash
sudo -u postgres psql << 'SQL'

-- Créer l'utilisateur de test (non-superuser)
CREATE ROLE benchuser WITH
  LOGIN
  PASSWORD 'Bench#2024!'
  CONNECTION LIMIT 200;

-- Créer la base de test
CREATE DATABASE benchdb
  OWNER benchuser
  ENCODING 'UTF8'
  LC_COLLATE 'fr_FR.UTF-8'
  LC_CTYPE   'fr_FR.UTF-8'
  TEMPLATE   template0;

-- Vérification
\du benchuser
\l benchdb

SQL
```

### 1.2 Initialiser pgbench sur la base de test

pgbench crée automatiquement les tables de test (pgbench_accounts, pgbench_branches, pgbench_tellers, pgbench_history).

```bash
# -i = initialize (créer les tables)
# -s 10 = scale factor 10 (≈ 1.4 Mo de données, 100 000 comptes)
pgbench -i -s 10 -h localhost -p 5432 -U benchuser benchdb
# Saisir le mot de passe : Bench#2024!
```

**Sortie attendue :**
```
dropping old tables...
creating tables...
generating data (client-side)...
1000000 of 1000000 tuples (100%) done (elapsed 3.21 s, remaining 0.00 s)
vacuuming...
creating primary keys...
done in 5.84 s (drop tables 0.01 s, create tables 0.02 s, ...).
```

```bash
# Vérifier les tables créées
sudo -u postgres psql -d benchdb -c "\dt pgbench_*"
sudo -u postgres psql -d benchdb -c "SELECT COUNT(*) FROM pgbench_accounts;"
# → 1 000 000 lignes
```

### 1.3 Configurer pg_hba.conf pour PgBouncer

PgBouncer se connectera à PostgreSQL via localhost. Il faut autoriser la méthode `scram-sha-256` (ou `md5`).

```bash
# Afficher la configuration actuelle
sudo cat /etc/postgresql/16/main/pg_hba.conf | grep -v "^#" | grep -v "^$"
```

```bash
# Ajouter les lignes nécessaires si absentes
sudo bash -c 'cat >> /etc/postgresql/16/main/pg_hba.conf << EOF

# PgBouncer — connexions depuis localhost
host    benchdb     benchuser   127.0.0.1/32    scram-sha-256
host    all         benchuser   ::1/128         scram-sha-256

# PgBouncer — pgbouncer_auth (pour auth_query)
host    all         pgbouncer   127.0.0.1/32    scram-sha-256
EOF'
```

```bash
# Recharger PostgreSQL pour prendre en compte pg_hba.conf
sudo systemctl reload postgresql

# Tester la connexion directe
psql -h 127.0.0.1 -p 5432 -U benchuser -d benchdb -c "SELECT version();"
# Saisir le mot de passe : Bench#2024!
# → PostgreSQL 16.x ...
```

### 1.4 Ajuster les paramètres PostgreSQL pour le lab

```bash
sudo -u postgres psql << 'SQL'

-- Augmenter légèrement max_connections pour le lab
ALTER SYSTEM SET max_connections = 200;

-- Activer les logs de connexion pour voir la différence avec/sans PgBouncer
ALTER SYSTEM SET log_connections = on;
ALTER SYSTEM SET log_disconnections = on;

-- Activer pg_stat_statements pour analyser les requêtes
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
ALTER SYSTEM SET shared_preload_libraries = 'pg_stat_statements';

SQL

# Redémarrer PostgreSQL pour appliquer max_connections et shared_preload_libraries
sudo systemctl restart postgresql

# Vérifier
sudo -u postgres psql -c "SHOW max_connections;"
# → 200
```

---

## PARTIE 2 — Installation de PgBouncer

### 2.1 Installer PgBouncer depuis le dépôt PGDG

```bash
# PgBouncer est disponible dans le dépôt PGDG déjà configuré
sudo apt install -y pgbouncer

# Vérifier la version installée
pgbouncer --version
# → PgBouncer 1.22.x
```

### 2.2 Localiser les fichiers de configuration

```bash
# Fichiers de configuration Ubuntu
ls -la /etc/pgbouncer/
# → pgbouncer.ini   userlist.txt

# Fichier log
ls -la /var/log/postgresql/ | grep bouncer

# Répertoires utilisés
echo "Config : /etc/pgbouncer/pgbouncer.ini"
echo "Users  : /etc/pgbouncer/userlist.txt"
echo "PID    : /var/run/postgresql/pgbouncer.pid"
echo "Log    : /var/log/postgresql/pgbouncer.log"
```

---

## PARTIE 3 — Configuration de PgBouncer

### 3.1 Créer le fichier de configuration principal

```bash
# Sauvegarder la configuration originale
sudo cp /etc/pgbouncer/pgbouncer.ini /etc/pgbouncer/pgbouncer.ini.bak

# Créer la configuration complète pour le lab
sudo bash -c 'cat > /etc/pgbouncer/pgbouncer.ini << '"'"'EOF'"'"'
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; PgBouncer Configuration — Lab PostgreSQL 16 · Ubuntu 24.04
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

[databases]
;;;; Mapping bases de données ;;;;

; Base de test pour pgbench
; Format : alias_local = host=... port=... dbname=...
benchdb = host=127.0.0.1 port=5432 dbname=benchdb

; Wildcard : toute autre base → localhost PostgreSQL
; * = host=127.0.0.1 port=5432


[pgbouncer]
;;;; Paramètres réseau ;;;;

; Adresse et port d'écoute de PgBouncer
listen_addr = 127.0.0.1
listen_port = 6432

; Socket Unix (en complément du TCP)
unix_socket_dir = /var/run/postgresql

;;;; Mode de pooling ;;;;
; session     : 1 connexion PG par session client (peu d'intérêt)
; transaction : 1 connexion PG par transaction (RECOMMANDÉ production)
; statement   : 1 connexion PG par requête (très agressif, rarement utilisé)
pool_mode = transaction

;;;; Taille du pool ;;;;

; Connexions clients maximales acceptées par PgBouncer
max_client_conn = 1000

; Connexions PostgreSQL par pool (par base × par utilisateur)
default_pool_size = 25

; Connexions min maintenues ouvertes en permanence
min_pool_size = 5

; Connexions de réserve disponibles si le pool est saturé
reserve_pool_size = 5

; Délai avant d'utiliser les connexions de réserve (secondes)
reserve_pool_timeout = 3

;;;; Timeouts ;;;;

; Timeout pour établir une connexion vers PostgreSQL (secondes)
connect_timeout = 15

; Timeout inactivité client avant déconnexion (0 = illimité)
client_idle_timeout = 0

; Timeout inactivité côté serveur (ferme la connexion PostgreSQL)
server_idle_timeout = 600

; Durée max d'une connexion côté serveur avant recyclage
server_lifetime = 3600

; Timeout max d'une requête (0 = illimité — ne pas activer en production)
query_timeout = 0

; Attente max pour obtenir une connexion du pool
pool_availability_timeout = 5

;;;; Authentification ;;;;

; Type d'authentification : scram-sha-256 recommandé
auth_type = scram-sha-256

; Fichier contenant les utilisateurs et mots de passe
auth_file = /etc/pgbouncer/userlist.txt

;;;; Administration ;;;;

; Utilisateurs autorisés à administrer PgBouncer via SHOW commandes
admin_users = postgres

; Utilisateurs autorisés à voir les statistiques
stats_users = postgres, benchuser

;;;; Logging ;;;;

; Fichier de log
logfile = /var/log/postgresql/pgbouncer.log

; PID file
pidfile = /var/run/postgresql/pgbouncer.pid

; Niveau de log : 0=critique 1=erreur 2=warning 3=info 4=debug
log_level = info

; Logger les connexions clients
log_connections = 1

; Logger les déconnexions clients
log_disconnections = 1

; Logger les erreurs du pooler
log_pooler_errors = 1

; Logger les statistiques toutes les N secondes (0 = désactivé)
stats_period = 60

;;;; Paramètres avancés ;;;;

; Ignorer les paramètres de démarrage inconnus (utile pour certains ORM)
ignore_startup_parameters = extra_float_digits

; Réinitialiser la connexion avant de la remettre dans le pool
; Envoie DISCARD ALL entre les transactions (session pooling)
; En mode transaction, désactiver pour la performance
server_reset_query = DISCARD ALL
server_reset_query_always = 0

; Nombre de secondes avant de considérer un serveur PG comme mort
server_check_delay = 30

; Requête de vérification de vie d'une connexion serveur
server_check_query = SELECT 1

EOF'
```

### 3.2 Créer le fichier d'utilisateurs (userlist.txt)

PgBouncer a besoin des mots de passe des utilisateurs pour authentifier les clients. Il y a deux méthodes :

**Méthode A — Hash SCRAM-SHA-256 depuis PostgreSQL (recommandée)**

```bash
# Récupérer le hash du mot de passe depuis PostgreSQL
sudo -u postgres psql -At -c \
  "SELECT '\"' || rolname || '\" \"' || rolpassword || '\"'
   FROM pg_authid
   WHERE rolname IN ('benchuser', 'postgres');"
```

**Sortie attendue (exemple) :**
```
"benchuser" "SCRAM-SHA-256$4096:abc123...=="
"postgres" "SCRAM-SHA-256$4096:xyz789...=="
```

```bash
# Créer le fichier userlist.txt avec les hashes obtenus
# ATTENTION : remplacer les valeurs SCRAM-SHA-256$... par celles obtenues ci-dessus
sudo bash -c 'cat > /etc/pgbouncer/userlist.txt << '"'"'EOF'"'"'
# Format : "username" "password_hash"
# Les hashes SCRAM-SHA-256 sont obtenus depuis pg_authid
"benchuser" "SCRAM-SHA-256$4096:REMPLACER_PAR_HASH_OBTENU"
"postgres" "SCRAM-SHA-256$4096:REMPLACER_PAR_HASH_OBTENU"
EOF'
```

**Script automatique pour peupler userlist.txt :**

```bash
# Script qui récupère automatiquement les hashes et crée userlist.txt
sudo -u postgres psql -At -c \
  "SELECT '\"' || rolname || '\" \"' || rolpassword || '\"'
   FROM pg_authid
   WHERE rolname IN ('benchuser', 'postgres')
     AND rolpassword IS NOT NULL;" \
  | sudo tee /etc/pgbouncer/userlist.txt

# Vérifier le contenu
cat /etc/pgbouncer/userlist.txt
```

```bash
# Définir les permissions correctes
sudo chown postgres:postgres /etc/pgbouncer/userlist.txt
sudo chmod 640 /etc/pgbouncer/userlist.txt

sudo chown postgres:postgres /etc/pgbouncer/pgbouncer.ini
sudo chmod 640 /etc/pgbouncer/pgbouncer.ini
```

### 3.3 Créer le répertoire de log si nécessaire

```bash
# Vérifier que le répertoire de log existe
ls -la /var/log/postgresql/

# Créer le fichier de log et lui donner les bons droits
sudo touch /var/log/postgresql/pgbouncer.log
sudo chown postgres:postgres /var/log/postgresql/pgbouncer.log
sudo chmod 640 /var/log/postgresql/pgbouncer.log
```

---

## PARTIE 4 — Démarrage et vérification de PgBouncer

### 4.1 Démarrer PgBouncer

```bash
# Démarrer le service
sudo systemctl start pgbouncer

# Activer le démarrage automatique
sudo systemctl enable pgbouncer

# Vérifier l'état
sudo systemctl status pgbouncer
# → Active: active (running)
```

### 4.2 Vérifier les logs de démarrage

```bash
# Voir les logs de démarrage
sudo tail -30 /var/log/postgresql/pgbouncer.log
```

**Sortie attendue :**
```
2024-01-15 10:30:00.123 UTC [12345] LOG kernel file descriptor limit: 1048576
2024-01-15 10:30:00.124 UTC [12345] LOG listening on 127.0.0.1:6432
2024-01-15 10:30:00.125 UTC [12345] LOG listening on /var/run/postgresql/.s.PGSQL.6432
2024-01-15 10:30:00.126 UTC [12345] LOG process up: PgBouncer 1.22.x
```

### 4.3 Vérifier que PgBouncer écoute sur le bon port

```bash
# Vérifier les ports ouverts
ss -tlnp | grep 6432
# → LISTEN   0   ...   127.0.0.1:6432   ...   pgbouncer

# Alternative avec netstat
netstat -tlnp 2>/dev/null | grep 6432
```

### 4.4 Tester la connexion via PgBouncer

```bash
# Test de connexion basic via PgBouncer (port 6432)
psql -h 127.0.0.1 -p 6432 -U benchuser -d benchdb \
  -c "SELECT current_database(), inet_server_port(), now();"
# Saisir le mot de passe : Bench#2024!

# Résultat attendu :
# current_database | inet_server_port |              now
# -----------------+------------------+-------------------------------
# benchdb          |             5432 | 2024-01-15 10:30:00.000+00
#
# NOTER : inet_server_port() retourne 5432 (PostgreSQL)
# car PgBouncer proxifie vers PostgreSQL sur le port 5432
```

```bash
# Vérifier que le compte de lignes est correct
psql -h 127.0.0.1 -p 6432 -U benchuser -d benchdb \
  -c "SELECT COUNT(*) FROM pgbench_accounts;"
# → 1 000 000
```

### 4.5 Accéder à la console d'administration PgBouncer

PgBouncer possède une base virtuelle `pgbouncer` pour l'administration.

```bash
# Se connecter à la console d'administration
psql -h 127.0.0.1 -p 6432 -U postgres -d pgbouncer

# Dans la console PgBouncer :

-- Voir les pools actifs
SHOW POOLS;

-- Voir les bases de données configurées
SHOW DATABASES;

-- Voir les statistiques de connexion
SHOW STATS;

-- Voir les serveurs PostgreSQL connectés
SHOW SERVERS;

-- Voir les clients connectés
SHOW CLIENTS;

-- Voir la configuration active
SHOW CONFIG;

-- Quitter
\q
```

**Sortie de `SHOW POOLS` :**
```
 database  | user      | cl_active | cl_waiting | sv_active | sv_idle | sv_used | sv_tested | sv_login | maxwait
-----------+-----------+-----------+------------+-----------+---------+---------+-----------+----------+---------
 benchdb   | benchuser |         0 |          0 |         0 |       5 |       0 |         0 |        0 |       0
```

---

## PARTIE 5 — Benchmark SANS PgBouncer (référence)

> ⚠️ Cette partie établit la **référence de performance** en se connectant **directement** à PostgreSQL (port 5432) sans PgBouncer. Garder ces résultats pour la comparaison finale.

### 5.1 Réinitialiser les statistiques

```bash
# Réinitialiser pg_stat_statements pour avoir des métriques propres
sudo -u postgres psql -d benchdb -c "SELECT pg_stat_reset();"
sudo -u postgres psql -d benchdb -c "SELECT pg_stat_statements_reset();"
```

### 5.2 Test pgbench SANS PgBouncer — Faible concurrence

```bash
echo "======================================"
echo "TEST 1 : SANS PgBouncer — 10 clients"
echo "Port 5432 — Connexion directe PostgreSQL"
echo "======================================"

pgbench \
  -h 127.0.0.1 \
  -p 5432 \
  -U benchuser \
  -d benchdb \
  -c 10 \
  -j 2 \
  -T 30 \
  -P 5 \
  --progress-timestamp
# Saisir le mot de passe : Bench#2024!
```

**Paramètres :**
- `-c 10` : 10 clients simultanés
- `-j 2` : 2 threads pgbench
- `-T 30` : durée 30 secondes
- `-P 5` : afficher les stats toutes les 5 secondes

**Noter les résultats :**
```
# Résultats à noter :
# tps (transactions per second including connections) : ________
# tps (transactions per second excluding connections) : ________
# latency average : ________ ms
```

### 5.3 Test pgbench SANS PgBouncer — Concurrence moyenne

```bash
echo "======================================"
echo "TEST 2 : SANS PgBouncer — 50 clients"
echo "Port 5432 — Connexion directe PostgreSQL"
echo "======================================"

pgbench \
  -h 127.0.0.1 \
  -p 5432 \
  -U benchuser \
  -d benchdb \
  -c 50 \
  -j 4 \
  -T 60 \
  -P 10
```

**Noter les résultats :**
```
# tps (with connections)    : ________
# tps (without connections) : ________
# latency average           : ________ ms
# latency stddev            : ________ ms
```

### 5.4 Test pgbench SANS PgBouncer — Forte concurrence

```bash
echo "======================================"
echo "TEST 3 : SANS PgBouncer — 100 clients"
echo "Port 5432 — Connexion directe PostgreSQL"
echo "======================================"

pgbench \
  -h 127.0.0.1 \
  -p 5432 \
  -U benchuser \
  -d benchdb \
  -c 100 \
  -j 8 \
  -T 60 \
  -P 10
```

**Notable :** Avec 100 clients, PostgreSQL va créer 100 processus backend simultanément. Observer la charge mémoire avec `htop`.

```bash
# Dans un autre terminal, observer la charge pendant le bench
watch -n 1 'ps aux | grep postgres | grep -v grep | wc -l'
# → doit afficher ~100+ processus PostgreSQL
```

### 5.5 Vérifier les connexions PostgreSQL pendant le test

```bash
# Nombre de connexions actives sur PostgreSQL
sudo -u postgres psql -c "
SELECT count(*) AS total_connexions,
       count(*) FILTER (WHERE state = 'active')  AS actives,
       count(*) FILTER (WHERE state = 'idle')    AS idle,
       count(*) FILTER (WHERE wait_event IS NOT NULL) AS en_attente
FROM pg_stat_activity
WHERE datname = 'benchdb';"
```

---

## PARTIE 6 — Benchmark AVEC PgBouncer

> ✔️ Même benchmark, mais en passant par PgBouncer (port 6432). PgBouncer va maintenir un pool de 25 connexions vers PostgreSQL quel que soit le nombre de clients.

### 6.1 Vérifier l'état de PgBouncer avant le test

```bash
# S'assurer que PgBouncer fonctionne
sudo systemctl status pgbouncer

# Voir l'état du pool (doit montrer min_pool_size = 5 connexions idle)
psql -h 127.0.0.1 -p 6432 -U postgres -d pgbouncer -c "SHOW POOLS;"
```

### 6.2 Test pgbench AVEC PgBouncer — Faible concurrence

```bash
echo "======================================"
echo "TEST 4 : AVEC PgBouncer — 10 clients"
echo "Port 6432 — Via PgBouncer"
echo "======================================"

pgbench \
  -h 127.0.0.1 \
  -p 6432 \
  -U benchuser \
  -d benchdb \
  -c 10 \
  -j 2 \
  -T 30 \
  -P 5 \
  --progress-timestamp
```

**⚠️ Important :** En mode `transaction pooling`, pgbench doit utiliser des transactions explicites. Si pgbench génère des erreurs, utiliser le flag `--no-vacuum` :

```bash
# Si erreurs de préparation de requêtes :
pgbench \
  -h 127.0.0.1 \
  -p 6432 \
  -U benchuser \
  -d benchdb \
  -c 10 \
  -j 2 \
  -T 30 \
  -P 5 \
  -M simple
# -M simple : utilise le protocole simple (compatible transaction pooling)
```

### 6.3 Test pgbench AVEC PgBouncer — Concurrence moyenne

```bash
echo "======================================"
echo "TEST 5 : AVEC PgBouncer — 50 clients"
echo "Port 6432 — Via PgBouncer"
echo "======================================"

pgbench \
  -h 127.0.0.1 \
  -p 6432 \
  -U benchuser \
  -d benchdb \
  -c 50 \
  -j 4 \
  -T 60 \
  -P 10 \
  -M simple
```

### 6.4 Test pgbench AVEC PgBouncer — Forte concurrence

```bash
echo "======================================"
echo "TEST 6 : AVEC PgBouncer — 100 clients"
echo "Port 6432 — Via PgBouncer"
echo "======================================"

pgbench \
  -h 127.0.0.1 \
  -p 6432 \
  -U benchuser \
  -d benchdb \
  -c 100 \
  -j 8 \
  -T 60 \
  -P 10 \
  -M simple
```

### 6.5 Test AVEC PgBouncer — Surcharge (200 clients)

```bash
echo "======================================"
echo "TEST 7 : AVEC PgBouncer — 200 clients"
echo "Port 6432 — Via PgBouncer (pool = 25 conn PG)"
echo "======================================"

# IMPOSSIBLE sans PgBouncer (max_connections = 200)
# AVEC PgBouncer : 200 clients → 25 connexions PostgreSQL
pgbench \
  -h 127.0.0.1 \
  -p 6432 \
  -U benchuser \
  -d benchdb \
  -c 200 \
  -j 8 \
  -T 60 \
  -P 10 \
  -M simple
```

```bash
# Pendant ce test, observer les connexions réelles sur PostgreSQL
# AVEC 200 clients pgbench → seulement ~25 connexions PG !
sudo -u postgres psql -c "
SELECT count(*) AS connexions_pg_reelles
FROM pg_stat_activity
WHERE datname = 'benchdb'
  AND usename = 'benchuser';"
```

### 6.6 Observer les statistiques PgBouncer en temps réel

```bash
# Dans un terminal séparé, pendant le benchmark :
watch -n 2 'psql -h 127.0.0.1 -p 6432 -U postgres -d pgbouncer \
  -c "SHOW STATS;" 2>/dev/null'
```

**Sortie de `SHOW STATS` :**
```
 database  | total_xact_count | total_query_count | total_received | total_sent | avg_xact_count | avg_query_count | avg_recv | avg_sent | avg_xact_time | avg_query_time | avg_wait_time
-----------+------------------+-------------------+----------------+------------+----------------+-----------------+----------+----------+---------------+----------------+---------------
 benchdb   |           127453 |            127453 |      213847291 |  412938471 |           4248 |            4248 |     7128 |    13764 |         23.45 |          23.45 |          1.23
```

---

## PARTIE 7 — Tableau de résultats comparatifs

Remplir ce tableau au fur et à mesure des tests :

| Test | Port | Clients | TPS (avec conn.) | TPS (sans conn.) | Latence moy. (ms) | Conn. PG réelles |
|------|------|---------|-----------------|-----------------|-------------------|-----------------|
| 1 — Sans PgBouncer | 5432 | 10 | | | | 10 |
| 2 — Sans PgBouncer | 5432 | 50 | | | | 50 |
| 3 — Sans PgBouncer | 5432 | 100 | | | | 100 |
| 4 — Avec PgBouncer | 6432 | 10 | | | | ~5-10 |
| 5 — Avec PgBouncer | 6432 | 50 | | | | ~25 |
| 6 — Avec PgBouncer | 6432 | 100 | | | | ~25 |
| 7 — Avec PgBouncer | 6432 | 200 | | | | ~25 |

### Ce que vous devriez observer

```
ATTENDU — Résultats typiques :
┌──────────────────────────────────────────────────────────────────┐
│                                                                  │
│  10 clients  → performances similaires (overhead PgBouncer ~2%) │
│                                                                  │
│  50 clients  → PgBouncer légèrement meilleur (moins de RAM PG)  │
│                                                                  │
│  100 clients → PgBouncer nettement meilleur (moins de context   │
│                switch OS, moins de RAM PostgreSQL)               │
│                                                                  │
│  200 clients → Sans PgBouncer : IMPOSSIBLE ou très lent          │
│               Avec PgBouncer : fonctionne normalement            │
│               (25 connexions PG pour 200 clients)                │
│                                                                  │
│  Gain principal : économie de RAM (~10 Mo/connexion PG évitée)  │
│                   Réduction du context-switch OS                 │
│                   Protection contre connection storm             │
└──────────────────────────────────────────────────────────────────┘
```

---

## PARTIE 8 — Analyse approfondie des résultats

### 8.1 Requêtes SQL d'analyse post-benchmark

```sql
-- Connexion : sudo -u postgres psql -d benchdb

-- Statistiques de connexion pendant les tests
SELECT
  usename,
  count(*)                                          AS total_connexions,
  count(*) FILTER (WHERE state = 'active')          AS actives,
  count(*) FILTER (WHERE state = 'idle')            AS idle,
  count(*) FILTER (WHERE state = 'idle in transaction') AS idle_in_tx
FROM pg_stat_activity
WHERE datname = 'benchdb'
GROUP BY usename;
```

```sql
-- Activité de la base pendant le benchmark
SELECT
  numbackends          AS connexions_actives,
  xact_commit          AS transactions_validées,
  xact_rollback        AS transactions_annulées,
  blks_read            AS blocs_lus_disque,
  blks_hit             AS blocs_lus_cache,
  ROUND(blks_hit::numeric / NULLIF(blks_hit + blks_read, 0) * 100, 2)
                       AS taux_cache_pct,
  tup_returned         AS tuples_retournés,
  tup_fetched          AS tuples_récupérés,
  tup_inserted         AS tuples_insérés,
  tup_updated          AS tuples_modifiés
FROM pg_stat_database
WHERE datname = 'benchdb';
```

```sql
-- Top 10 requêtes les plus exécutées (pg_stat_statements)
SELECT
  LEFT(query, 80)                                     AS requête,
  calls                                               AS nb_appels,
  ROUND(total_exec_time::numeric, 0)                  AS total_ms,
  ROUND((total_exec_time / calls)::numeric, 2)        AS moy_ms,
  ROUND(rows::numeric / calls, 1)                     AS lignes_moy
FROM pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = 'benchdb')
ORDER BY total_exec_time DESC
LIMIT 10;
```

```sql
-- Taux de cache PostgreSQL (shared_buffers)
SELECT
  c.relname                                           AS table,
  ROUND(100.0 * pg_stat_get_blocks_hit(c.oid)
    / NULLIF(pg_stat_get_blocks_hit(c.oid)
           + pg_stat_get_blocks_fetched(c.oid), 0), 1) AS cache_hit_pct
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relkind = 'r'
  AND c.relname LIKE 'pgbench_%'
ORDER BY c.relname;
```

### 8.2 Statistiques PgBouncer depuis la console

```bash
# Se connecter à la console PgBouncer
psql -h 127.0.0.1 -p 6432 -U postgres -d pgbouncer
```

```sql
-- Vue complète des pools
SHOW POOLS;

-- Statistiques cumulées depuis le démarrage
SHOW STATS;

-- Statistiques moyennes sur la dernière période
SHOW STATS_AVERAGES;

-- Connexions serveur (vers PostgreSQL)
SHOW SERVERS;
-- sv_active : connexions PG avec un client
-- sv_idle   : connexions PG disponibles dans le pool
-- sv_used   : connexions PG récemment utilisées

-- Connexions client (depuis pgbench)
SHOW CLIENTS;

-- Configuration actuelle
SHOW CONFIG;

-- Listes des bases disponibles
SHOW DATABASES;

-- Version PgBouncer
SHOW VERSION;
```

**Interprétation de `SHOW POOLS` :**

| Colonne | Signification |
|---|---|
| `cl_active` | Clients avec une connexion serveur assignée |
| `cl_waiting` | Clients en attente d'une connexion (pool plein) |
| `sv_active` | Connexions PostgreSQL avec un client actif |
| `sv_idle` | Connexions PostgreSQL libres dans le pool |
| `sv_used` | Connexions PostgreSQL récemment libérées |
| `maxwait` | Attente maximale d'un client (secondes) |

---

## PARTIE 9 — Configurations avancées

### 9.1 Tester les différents modes de pooling

PgBouncer supporte 3 modes. Modifier `pool_mode` dans `pgbouncer.ini` et relancer les tests pour comparer.

```bash
# Modifier le mode de pooling
sudo vim /etc/pgbouncer/pgbouncer.ini

# Changer pool_mode = session | transaction | statement
```

| Mode | Comportement | Cas d'usage |
|---|---|---|
| `session` | 1 connexion PG par session client (comme sans pooler) | Migration initiale, debugging |
| `transaction` | 1 connexion PG par transaction (**RECOMMANDÉ**) | Production, applications web |
| `statement` | 1 connexion PG par requête | Très rare, requêtes atomiques uniquement |

```bash
# Recharger PgBouncer sans coupure de service
sudo systemctl reload pgbouncer

# Ou via la console d'admin
psql -h 127.0.0.1 -p 6432 -U postgres -d pgbouncer -c "RELOAD;"
```

### 9.2 Ajuster default_pool_size

```bash
# Tester avec un pool plus grand
# Dans pgbouncer.ini : default_pool_size = 50

sudo systemctl reload pgbouncer

# Relancer le test 200 clients et comparer
pgbench \
  -h 127.0.0.1 -p 6432 \
  -U benchuser -d benchdb \
  -c 200 -j 8 -T 60 -P 10 -M simple
```

### 9.3 Activer auth_query (alternative à userlist.txt)

Au lieu de stocker les mots de passe dans un fichier, PgBouncer peut interroger PostgreSQL directement.

```bash
# Créer une fonction d'authentification dans PostgreSQL
sudo -u postgres psql << 'SQL'

-- Créer un utilisateur dédié à l'authentification PgBouncer
CREATE ROLE pgbouncer WITH
  LOGIN
  PASSWORD 'pgBouncer#Auth2024!'
  NOSUPERUSER;

-- Créer la fonction d'auth (accès à pg_shadow réservé aux superusers)
CREATE OR REPLACE FUNCTION pgbouncer.get_auth(uname TEXT)
RETURNS TABLE(username TEXT, password TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  RETURN QUERY
  SELECT usename::TEXT, passwd::TEXT
  FROM pg_shadow
  WHERE usename = uname;
END;
$$;

-- Donner l'accès à pgbouncer
GRANT EXECUTE ON FUNCTION pgbouncer.get_auth(TEXT) TO pgbouncer;

SQL
```

```bash
# Dans pgbouncer.ini, ajouter :
# auth_user = pgbouncer
# auth_query = SELECT username, password FROM pgbouncer.get_auth($1)
# auth_file peut être vide ou supprimé
```

### 9.4 Configurer le monitoring via pg_hba

```bash
# Voir les connexions PgBouncer vs directes en temps réel
sudo -u postgres psql -c "
SELECT
  application_name,
  client_addr,
  usename,
  datname,
  state,
  wait_event_type,
  wait_event,
  now() - backend_start AS durée_session,
  now() - xact_start    AS durée_tx
FROM pg_stat_activity
WHERE datname IS NOT NULL
  AND pid <> pg_backend_pid()
ORDER BY backend_start;"
```

---

## PARTIE 10 — Opérations de maintenance PgBouncer

### 10.1 Recharger la configuration sans coupure

```bash
# Après modification de pgbouncer.ini
sudo systemctl reload pgbouncer

# Via la console d'admin (sans interrompre les connexions actives)
psql -h 127.0.0.1 -p 6432 -U postgres -d pgbouncer -c "RELOAD;"

# Vérifier que la nouvelle config est prise en compte
psql -h 127.0.0.1 -p 6432 -U postgres -d pgbouncer -c "SHOW CONFIG;" | grep pool_mode
```

### 10.2 Mettre une base en pause (maintenance PostgreSQL)

```bash
# Suspendre le trafic vers benchdb (ex : pendant un VACUUM FULL)
psql -h 127.0.0.1 -p 6432 -U postgres -d pgbouncer \
  -c "PAUSE benchdb;"

# Faire la maintenance sur PostgreSQL...
sudo -u postgres psql -d benchdb -c "VACUUM FULL pgbench_accounts;"

# Reprendre le trafic
psql -h 127.0.0.1 -p 6432 -U postgres -d pgbouncer \
  -c "RESUME benchdb;"
```

### 10.3 Forcer la fermeture des connexions inactives

```bash
# Fermer les connexions idle côté serveur
psql -h 127.0.0.1 -p 6432 -U postgres -d pgbouncer \
  -c "RECONNECT benchdb;"

# Vider completement le pool d'une base (attention : interruption !)
psql -h 127.0.0.1 -p 6432 -U postgres -d pgbouncer \
  -c "KILL benchdb;"

# Désactiver temporairement une base
psql -h 127.0.0.1 -p 6432 -U postgres -d pgbouncer \
  -c "DISABLE benchdb;"

# Réactiver
psql -h 127.0.0.1 -p 6432 -U postgres -d pgbouncer \
  -c "ENABLE benchdb;"
```

### 10.4 Mettre à jour userlist.txt à chaud

```bash
# Après un changement de mot de passe utilisateur dans PostgreSQL
sudo -u postgres psql -At -c \
  "SELECT '\"' || rolname || '\" \"' || rolpassword || '\"'
   FROM pg_authid
   WHERE rolname IN ('benchuser', 'postgres')
     AND rolpassword IS NOT NULL;" \
  | sudo tee /etc/pgbouncer/userlist.txt

# Recharger sans coupure
sudo systemctl reload pgbouncer
```

### 10.5 Voir les logs en temps réel

```bash
# Suivre les logs PgBouncer
sudo tail -f /var/log/postgresql/pgbouncer.log

# Voir uniquement les connexions et déconnexions
sudo tail -f /var/log/postgresql/pgbouncer.log | grep -E "(login|disconnect|connect)"
```

---

## PARTIE 11 — Dépannage (Troubleshooting)

### Problème : PgBouncer refuse de démarrer

```bash
# Vérifier les logs d'erreur
sudo journalctl -u pgbouncer -n 50 --no-pager
sudo cat /var/log/postgresql/pgbouncer.log | tail -20

# Problèmes courants :
# 1. Permission sur pgbouncer.ini ou userlist.txt
sudo ls -la /etc/pgbouncer/
sudo chown postgres:postgres /etc/pgbouncer/pgbouncer.ini
sudo chown postgres:postgres /etc/pgbouncer/userlist.txt

# 2. Port 6432 déjà utilisé
sudo ss -tlnp | grep 6432

# 3. Syntaxe du fichier .ini incorrecte
sudo pgbouncer -d /etc/pgbouncer/pgbouncer.ini
# affiche l'erreur de syntaxe
```

### Problème : Erreur d'authentification

```bash
# "password authentication failed"
# → Vérifier que userlist.txt contient le bon hash

# Récupérer le hash à nouveau
sudo -u postgres psql -At -c \
  "SELECT rolpassword FROM pg_authid WHERE rolname = 'benchuser';"

# Vérifier le contenu de userlist.txt
sudo cat /etc/pgbouncer/userlist.txt

# Tester la connexion directe PostgreSQL (bypass PgBouncer)
psql -h 127.0.0.1 -p 5432 -U benchuser -d benchdb -c "SELECT 1;"
```

### Problème : pgbench retourne "ERROR: prepared statement already exists"

```bash
# Ce problème arrive en mode transaction pooling avec protocole extended
# Solution : utiliser le protocole simple avec -M simple

pgbench -h 127.0.0.1 -p 6432 -U benchuser -d benchdb \
  -c 50 -j 4 -T 30 \
  -M simple    # ← ajouter ce flag
```

### Problème : "connection to server failed" ou timeout

```bash
# Vérifier que PostgreSQL accepte les connexions depuis PgBouncer
sudo -u postgres psql -c "
SELECT count(*) FROM pg_stat_activity
WHERE client_addr = '127.0.0.1';"

# Vérifier pg_hba.conf
sudo cat /etc/postgresql/16/main/pg_hba.conf | grep benchuser

# Tester la connexion PgBouncer → PostgreSQL directement
sudo -u postgres psql -h 127.0.0.1 -p 5432 -U benchuser -d benchdb -c "SELECT 1;"
```

### Problème : pool saturé, clients en attente

```bash
# Voir les clients en attente
psql -h 127.0.0.1 -p 6432 -U postgres -d pgbouncer \
  -c "SHOW CLIENTS;" | grep waiting

# Augmenter default_pool_size dans pgbouncer.ini
# default_pool_size = 50
sudo systemctl reload pgbouncer
```

---
 
### Règles de dimensionnement du pool

```
Formule recommandée :
  default_pool_size = (nombre de cœurs CPU) × 2 + disques effectifs
  
Exemple : 4 cœurs, 1 disque SSD
  default_pool_size = 4 × 2 + 1 = 9 (arrondi à 10-15 pour la marge)

Règle générale :
  • OLTP classique     : 15-30 connexions par pool
  • Reporting / BI     : 5-10 connexions (longues requêtes)
  • Microservices      : 3-5 connexions par service
  
max_client_conn :
  • Doit être >> max_connections PostgreSQL
  • Typiquement 500 à 5000 selon la charge applicative
```

### Tableau de commandes essentielles

| Action | Commande |
|---|---|
| Démarrer PgBouncer | `sudo systemctl start pgbouncer` |
| Arrêter PgBouncer | `sudo systemctl stop pgbouncer` |
| Recharger la config | `sudo systemctl reload pgbouncer` |
| Voir l'état | `sudo systemctl status pgbouncer` |
| Console d'admin | `psql -h 127.0.0.1 -p 6432 -U postgres -d pgbouncer` |
| Voir les pools | `SHOW POOLS;` (dans la console) |
| Voir les stats | `SHOW STATS;` (dans la console) |
| Pause une base | `PAUSE benchdb;` (dans la console) |
| Reprendre | `RESUME benchdb;` (dans la console) |
| Recharger depuis console | `RELOAD;` (dans la console) |
| Voir les logs | `sudo tail -f /var/log/postgresql/pgbouncer.log` |

---
 

## Résumé — Pourquoi utiliser PgBouncer ?

```
PROBLÈME SANS PGBOUNCER :
  Chaque connexion PostgreSQL = 1 processus OS = ~5-10 Mo RAM
  1000 connexions app → 1000 processus PG → 5-10 Go RAM gaspillée
  Context-switch entre processus → dégradation des performances
  Connection storm (pic soudain) → PostgreSQL surchargé ou crashé

SOLUTION AVEC PGBOUNCER :
  1000 connexions app → PgBouncer → 25 connexions PostgreSQL
  RAM économisée : (1000 - 25) × 7 Mo ≈ 6,8 Go libérés
  PostgreSQL ne voit que 25 processus → beaucoup moins de context-switch
  PgBouncer absorbe les pics → PostgreSQL reste stable

QUAND NE PAS UTILISER PGBOUNCER :
  • Applications utilisant LISTEN/NOTIFY (incompatible transaction pooling)
  • Applications utilisant des curseurs persistants entre transactions
  • Applications utilisant SET (variables de session) entre transactions
  • Très peu de connexions (< 20) → overhead inutile
  → Dans ces cas : utiliser pool_mode = session
```

---