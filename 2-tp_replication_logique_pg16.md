# TP — Réplication Logique PostgreSQL 16
## Deux clusters sur une même machine virtuelle

---

## Informations du Lab


| Cluster SOURCE (Primaire) | Port **5432** — répertoire `/var/lib/postgresql/16/source` |
| Cluster DESTINATION (Abonné) | Port **5433** — répertoire `/var/lib/postgresql/16/dest` |
| Base source | `lab_source` |
| Base destination | `lab_dest` |
| Utilisateur de réplication | `replicateur` |

> **Convention** : toutes les commandes préfixées par `[SOURCE]` s'exécutent sur le cluster en port 5432.
> Toutes celles préfixées par `[DEST]` s'exécutent sur le cluster en port 5433.

---

## Prérequis

PostgreSQL 16 installé. Vérifier la version :

```bash
psql --version
# PostgreSQL 16.x
```

---

## PARTIE 0 — Initialisation des deux clusters

### 0.1 Créer les deux clusters PostgreSQL

```bash
# Cluster SOURCE (port 5432)
pg_createcluster 16 source --port=5432
pg_ctlcluster 16 source start

# Cluster DESTINATION (port 5433)
pg_createcluster 16 dest --port=5433
pg_ctlcluster 16 dest start

# Vérifier que les deux clusters tournent
pg_lsclusters
```

**Résultat attendu :**

```
Ver Cluster Port Status Owner    Data directory
16  source  5432 online postgres /var/lib/postgresql/16/source
16  dest    5433 online postgres /var/lib/postgresql/16/dest
```

### 0.2 Créer les bases de données

```bash
# [SOURCE] Créer la base source
psql -p 5432 -U postgres -c "CREATE DATABASE lab_source;"

# [DEST] Créer la base destination
psql -p 5433 -U postgres -c "CREATE DATABASE lab_dest;"
```

---

## PARTIE 1 — Préparation du cluster SOURCE

### 1.1 Configurer postgresql.conf

```bash
# Éditer la configuration du cluster source
nano /etc/postgresql/16/source/postgresql.conf
```

Modifier ou vérifier les paramètres suivants :

```ini
# Réplication logique — obligatoire
wal_level = logical

# Nombre max de slots de réplication (un par souscription)
max_replication_slots = 10

# Nombre max de processus WAL sender
max_wal_senders = 10

# Optionnel : conserver les WAL plus longtemps (utile si le dest est lent)
wal_keep_size = 256
```

Vérifier la valeur active sans redémarrer :

```bash
psql -p 5432 -U postgres -c "SHOW wal_level;"
```

> Si `wal_level` n'est pas encore `logical`, redémarrer le cluster source est obligatoire.

```bash
pg_ctlcluster 16 source restart
psql -p 5432 -U postgres -c "SHOW wal_level;"
# Résultat attendu : logical
```

### 1.2 Configurer pg_hba.conf

```bash
nano /etc/postgresql/16/source/pg_hba.conf
```

Ajouter la ligne suivante pour autoriser le replicateur depuis localhost :

```
# Réplication logique — même machine, port 5433 → 5432
host    lab_source    replicateur    127.0.0.1/32    scram-sha-256
```

Recharger la configuration (pas besoin de redémarrage) :

```bash
pg_ctlcluster 16 source reload
```

### 1.3 Créer le rôle replicateur

```bash
psql -p 5432 -U postgres
```

```sql
-- [SOURCE] Créer le rôle de réplication
CREATE ROLE replicateur
  WITH LOGIN
  REPLICATION
  PASSWORD 'RepliPass2024!';

-- Donner accès à la base source
GRANT CONNECT ON DATABASE lab_source TO replicateur;

-- Se connecter à lab_source pour donner les droits SELECT
\c lab_source

-- Droits sur les tables existantes
GRANT SELECT ON ALL TABLES IN SCHEMA public TO replicateur;

-- Droits automatiques sur les futures tables
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT ON TABLES TO replicateur;

\q
```

### 1.4 Créer les tables de test

```bash
psql -p 5432 -U postgres -d lab_source
```

```sql
-- [SOURCE] Créer les tables du lab

CREATE TABLE clients (
    id          SERIAL PRIMARY KEY,
    nom         VARCHAR(100) NOT NULL,
    email       VARCHAR(150) UNIQUE NOT NULL,
    ville       VARCHAR(100),
    statut      VARCHAR(20) DEFAULT 'actif',
    created_at  TIMESTAMP DEFAULT NOW()
);

CREATE TABLE commandes (
    id          SERIAL PRIMARY KEY,
    client_id   INTEGER REFERENCES clients(id),
    montant     NUMERIC(10,2) NOT NULL,
    statut      VARCHAR(30) DEFAULT 'en_attente',
    created_at  TIMESTAMP DEFAULT NOW()
);

CREATE TABLE produits (
    id          SERIAL PRIMARY KEY,
    nom         VARCHAR(150) NOT NULL,
    prix        NUMERIC(10,2) NOT NULL,
    stock       INTEGER DEFAULT 0
);

CREATE TABLE logs_application (
    id          SERIAL PRIMARY KEY,
    niveau      VARCHAR(10),
    message     TEXT,
    created_at  TIMESTAMP DEFAULT NOW()
);

-- Insérer des données initiales
INSERT INTO clients (nom, email, ville, statut) VALUES
  ('Alice Martin',   'alice@example.com',   'Paris',     'actif'),
  ('Bob Dupont',     'bob@example.com',     'Lyon',      'actif'),
  ('Claire Lebrun',  'claire@example.com',  'Marseille', 'inactif'),
  ('David Moreau',   'david@example.com',   'Bordeaux',  'actif'),
  ('Eve Lambert',    'eve@example.com',     'Lille',     'actif');

INSERT INTO produits (nom, prix, stock) VALUES
  ('Laptop Pro',   1299.99, 50),
  ('Souris USB',     19.99, 200),
  ('Clavier mécanique', 89.99, 75),
  ('Écran 27"',    349.99, 30);

INSERT INTO commandes (client_id, montant, statut) VALUES
  (1, 1299.99, 'livree'),
  (2,   19.99, 'en_attente'),
  (1,   89.99, 'livree'),
  (4,  349.99, 'en_cours'),
  (5,   19.99, 'annulee');

INSERT INTO logs_application (niveau, message) VALUES
  ('INFO',  'Démarrage application'),
  ('WARN',  'Connexion lente détectée'),
  ('ERROR', 'Timeout base de données'),
  ('INFO',  'Sauvegarde terminée');

-- Vérifier
SELECT 'clients' AS table, COUNT(*) FROM clients
UNION ALL
SELECT 'commandes', COUNT(*) FROM commandes
UNION ALL
SELECT 'produits',  COUNT(*) FROM produits
UNION ALL
SELECT 'logs',      COUNT(*) FROM logs_application;
```



---

## PARTIE 2 — Préparation du cluster DESTINATION

### 2.1 Créer les tables sur la destination

> **Important** : la réplication logique ne réplique pas le DDL (CREATE TABLE). Les tables doivent exister sur la destination avant de créer la souscription.

```bash
psql -p 5433 -U postgres -d lab_dest
```

```sql
-- [DEST] Copie exacte du DDL source (sans les données)

CREATE TABLE clients (
    id          SERIAL PRIMARY KEY,
    nom         VARCHAR(100) NOT NULL,
    email       VARCHAR(150) UNIQUE NOT NULL,
    ville       VARCHAR(100),
    statut      VARCHAR(20) DEFAULT 'actif',
    created_at  TIMESTAMP DEFAULT NOW()
);

CREATE TABLE commandes (
    id          SERIAL PRIMARY KEY,
    client_id   INTEGER,   -- Pas de FK en réplication logique (optionnel)
    montant     NUMERIC(10,2) NOT NULL,
    statut      VARCHAR(30) DEFAULT 'en_attente',
    created_at  TIMESTAMP DEFAULT NOW()
);

CREATE TABLE produits (
    id          SERIAL PRIMARY KEY,
    nom         VARCHAR(150) NOT NULL,
    prix        NUMERIC(10,2) NOT NULL,
    stock       INTEGER DEFAULT 0
);

CREATE TABLE logs_application (
    id          SERIAL PRIMARY KEY,
    niveau      VARCHAR(10),
    message     TEXT,
    created_at  TIMESTAMP DEFAULT NOW()
);

-- Vérifier que les tables sont vides
SELECT 'clients'  AS table, COUNT(*) FROM clients
UNION ALL
SELECT 'commandes', COUNT(*) FROM commandes
UNION ALL
SELECT 'produits',  COUNT(*) FROM produits
UNION ALL
SELECT 'logs',      COUNT(*) FROM logs_application;

\q
```

---

##  1 — Publication et Souscription de base

### Objectif
Répliquer toutes les tables de `lab_source` vers `lab_dest` et observer la synchronisation initiale (copy_data) puis le suivi en temps réel.

---

### Étape 1 : Créer la publication sur le SOURCE

```bash
psql -p 5432 -U postgres -d lab_source
```

```sql
-- [SOURCE] Publication de toutes les tables
CREATE PUBLICATION pub_tout FOR ALL TABLES;

-- Vérifier la publication créée
SELECT pubname, puballtables, pubinsert, pubupdate, pubdelete, pubtruncate
FROM pg_publication;
```

**Résultat attendu :**

```
 pubname  | puballtables | pubinsert | pubupdate | pubdelete | pubtruncate
----------+--------------+-----------+-----------+-----------+-------------
 pub_tout | t            | t         | t         | t         | t
```

```sql
-- Lister les tables incluses
SELECT pubname, schemaname, tablename
FROM pg_publication_tables
ORDER BY tablename;

\q
```

---

### Étape 2 : Créer la souscription sur la DESTINATION

```bash
psql -p 5433 -U postgres -d lab_dest
```

```sql
-- [DEST] Créer la souscription
-- copy_data = true (défaut) : copie les données existantes au moment de la création
CREATE SUBSCRIPTION sub_tout
  CONNECTION 'host=127.0.0.1 port=5432 dbname=lab_source
              user=replicateur password=RepliPass2024!'
  PUBLICATION pub_tout;
```

> PostgreSQL va immédiatement lancer la synchronisation initiale (copy_data). Les données existantes sur le SOURCE sont copiées vers la DEST.

```sql
-- Vérifier l'état de la souscription
SELECT subname, subenabled, subslotname, subpublications
FROM pg_subscription;
```

**Résultat attendu :**

```
 subname  | subenabled | subslotname | subpublications
----------+------------+-------------+-----------------
 sub_tout | t          | sub_tout    | {pub_tout}
```

---

### Étape 3 : Vérifier la synchronisation initiale

```sql
-- [DEST] Vérifier que les données ont bien été copiées
SELECT 'clients'  AS table, COUNT(*) FROM clients
UNION ALL
SELECT 'commandes', COUNT(*) FROM commandes
UNION ALL
SELECT 'produits',  COUNT(*) FROM produits
UNION ALL
SELECT 'logs',      COUNT(*) FROM logs_application;
```

**Résultat attendu :** mêmes compteurs que sur le SOURCE (5, 5, 4, 4).

---

### Étape 4 : Tester la réplication en temps réel

**Terminal 1 — surveiller la destination en continu :**

```bash
watch -n 1 "psql -p 5433 -U postgres -d lab_dest -c \
  \"SELECT id, nom, email FROM clients ORDER BY id;\""
```

**Terminal 2 — insérer des données sur le source :**

```bash
psql -p 5432 -U postgres -d lab_source
```

```sql
-- [SOURCE] Insérer un nouveau client
INSERT INTO clients (nom, email, ville, statut)
VALUES ('Frank Duval', 'frank@example.com', 'Nantes', 'actif');

-- Attendre 1-2 secondes, observer Terminal 1
-- Le client Frank doit apparaître sur la DESTINATION

-- Modifier un client existant
UPDATE clients SET ville = 'Strasbourg' WHERE nom = 'Alice Martin';

-- Supprimer un enregistrement
DELETE FROM commandes WHERE statut = 'annulee';

\q
```

**Vérifier sur la DEST :**

```bash
psql -p 5433 -U postgres -d lab_dest -c \
  "SELECT nom, ville FROM clients WHERE nom IN ('Alice Martin','Frank Duval');"
```

**Résultat attendu :**

```
     nom      |    ville
--------------+------------
 Alice Martin | Strasbourg
 Frank Duval  | Nantes
```

---

### Étape 5 : Vérifier le slot de réplication côté SOURCE

```bash
psql -p 5432 -U postgres -c \
  "SELECT slot_name, plugin, slot_type, active, restart_lsn
   FROM pg_replication_slots;"
```

**Résultat attendu :**

```
 slot_name | plugin | slot_type | active | restart_lsn
-----------+--------+-----------+--------+-------------
 sub_tout  | pgoutput | logical  | t      | 0/...
```

---

### Étape 6 : Vérifier l'état du worker de réplication

```bash
psql -p 5432 -U postgres -c \
  "SELECT pid, usename, application_name, state, sent_lsn, write_lsn
   FROM pg_stat_replication;"
```

---

##  2 — Publication Sélective (tables spécifiques)

### Objectif
Créer une publication qui ne réplique qu'un sous-ensemble de tables, et observer l'isolation entre publications.

---

### Étape 1 : Nettoyage du scénario précédent

```bash
# [DEST] Supprimer la souscription existante
psql -p 5433 -U postgres -d lab_dest -c "DROP SUBSCRIPTION sub_tout;"

# [SOURCE] Supprimer la publication existante
psql -p 5432 -U postgres -d lab_source -c "DROP PUBLICATION pub_tout;"

# [DEST] Vider les tables destination
psql -p 5433 -U postgres -d lab_dest -c \
  "TRUNCATE clients, commandes, produits, logs_application;"
```

---

### Étape 2 : Créer une publication sélective

```bash
psql -p 5432 -U postgres -d lab_source
```

```sql
-- [SOURCE] Publier uniquement clients et commandes
CREATE PUBLICATION pub_commerce FOR TABLE clients, commandes;

-- Vérifier les tables incluses
SELECT pubname, tablename
FROM pg_publication_tables
ORDER BY tablename;
```

**Résultat attendu :**

```
   pubname    | tablename
--------------+-----------
 pub_commerce | clients
 pub_commerce | commandes
```

> `produits` et `logs_application` ne sont PAS dans cette publication.

---

### Étape 3 : Créer la souscription correspondante

```bash
psql -p 5433 -U postgres -d lab_dest
```

```sql
-- [DEST] Souscription à pub_commerce uniquement
CREATE SUBSCRIPTION sub_commerce
  CONNECTION 'host=127.0.0.1 port=5432 dbname=lab_source
              user=replicateur password=RepliPass2024!'
  PUBLICATION pub_commerce;
```

---

### Étape 4 : Vérifier l'isolation de la réplication

```sql
-- [DEST] clients et commandes sont répliqués
SELECT COUNT(*) AS clients FROM clients;
SELECT COUNT(*) AS commandes FROM commandes;

-- produits et logs restent vides
SELECT COUNT(*) AS produits FROM produits;
SELECT COUNT(*) AS logs FROM logs_application;
```

**Résultat attendu :**

```
 clients  → 6  (données présentes)
 commandes→ 4  (données présentes)
 produits → 0  (non répliqué)
 logs     → 0  (non répliqué)
```

---

### Étape 5 : Ajouter une table à la publication existante

```bash
psql -p 5432 -U postgres -d lab_source
```

```sql
-- [SOURCE] Ajouter produits à la publication
ALTER PUBLICATION pub_commerce ADD TABLE produits;

-- Vérifier
SELECT pubname, tablename FROM pg_publication_tables ORDER BY tablename;
```

**Côté DEST**, la table `produits` ne sera pas automatiquement synchronisée pour les données existantes. Il faut rafraîchir la souscription :

```bash
psql -p 5433 -U postgres -d lab_dest
```

```sql
-- [DEST] Rafraîchir pour prendre en compte la nouvelle table
ALTER SUBSCRIPTION sub_commerce REFRESH PUBLICATION;

-- Vérifier après quelques secondes
SELECT COUNT(*) FROM produits;
```

**Résultat attendu :** 4 lignes (synchronisation initiale déclenchée pour produits).

---

### Étape 6 : Retirer une table de la publication

```bash
psql -p 5432 -U postgres -d lab_source
```

```sql
-- [SOURCE] Retirer logs_application (déjà absente, mais tester avec commandes)
ALTER PUBLICATION pub_commerce DROP TABLE commandes;

-- Vérifier
SELECT pubname, tablename FROM pg_publication_tables ORDER BY tablename;
```

```sql
-- [SOURCE] Insérer une commande — ne doit PAS être répliquée
INSERT INTO commandes (client_id, montant, statut)
VALUES (1, 999.99, 'test_non_replique');
```

```bash
# [DEST] Vérifier que la commande n'est pas arrivée
psql -p 5433 -U postgres -d lab_dest -c \
  "SELECT * FROM commandes WHERE statut = 'test_non_replique';"
```

**Résultat attendu :** 0 ligne.

---

##  3 — Filtrage des Opérations (INSERT / UPDATE / DELETE)

### Objectif
Contrôler précisément quelles opérations DML sont répliquées.

---

### Étape 1 : Nettoyage

```bash
psql -p 5433 -U postgres -d lab_dest -c "DROP SUBSCRIPTION sub_commerce;"
psql -p 5432 -U postgres -d lab_source -c "DROP PUBLICATION pub_commerce;"
psql -p 5433 -U postgres -d lab_dest -c \
  "TRUNCATE clients, commandes, produits, logs_application;"
```

---

### Étape 2 : Publication INSERT seulement (logs)

```bash
psql -p 5432 -U postgres -d lab_source
```

```sql
-- [SOURCE] Les logs : on réplique uniquement les INSERT
-- Jamais de UPDATE ou DELETE sur des logs = cohérent
CREATE PUBLICATION pub_logs_insert FOR TABLE logs_application
  WITH (publish = 'insert');

SELECT pubname, pubinsert, pubupdate, pubdelete, pubtruncate
FROM pg_publication;
```

**Résultat attendu :**

```
     pubname      | pubinsert | pubupdate | pubdelete | pubtruncate
------------------+-----------+-----------+-----------+-------------
 pub_logs_insert  | t         | f         | f         | f
```

---

### Étape 3 : Publication INSERT + UPDATE (sans DELETE)

```sql
-- [SOURCE] Les commandes : réplication sans DELETE
-- On veut garder l'historique côté destination
CREATE PUBLICATION pub_commandes_hist FOR TABLE commandes
  WITH (publish = 'insert, update');
```

---

### Étape 4 : Créer les souscriptions

```bash
psql -p 5433 -U postgres -d lab_dest
```

```sql
-- [DEST] Souscription aux logs (INSERT only)
CREATE SUBSCRIPTION sub_logs
  CONNECTION 'host=127.0.0.1 port=5432 dbname=lab_source
              user=replicateur password=RepliPass2024!'
  PUBLICATION pub_logs_insert;

-- [DEST] Souscription aux commandes (INSERT + UPDATE)
CREATE SUBSCRIPTION sub_commandes
  CONNECTION 'host=127.0.0.1 port=5432 dbname=lab_source
              user=replicateur password=RepliPass2024!'
  PUBLICATION pub_commandes_hist;

-- Vérifier les souscriptions actives
SELECT subname, subenabled, subpublications FROM pg_subscription;
```

---

### Étape 5 : Tester le filtrage des opérations

**Test 1 — INSERT répliqué sur les logs :**

```bash
psql -p 5432 -U postgres -d lab_source -c \
  "INSERT INTO logs_application (niveau, message)
   VALUES ('INFO', 'Nouveau log répliqué');"
```

```bash
psql -p 5433 -U postgres -d lab_dest -c \
  "SELECT * FROM logs_application WHERE message = 'Nouveau log répliqué';"
```

**Résultat attendu :** 1 ligne présente sur la DEST.

---

**Test 2 — UPDATE NON répliqué sur les logs :**

```bash
psql -p 5432 -U postgres -d lab_source -c \
  "UPDATE logs_application SET niveau = 'DEBUG'
   WHERE message = 'Nouveau log répliqué';"
```

```bash
psql -p 5433 -U postgres -d lab_dest -c \
  "SELECT niveau FROM logs_application
   WHERE message = 'Nouveau log répliqué';"
```

**Résultat attendu :** niveau reste `INFO` sur la DEST (UPDATE non répliqué).

---

**Test 3 — DELETE NON répliqué sur commandes :**

```bash
# [SOURCE] Supprimer une commande
psql -p 5432 -U postgres -d lab_source -c \
  "DELETE FROM commandes WHERE statut = 'en_attente';"

# [SOURCE] Vérifier : la commande est supprimée
psql -p 5432 -U postgres -d lab_source -c \
  "SELECT COUNT(*) FROM commandes WHERE statut = 'en_attente';"

# [DEST] Vérifier : la commande est toujours présente (DELETE non répliqué)
psql -p 5433 -U postgres -d lab_dest -c \
  "SELECT COUNT(*) FROM commandes WHERE statut = 'en_attente';"
```

**Résultat attendu :**

```
SOURCE → 0 commandes en_attente (supprimée)
DEST   → 1 commande  en_attente (conservée car DELETE non répliqué)
```

---

##  4 — Filtrage par Lignes (Row Filtering)

### Objectif
Répliquer uniquement les lignes correspondant à un critère précis — fonctionnalité introduite dans PostgreSQL 15, disponible en PG16.

---

### Étape 1 : Nettoyage

```bash
psql -p 5433 -U postgres -d lab_dest -c \
  "DROP SUBSCRIPTION sub_logs; DROP SUBSCRIPTION sub_commandes;"
psql -p 5432 -U postgres -d lab_source -c \
  "DROP PUBLICATION pub_logs_insert; DROP PUBLICATION pub_commandes_hist;"
psql -p 5433 -U postgres -d lab_dest -c \
  "TRUNCATE clients, commandes, produits, logs_application;"
```

---

### Étape 2 : Publication avec filtre de lignes

```bash
psql -p 5432 -U postgres -d lab_source
```

```sql
-- [SOURCE] Répliquer uniquement les clients actifs
CREATE PUBLICATION pub_clients_actifs FOR TABLE clients
  WHERE (statut = 'actif');

-- [SOURCE] Répliquer uniquement les commandes livrées
CREATE PUBLICATION pub_commandes_livrees FOR TABLE commandes
  WHERE (statut = 'livree');

-- Vérifier les filtres définis
SELECT pubname, tablename, rowfilter
FROM pg_publication_tables;
```

**Résultat attendu :**

```
        pubname         | tablename |      rowfilter
------------------------+-----------+---------------------
 pub_clients_actifs     | clients   | (statut = 'actif')
 pub_commandes_livrees  | commandes | (statut = 'livree')
```

---

### Étape 3 : Créer les souscriptions

```bash
psql -p 5433 -U postgres -d lab_dest
```

```sql
CREATE SUBSCRIPTION sub_clients_actifs
  CONNECTION 'host=127.0.0.1 port=5432 dbname=lab_source
              user=replicateur password=RepliPass2024!'
  PUBLICATION pub_clients_actifs;

CREATE SUBSCRIPTION sub_commandes_livrees
  CONNECTION 'host=127.0.0.1 port=5432 dbname=lab_source
              user=replicateur password=RepliPass2024!'
  PUBLICATION pub_commandes_livrees;
```

---

### Étape 4 : Vérifier le filtrage initial

```bash
# [SOURCE] État initial
psql -p 5432 -U postgres -d lab_source -c \
  "SELECT nom, statut FROM clients ORDER BY id;"

# [DEST] Seuls les clients actifs doivent être présents
psql -p 5433 -U postgres -d lab_dest -c \
  "SELECT nom, statut FROM clients ORDER BY id;"
```

**Résultat attendu :**

```
SOURCE → 6 clients (actifs + inactifs)
DEST   → 5 clients (Claire inactif absent)
```

---

### Étape 5 : Tester le filtre en temps réel

**Cas A — Un client inactif devient actif :**

```bash
psql -p 5432 -U postgres -d lab_source -c \
  "UPDATE clients SET statut = 'actif' WHERE nom = 'Claire Lebrun';"
```

```bash
# [DEST] Claire doit maintenant apparaître
psql -p 5433 -U postgres -d lab_dest -c \
  "SELECT nom, statut FROM clients WHERE nom = 'Claire Lebrun';"
```

**Résultat attendu :** Claire apparaît maintenant sur la DEST (elle correspond désormais au filtre).

---

**Cas B — Un client actif devient inactif :**

```bash
psql -p 5432 -U postgres -d lab_source -c \
  "UPDATE clients SET statut = 'inactif' WHERE nom = 'Bob Dupont';"
```

```bash
# [DEST] Bob doit être supprimé de la DEST
psql -p 5433 -U postgres -d lab_dest -c \
  "SELECT nom, statut FROM clients WHERE nom = 'Bob Dupont';"
```

**Résultat attendu :** 0 ligne (Bob ne correspond plus au filtre, il est supprimé de la DEST).

---

##  5 — Filtrage par Colonnes (Column Filtering)

### Objectif
Répliquer une table en excluant certaines colonnes sensibles (données personnelles, colonnes confidentielles).

---

### Étape 1 : Nettoyage

```bash
psql -p 5433 -U postgres -d lab_dest -c \
  "DROP SUBSCRIPTION sub_clients_actifs; DROP SUBSCRIPTION sub_commandes_livrees;"
psql -p 5432 -U postgres -d lab_source -c \
  "DROP PUBLICATION pub_clients_actifs; DROP PUBLICATION pub_commandes_livrees;"

# Ajouter une colonne sensible sur la table clients (SOURCE uniquement)
psql -p 5432 -U postgres -d lab_source -c \
  "ALTER TABLE clients ADD COLUMN telephone VARCHAR(20) DEFAULT '0600000000';
   ALTER TABLE clients ADD COLUMN mot_de_passe_hash TEXT DEFAULT 'hash_secret';"

psql -p 5433 -U postgres -d lab_dest -c \
  "TRUNCATE clients, commandes, produits, logs_application;"
```

---

### Étape 2 : Publication avec filtrage de colonnes

```bash
psql -p 5432 -U postgres -d lab_source
```

```sql
-- [SOURCE] Publier clients sans les colonnes sensibles
-- On exclut telephone et mot_de_passe_hash
CREATE PUBLICATION pub_clients_public FOR TABLE clients
  (id, nom, ville, statut, created_at);
-- Note : email et les colonnes sensibles sont exclues

-- Vérifier les colonnes publiées
SELECT pubname, tablename, attnames
FROM pg_publication_tables;
```

**Résultat attendu :**

```
      pubname       | tablename |             attnames
--------------------+-----------+----------------------------------
 pub_clients_public | clients   | {id,nom,ville,statut,created_at}
```

---

### Étape 3 : Adapter la table destination

> La table DEST doit correspondre aux colonnes publiées (ou en avoir moins, mais pas plus).

```bash
psql -p 5433 -U postgres -d lab_dest
```

```sql
-- [DEST] Recréer la table clients sans les colonnes sensibles
DROP TABLE clients;

CREATE TABLE clients (
    id          SERIAL PRIMARY KEY,
    nom         VARCHAR(100) NOT NULL,
    ville       VARCHAR(100),
    statut      VARCHAR(20) DEFAULT 'actif',
    created_at  TIMESTAMP DEFAULT NOW()
);
-- Pas de colonne email, telephone, mot_de_passe_hash

\q
```

---

### Étape 4 : Créer la souscription

```bash
psql -p 5433 -U postgres -d lab_dest
```

```sql
CREATE SUBSCRIPTION sub_clients_public
  CONNECTION 'host=127.0.0.1 port=5432 dbname=lab_source
              user=replicateur password=RepliPass2024!'
  PUBLICATION pub_clients_public;
```

---

### Étape 5 : Vérifier l'exclusion des colonnes

```bash
# [SOURCE] Voir toutes les colonnes
psql -p 5432 -U postgres -d lab_source -c \
  "SELECT id, nom, email, telephone, mot_de_passe_hash FROM clients LIMIT 3;"

# [DEST] Seules les colonnes publiées sont présentes
psql -p 5433 -U postgres -d lab_dest -c \
  "SELECT * FROM clients LIMIT 3;"
```

**Résultat attendu :** la DEST ne contient pas `email`, `telephone`, ni `mot_de_passe_hash`.

---

##  6 — Gestion des Slots de Réplication

### Objectif
Comprendre les slots de réplication, leur impact sur le stockage WAL, et savoir les gérer correctement.

---

### Étape 1 : Observer les slots actifs

```bash
psql -p 5432 -U postgres
```

```sql
-- [SOURCE] Lister tous les slots de réplication
SELECT
    slot_name,
    plugin,
    slot_type,
    database,
    active,
    active_pid,
    restart_lsn,
    confirmed_flush_lsn,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS lag_wal
FROM pg_replication_slots;
```

**Colonnes importantes :**

| Colonne | Signification |
|---|---|
| `active` | `true` si un worker de réplication utilise ce slot |
| `restart_lsn` | Position WAL à partir de laquelle les WAL sont conservés |
| `lag_wal` | Volume de WAL accumulé en attente de consommation |

---

### Étape 2 : Simuler un slot inactif (dangereux)

```bash
# [DEST] Désactiver la souscription (simule une dest hors ligne)
psql -p 5433 -U postgres -d lab_dest -c \
  "ALTER SUBSCRIPTION sub_clients_public DISABLE;"

# [SOURCE] Générer des données pendant que la dest est "hors ligne"
psql -p 5432 -U postgres -d lab_source -c "
INSERT INTO clients (nom, ville, statut)
SELECT 'Client_' || i, 'Ville_' || i, 'actif'
FROM generate_series(1, 1000) AS i;"
```

```bash
# [SOURCE] Observer l'accumulation de WAL dans le slot
psql -p 5432 -U postgres -c \
  "SELECT slot_name, active,
     pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_retenu
   FROM pg_replication_slots;"
```

> **Point pédagogique :** un slot inactif empêche PostgreSQL de nettoyer les WAL. Si la DEST reste hors ligne trop longtemps, le disque du SOURCE peut se remplir.

---

### Étape 3 : Réactiver et vérifier la reprise

```bash
# [DEST] Réactiver la souscription
psql -p 5433 -U postgres -d lab_dest -c \
  "ALTER SUBSCRIPTION sub_clients_public ENABLE;"

# Attendre 5-10 secondes le temps de la resynchronisation

# [DEST] Vérifier que les 1000 clients sont bien arrivés
psql -p 5433 -U postgres -d lab_dest -c \
  "SELECT COUNT(*) FROM clients WHERE nom LIKE 'Client_%';"
```

**Résultat attendu :** 1000 lignes (la reprise est automatique).

---

### Étape 4 : Supprimer un slot orphelin

> Si une souscription est supprimée sans `DROP SUBSCRIPTION` (ex : crash), le slot reste sur le SOURCE et continue de retenir les WAL. Il faut le supprimer manuellement.

```bash
psql -p 5432 -U postgres
```

```sql
-- [SOURCE] Supprimer un slot orphelin manuellement
-- ATTENTION : vérifier que le slot n'est plus utilisé (active = false)
SELECT slot_name, active FROM pg_replication_slots;

-- Si active = false, supprimer :
-- SELECT pg_drop_replication_slot('nom_du_slot_orphelin');
```

---

##  7 — Supervision de la Réplication Logique

### Objectif
Utiliser les vues système pour monitorer l'état et les performances de la réplication logique.

---

### Étape 1 : Superviser côté SOURCE

```bash
psql -p 5432 -U postgres
```

```sql
-- [SOURCE] État des connexions de réplication actives
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
    pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS lag
FROM pg_stat_replication;
```

```sql
-- [SOURCE] Statistiques des publications
SELECT
    pubname,
    schemaname,
    tablename
FROM pg_publication_tables
ORDER BY pubname, tablename;
```

```sql
-- [SOURCE] État détaillé des slots
SELECT
    slot_name,
    plugin,
    active,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_retenu,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS lag_confirmation
FROM pg_replication_slots;
```

---

### Étape 2 : Superviser côté DESTINATION

```bash
psql -p 5433 -U postgres -d lab_dest
```

```sql
-- [DEST] État des workers de réplication appliqués
SELECT
    subname,
    received_lsn,
    last_msg_send_time,
    last_msg_receipt_time,
    latest_end_lsn,
    latest_end_time
FROM pg_stat_subscription;
```

```sql
-- [DEST] État de synchronisation par table
SELECT
    subname,
    relname,
    state,
    received_lsn
FROM pg_subscription_rel
JOIN pg_class ON pg_class.oid = pg_subscription_rel.srrelid
JOIN pg_subscription ON pg_subscription.oid = pg_subscription_rel.srsubid;
```

**États possibles dans `pg_subscription_rel` :**

| État | Signification |
|---|---|
| `i` | initialize — synchronisation initiale en cours |
| `d` | data — copie des données en cours |
| `s` | syncdone — synchronisation initiale terminée |
| `r` | ready — réplication normale en cours |

---

### Étape 3 : Script de supervision rapide

```bash
# Script one-liner pour surveiller la santé de la réplication
echo "=== SOURCE : Slots ===" && \
psql -p 5432 -U postgres -c \
  "SELECT slot_name, active,
     pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(),restart_lsn)) AS wal_retenu
   FROM pg_replication_slots;" && \
echo "=== DEST : Subscriptions ===" && \
psql -p 5433 -U postgres -d lab_dest -c \
  "SELECT subname, subenabled FROM pg_subscription;" && \
echo "=== DEST : Workers ===" && \
psql -p 5433 -U postgres -d lab_dest -c \
  "SELECT subname, received_lsn, latest_end_time FROM pg_stat_subscription;"
```

---

##  8 — Modification de la Publication à Chaud

### Objectif
Modifier une publication existante sans interrompre la réplication.

---

### Étape 1 : Ajouter une table à la publication en production

```bash
psql -p 5432 -U postgres -d lab_source
```

```sql
-- [SOURCE] Ajouter produits à une publication existante
ALTER PUBLICATION pub_clients_public ADD TABLE produits;

-- Vérifier
SELECT pubname, tablename FROM pg_publication_tables ORDER BY tablename;
```

```bash
# [DEST] Rafraîchir la souscription pour prendre en compte la nouvelle table
psql -p 5433 -U postgres -d lab_dest -c \
  "ALTER SUBSCRIPTION sub_clients_public REFRESH PUBLICATION;"

# Attendre quelques secondes
sleep 5

# [DEST] Vérifier que produits est maintenant répliqué
psql -p 5433 -U postgres -d lab_dest -c "SELECT COUNT(*) FROM produits;"
```

---

### Étape 2 : Changer les opérations publiées à chaud

```bash
psql -p 5432 -U postgres -d lab_source
```

```sql
-- [SOURCE] Changer la publication pour exclure les DELETE sur produits
ALTER PUBLICATION pub_clients_public
  SET TABLE produits WITH (publish = 'insert, update');

-- Vérifier
SELECT pubname, tablename, attnames
FROM pg_publication_tables;
```

---

### Étape 3 : Tester la modification

```bash
# [SOURCE] Supprimer un produit
psql -p 5432 -U postgres -d lab_source -c \
  "DELETE FROM produits WHERE nom = 'Souris USB';"

# [SOURCE] Vérifier : produit supprimé sur source
psql -p 5432 -U postgres -d lab_source -c "SELECT COUNT(*) FROM produits;"

# [DEST] Vérifier : produit toujours présent (DELETE non répliqué)
psql -p 5433 -U postgres -d lab_dest -c "SELECT COUNT(*) FROM produits;"
```

**Résultat attendu :**

```
SOURCE → 3 produits (Souris USB supprimée)
DEST   → 4 produits (Souris USB conservée)
```

---

##  9 — Désactivation et Réactivation d'une Souscription

### Objectif
Gérer le cycle de vie d'une souscription : pause, maintenance, reprise.

---

### Étape 1 : Désactiver la souscription (pause)

```bash
psql -p 5433 -U postgres -d lab_dest
```

```sql
-- [DEST] Mettre la réplication en pause
ALTER SUBSCRIPTION sub_clients_public DISABLE;

-- Vérifier l'état
SELECT subname, subenabled FROM pg_subscription;
```

**Résultat attendu :** `subenabled = f`

---

### Étape 2 : Effectuer des modifications pendant la pause

```bash
# [SOURCE] Insérer des données pendant la pause
psql -p 5432 -U postgres -d lab_source -c "
INSERT INTO clients (nom, ville, statut)
VALUES ('Test Pause', 'Paris', 'actif');"
```

```bash
# [DEST] Vérifier immédiatement : le client n'est pas encore arrivé
psql -p 5433 -U postgres -d lab_dest -c \
  "SELECT COUNT(*) FROM clients WHERE nom = 'Test Pause';"
# Résultat attendu : 0
```

---

### Étape 3 : Réactiver et vérifier la reprise automatique

```bash
psql -p 5433 -U postgres -d lab_dest -c \
  "ALTER SUBSCRIPTION sub_clients_public ENABLE;"

sleep 3

# Le client doit maintenant être arrivé
psql -p 5433 -U postgres -d lab_dest -c \
  "SELECT nom, ville FROM clients WHERE nom = 'Test Pause';"
```

**Résultat attendu :** 1 ligne — la réplication reprend là où elle s'était arrêtée grâce au slot de réplication.

---

##  10 — Nettoyage complet du Lab

### Supprimer les souscriptions (DEST en premier)

```bash
# [DEST] Supprimer toutes les souscriptions
psql -p 5433 -U postgres -d lab_dest -c \
  "DROP SUBSCRIPTION IF EXISTS sub_clients_public;"
```

> `DROP SUBSCRIPTION` supprime automatiquement le slot de réplication côté SOURCE.

### Supprimer les publications (SOURCE)

```bash
# [SOURCE] Supprimer toutes les publications
psql -p 5432 -U postgres -d lab_source -c \
  "DROP PUBLICATION IF EXISTS pub_clients_public;
   DROP PUBLICATION IF EXISTS pub_tout;
   DROP PUBLICATION IF EXISTS pub_commerce;"
```

### Vérifier que les slots sont bien supprimés

```bash
psql -p 5432 -U postgres -c \
  "SELECT slot_name FROM pg_replication_slots;"
# Résultat attendu : 0 ligne
```

### Arrêter les clusters (optionnel)

```bash
pg_ctlcluster 16 dest stop
pg_ctlcluster 16 source stop
```

---

## Annexe A — Référence des vues système

| Vue | Cluster | Contenu |
|---|---|---|
| `pg_publication` | SOURCE | Liste des publications et leurs options |
| `pg_publication_tables` | SOURCE | Tables et colonnes incluses par publication |
| `pg_replication_slots` | SOURCE | Slots de réplication et leur lag WAL |
| `pg_stat_replication` | SOURCE | Connexions WAL sender actives |
| `pg_subscription` | DEST | Liste des souscriptions |
| `pg_subscription_rel` | DEST | État de synchronisation par table |
| `pg_stat_subscription` | DEST | Métriques des workers de réplication |

---

## Annexe B — Erreurs fréquentes et solutions

### Erreur : `ERROR: logical replication not enabled`
**Cause :** `wal_level` n'est pas à `logical` sur le SOURCE.
**Solution :** modifier `postgresql.conf`, puis redémarrer le cluster source.

```bash
pg_ctlcluster 16 source restart
```

---

### Erreur : `ERROR: publication does not exist`
**Cause :** la souscription référence une publication qui n'existe pas encore sur le SOURCE.
**Solution :** créer la publication sur le SOURCE avant de créer la souscription sur la DEST.

---

### Erreur : `ERROR: relation "table" does not exist`
**Cause :** la table n'existe pas sur la DEST au moment de la création de la souscription.
**Solution :** créer le DDL (CREATE TABLE) sur la DEST avant de créer la souscription.

---

### Erreur : `ERROR: could not connect to the publisher`
**Cause :** mauvais paramètres de connexion dans la souscription, ou `pg_hba.conf` non configuré.
**Solution :**
1. Vérifier la chaîne de connexion (host, port, dbname, user, password).
2. Vérifier `pg_hba.conf` sur le SOURCE.
3. Recharger la configuration : `pg_ctlcluster 16 source reload`.

---

### Erreur : slot inactif qui remplit le disque
**Cause :** la souscription DEST est hors ligne, le slot SOURCE retient les WAL.
**Solution :**
- Réactiver la souscription DEST.
- Si la DEST est définitivement abandonnée, supprimer le slot côté SOURCE :

```sql
SELECT pg_drop_replication_slot('nom_du_slot');
```

---

### Erreur : conflit de clé primaire lors de la synchronisation
**Cause :** des données existent déjà sur la DEST et entrent en conflit avec les données du SOURCE.
**Solution :** vider la table DEST avant de créer la souscription, ou utiliser `copy_data = false`.

```sql
TRUNCATE ma_table;
-- Puis recréer la souscription
```

---

## Annexe C — Commandes de référence rapide

```bash
# Vérifier wal_level
psql -p 5432 -U postgres -c "SHOW wal_level;"

# Lister les publications
psql -p 5432 -U postgres -d lab_source -c \
  "SELECT * FROM pg_publication;"

# Lister les tables d'une publication
psql -p 5432 -U postgres -d lab_source -c \
  "SELECT * FROM pg_publication_tables ORDER BY pubname, tablename;"

# Lister les slots et leur lag
psql -p 5432 -U postgres -c \
  "SELECT slot_name, active,
     pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(),restart_lsn)) AS lag
   FROM pg_replication_slots;"

# Lister les souscriptions
psql -p 5433 -U postgres -d lab_dest -c \
  "SELECT * FROM pg_subscription;"

# Lister les workers de réplication
psql -p 5433 -U postgres -d lab_dest -c \
  "SELECT * FROM pg_stat_subscription;"

# Rafraîchir une souscription après ajout de table
psql -p 5433 -U postgres -d lab_dest -c \
  "ALTER SUBSCRIPTION sub_nom REFRESH PUBLICATION;"

# Désactiver / réactiver une souscription
psql -p 5433 -U postgres -d lab_dest -c \
  "ALTER SUBSCRIPTION sub_nom DISABLE;"
psql -p 5433 -U postgres -d lab_dest -c \
  "ALTER SUBSCRIPTION sub_nom ENABLE;"

# Supprimer proprement (supprime aussi le slot côté source)
psql -p 5433 -U postgres -d lab_dest -c \
  "DROP SUBSCRIPTION sub_nom;"
```
