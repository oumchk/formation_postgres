# Lab — postgres_fdw entre deux instances PostgreSQL

## Objectif

Créer une connexion **Foreign Data Wrapper (postgres_fdw)** entre deux instances
PostgreSQL sur la même machine :

- **Instance A — port 5432** : instance principale, côté requêtes
- **Instance B — port 5450** : instance distante, contient la table `transactions`


---

## Architecture du lab
```
┌──────────────────────────────────────────────────────────┐
│                     MACHINE LOCALE                         │
│                                                            │
│  ┌─────────────────────────┐   postgres_fdw  ┌──────────────────────────┐ │
│  │  Instance A             │ ◄─────────────► │  Instance B              │ │
│  │  Port : 5432            │                 │  Port : 5450             │ │
│  │  Base : formation       │                 │  Base : lab_stream       │ │
│  │  Schéma : public        │                 │  Schéma : public         │ │
│  │  Table FDW : transactions│                 │  Table réelle: transactions│ │
│  └─────────────────────────┘                 └──────────────────────────┘ │
└──────────────────────────────────────────────────────────┘
```

---


---

## Étape 1 — Créer les deux instances PostgreSQL

```bash
 

# Vérifier les connexions
psql -h 127.0.0.1 -p 5432 -U postgres -c "SELECT version();"
psql -h 127.0.0.1 -p 5450 -U postgres -c "SELECT version();"

## en cas d'echec verifier les pg_hba.conf pour vous assurer que la connexion est autoriser 

```

---

## Étape 2 — Préparer l'instance B (port 5450)

### 2.1 Créer le rôle FDW dans l'instance B
```bash
psql -h 127.0.0.1 -p 5450 -U postgres  

-- Créer le rôle dédié aux connexions FDW
-- Ce rôle sera utilisé par postgres_fdw pour se connecter à l'instance B
CREATE ROLE fdw_user
  WITH LOGIN
  PASSWORD 'fdw_password_securise'
  NOSUPERUSER
  NOCREATEDB
  NOCREATEROLE;

-- Donner accès à la base distante
GRANT CONNECT ON DATABASE lab_stream TO fdw_user;

-- Se connecter à lab_stream pour donner les droits sur la table
\c lab_stream

-- Droits SELECT, UPDATE, DELETE sur la table transactions
GRANT USAGE  ON SCHEMA public      TO fdw_user;
GRANT SELECT, UPDATE, DELETE
  ON TABLE public.transactions      TO fdw_user;

-- Vérifier les droits accordés
SELECT grantee, privilege_type
FROM information_schema.role_table_grants
WHERE table_name = 'transactions'
  AND grantee = 'fdw_user';
-- grantee   | privilege_type
-- fdw_user  | SELECT
-- fdw_user  | UPDATE
-- fdw_user  | DELETE

```

### 2.1 Configurer pg_hba.conf de l'instance B
```bash
# Localiser le fichier pg_hba.conf de l'instance remote (port 5450)
sudo -u postgres psql -p 5450 -c "SHOW hba_file;"
#                  hba_file
# ----------------------------------------
#  /etc/postgresql/16/remote/pg_hba.conf

# Ajouter la règle d'accès pour fdw_user
sudo nano /etc/postgresql/16/remote/pg_hba.conf  

# Connexion FDW depuis l'instance A (127.0.0.1)
host    lab_stream    fdw_user    127.0.0.1/32    scram-sha-256
 

# Recharger la configuration
sudo pg_ctlcluster 16 primary reload

# Vérifier que la règle est appliquée
sudo -u postgres psql -p 5450 -c "SELECT pg_reload_conf();"

# Tester la connexion avec fdw_user
psql -h 127.0.0.1 -p 5450 -U fdw_user -d lab_stream \
  -c "SELECT count(*) FROM transactions;"
# count = 8  →  connexion OK
```

---

## Étape 3 — Préparer l'instance A (port 5432)


### 3.1 Installer l'extension postgres_fdw
```bash
psql -h 127.0.0.1 -p 5432 -U postgres -d formation  

-- Installer l'extension postgres_fdw
-- Elle est incluse dans postgresql-contrib (déjà installée avec PostgreSQL 16)
CREATE EXTENSION IF NOT EXISTS postgres_fdw;

-- Vérifier l'installation
SELECT extname, extversion
FROM pg_extension
WHERE extname = 'postgres_fdw';
-- extname      | extversion
-- postgres_fdw | 1.1

```

### 3.2 Créer le Foreign Server
```bash
psql -h 127.0.0.1 -p 5432 -U postgres -d formation 

-- Créer le serveur distant qui pointe vers l'instance B (port 5450)
CREATE SERVER srv_instance_b
  FOREIGN DATA WRAPPER postgres_fdw
  OPTIONS (
    host       '127.0.0.1',
    port       '5450',
    dbname     'lab_stream'
  );

-- Vérifier la création du serveur
SELECT srvname, srvfdw, srvoptions
FROM pg_foreign_server;
-- srvname        | srvfdw       | srvoptions
-- srv_instance_b | postgres_fdw | {host=127.0.0.1,port=5450,dbname=lab_stream}


```

### 3.3 Créer le User Mapping
```bash
psql -h 127.0.0.1 -p 5432 -U postgres -d formation 

-- Mapper l'utilisateur postgres local vers fdw_user sur l'instance B
-- Quand postgres (instance A) accède à srv_instance_b,
-- il se connecte en tant que fdw_user
CREATE USER MAPPING FOR postgres
  SERVER srv_instance_b
  OPTIONS (
    user     'fdw_user',
    password 'fdw_password_securise'
  );

-- Vérifier le mapping
SELECT umuser::regrole AS local_user,
       srvname,
       umoptions
FROM pg_user_mappings
WHERE srvname = 'srv_instance_b';
-- local_user | srvname        | umoptions
-- postgres   | srv_instance_b | {user=fdw_user,password=fdw_password_securise}


```

### 3.4 Créer la table étrangère (Foreign Table)
```bash
psql -h 127.0.0.1 -p 5432 -U postgres -d formation  

-- Créer la table étrangère qui mappe vers transactions de l'instance B
-- La structure doit correspondre exactement à la table distante
CREATE FOREIGN TABLE transactions (
     id          SERIAL PRIMARY KEY,
    employe_id  INTEGER REFERENCES employes(id),
    montant     NUMERIC(10,2),
    type_op     VARCHAR(20),
    created_at  TIMESTAMP DEFAULT NOW()
)
SERVER srv_instance_b
OPTIONS (
  schema_name 'public',
  table_name  'transactions'
);

-- Vérifier la création de la table étrangère
SELECT foreign_table_name,
       foreign_server_name,
       ftoptions
FROM information_schema.foreign_tables
WHERE foreign_table_name = 'transactions';

-- Voir les colonnes
\d transactions

```

> **Alternative — IMPORT FOREIGN SCHEMA**
> Plutôt que de déclarer manuellement chaque colonne, on peut importer
> automatiquement la structure depuis l'instance distante :
>
> ```sql
> -- Importer automatiquement la table (structure récupérée depuis l'instance B)
> IMPORT FOREIGN SCHEMA public
>   LIMIT TO (transactions)
>   FROM SERVER srv_instance_b
>   INTO public;
> ```
> Cette méthode est plus robuste car elle suit les modifications de structure
> de la table distante si on relance l'import.

---

## Étape 4 — Tests des opérations

### 4.1 SELECT — Lecture depuis l'instance A
```bash
psql -h 127.0.0.1 -p 5432 -U postgres -d formation  

-- Lire toutes les transactionss
SELECT id, type_op,employe_id,montant,created_at
FROM transactions
ORDER BY id;



-- Filtrer avec une condition (poussée vers l'instance B — pushdown)
SELECT id, employe_id, montant, type_op
FROM transactions
ORDER BY montant DESC;

-- Agrégation (calculée côté instance A après récupération)
SELECT
  type_op,
  COUNT(*)        AS nb,
  SUM(montant)    AS total,
  AVG(montant)    AS moyenne
FROM transactions
GROUP BY type_op
ORDER BY type_op;

-- Vérifier que la requête est bien envoyée à l'instance B (EXPLAIN)
EXPLAIN VERBOSE
SELECT * FROM transactions WHERE type_op = '---';
-- Doit afficher : Foreign Scan on public.transactions
-- et la condition poussée : Remote SQL: SELECT ... WHERE statut = 'valide'

 
```

### 4.2 UPDATE — Mise à jour depuis l'instance A
```bash
psql -h 127.0.0.1 -p 5432 -U postgres -d formation  

-- Mettre à jour le statut d'une transactions
UPDATE transactions
SET    type_op     = 'credit',
       created_at = NOW()
WHERE  id  = 1250;

-- UPDATE 1

-- Vérifier la mise à jour côté instance A
SELECT *
FROM transactions
WHERE id  = 1250;

-- statut doit être : valide

-- Vérifier côté instance B que la modification est bien persistée
-- (sortir de psql puis se connecter à l'instance B)
\q



psql -h 127.0.0.1 -p 5450 -U postgres -d lab_stream \
  -c "SELECT *
            FROM transactions
            WHERE id  = 1250;"
# statut = valide  →  mise à jour confirmée sur l'instance B
```


##  — Gestion des erreurs courantes

### Erreur : `could not connect to server`
```bash
# Symptôme
# ERROR: could not connect to server "srv_instance_b"
# DETAIL: could not connect to the server: Connection refused

# Diagnostic
pg_lsclusters
# Vérifier que l'instance B (remote, port 5450) est bien en status "online"

# Si elle est arrêtée
sudo pg_ctlcluster 16 remote start

# Retester
psql -h 127.0.0.1 -p 5450 -U postgres -c "SELECT 1;"
```

### Erreur : `password authentication failed`
```bash
# Symptôme
# ERROR: password authentication failed for user "fdw_user"

# Vérifier que le User Mapping est correct
psql -h 127.0.0.1 -p 5432 -U postgres -d formation \
  -c "SELECT umoptions FROM pg_user_mappings WHERE srvname = 'srv_instance_b';"

# Vérifier que pg_hba.conf de l'instance B autorise fdw_user
cat /etc/postgresql/16/remote/pg_hba.conf | grep fdw_user

# Tester la connexion directe
psql -h 127.0.0.1 -p 5450 -U fdw_user -d lab_stream -c "SELECT 1;"
```

### Erreur : `permission denied for table transactions`
```bash
# Symptôme
# ERROR: permission denied for table transactions

# Vérifier les droits de fdw_user sur l'instance B
psql -h 127.0.0.1 -p 5450 -U postgres -d lab_stream 

SELECT grantee, privilege_type, table_name
FROM information_schema.role_table_grants
WHERE table_name = 'transactions'
  AND grantee = 'fdw_user';

-- Si les droits manquent, les accorder
GRANT SELECT, UPDATE, DELETE ON TABLE public.transactions TO fdw_user;


```

### Erreur : `foreign table has no updatable columns`
```bash
# Symptôme lors d'un UPDATE ou DELETE
# ERROR: cannot update foreign table "transactions"

# Vérifier l'option updatable sur la table étrangère
psql -h 127.0.0.1 -p 5432 -U postgres -d formation 

-- Vérifier les options de la table étrangère
SELECT ftoptions
FROM pg_foreign_table
WHERE ftrelid = 'transactions'::regclass;

-- Forcer la table comme modifiable si nécessaire
ALTER FOREIGN TABLE transactions OPTIONS (ADD updatable 'true');


```
