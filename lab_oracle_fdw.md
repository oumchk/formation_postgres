# Lab oracle_fdw — PostgreSQL 16 ↔ Oracle 12c (PDB)
## Accès transparent depuis PostgreSQL vers Oracle via Foreign Data Wrapper

---

## Architecture du Lab

```
┌──────────────────────────────────────────────────────────────────────┐
│                     MACHINE POSTGRESQL (locale)                      │
│                                                                      │
│   ┌──────────────────────────────────────┐                          │
│   │  PostgreSQL 16   — Port 5432         │                          │
│   │                                      │                          │
│   │  Extension : oracle_fdw              │                          │
│   │  Schéma   : fdw_oracle               │                          │
│   │  User PG  : fdw_user                 │                          │
│   └──────────────┬───────────────────────┘                          │
│                  │  OCI (Oracle Call Interface)                      │
│                  │  Oracle Instant Client 19c                        │
└──────────────────┼───────────────────────────────────────────────────┘
                   │
                   │  TCP/IP  ORACLE_IP_ADDR:1521
                   │
┌──────────────────┼───────────────────────────────────────────────────┐
│                  ▼          MACHINE ORACLE                           │
│   ┌──────────────────────────────────────┐                          │
│   │  Oracle 12c  — Port 1521             │                          │
│   │  Service    : SERVICE_NAME               │                          │
│   │  User Oracle: fdw_reader (lecture)   │                          │
│   │  Schema     : DEMO                   │                          │
│   └──────────────────────────────────────┘                          │
└──────────────────────────────────────────────────────────────────────┘
```

| Paramètre | Valeur |
|---|---|
| Host Oracle | `ORACLE_IP_ADDR` |
| Port Oracle | `1521` |
| Service Oracle | `SERVICE_NAME` |
| Chaine OCI | `//ORACLE_IP_ADDR:1521/SERVICE_NAME` |
| Port PostgreSQL | `5432` |
| User Oracle (lecture) | `fdw_reader` |
| User PG (FDW) | `fdw_user` |
| Schema PG (FDW) | `fdw_oracle` |

> **Conventions :**
> - `[ORACLE]` — commandes a executer cote Oracle (sqlplus ou SQL Developer)
> - `[SHELL]` — commandes Bash sur le serveur PostgreSQL (root ou postgres)
> - `[PSQL]` — commandes SQL dans psql cote PostgreSQL

---

## PARTIE 0 — Prerequis et verifications initiales

### 0.1 Verifier la connectivite reseau vers Oracle

```bash
# [SHELL] Tester que le port Oracle est accessible
ping -c 3 ORACLE_IP_ADDR

# Tester le port TNS Listener
nc -zv ORACLE_IP_ADDR 1521
# Resultat attendu : Connection to ORACLE_IP_ADDR 1521 port [tcp] succeeded!

# Ou avec telnet
telnet ORACLE_IP_ADDR 1521
```

### 0.2 Verifier la version PostgreSQL

```bash
# [SHELL]
psql --version
# PostgreSQL 16.x

# Verifier les outils de developpement
dpkg -l | grep postgresql-server-dev
# Si absent :
sudo apt-get install -y postgresql-server-dev-16
```

### 0.3 Installer les outils de compilation

```bash
# [SHELL]
sudo apt-get install -y \
    build-essential \
    gcc \
    make \
    git \
    wget \
    unzip \
    libaio1 \
    libaio-dev
```

---

## PARTIE 1 — Installation d'Oracle Instant Client

> oracle_fdw utilise la bibliotheque OCI (Oracle Call Interface) incluse dans
> l'Oracle Instant Client. La version 19c du client est compatible Oracle 12c+.

### 1.1 Telecharger Oracle Instant Client 19c

Telecharger manuellement depuis :
**https://www.oracle.com/database/technologies/instant-client/linux-x86-64-downloads.html**

Fichiers requis (version 19.x) :
- `oracle-instantclient19.x-basic-19.x.x.x.x-1.x86_64.rpm`
- `oracle-instantclient19.x-devel-19.x.x.x.x-1.x86_64.rpm`

> **Alternative RPM vers DEB** : Sur Ubuntu/Debian, convertir avec `alien` :

```bash
# [SHELL] Convertir les RPM en DEB si necessaire
sudo apt-get install -y alien

sudo alien --to-deb oracle-instantclient19.x-basic-*.rpm
sudo alien --to-deb oracle-instantclient19.x-devel-*.rpm

# Installer
sudo dpkg -i oracle-instantclient19.x-basic_*.deb
sudo dpkg -i oracle-instantclient19.x-devel_*.deb
```

### 1.2 Installer via RPM (si systeme compatible)

```bash
# [SHELL] Installation directe RPM (CentOS/RHEL/Fedora)
sudo rpm -ivh oracle-instantclient19.x-basic-*.rpm
sudo rpm -ivh oracle-instantclient19.x-devel-*.rpm
```

### 1.3 Configurer le linker dynamique

```bash
# [SHELL] Creer le fichier de configuration du linker
echo '/usr/lib/oracle/19.x/client64/lib' | \
    sudo tee /etc/ld.so.conf.d/oracle-instantclient.conf

# Recharger le cache des bibliotheques dynamiques
sudo ldconfig

# Verifier que les libs Oracle sont trouvees
ldconfig -p | grep libclntsh
# Resultat attendu :
#   libclntsh.so.19.1 (libc6,x86-64) => /usr/lib/oracle/19.x/client64/lib/libclntsh.so.19.1
```

### 1.4 Variables d'environnement PostgreSQL

```bash
# [SHELL] Ajouter dans /etc/postgresql/16/main/environment
# Ce fichier est lu par le service PostgreSQL au demarrage

sudo tee -a /etc/postgresql/16/main/environment << 'ENVEOF'

# Oracle Instant Client -- requis par oracle_fdw
ORACLE_HOME=/usr/lib/oracle/19.x/client64
LD_LIBRARY_PATH=/usr/lib/oracle/19.x/client64/lib
TNS_ADMIN=/etc/oracle
ENVEOF

# Verifier le contenu
cat /etc/postgresql/16/main/environment
```

### 1.5 Variables d'environnement systeme (pour la compilation)

```bash
# [SHELL] Exporter pour la session courante (compilation oracle_fdw)
export ORACLE_HOME=/usr/lib/oracle/19.x/client64
export LD_LIBRARY_PATH=/usr/lib/oracle/19.x/client64/lib
export PATH=$ORACLE_HOME/bin:$PATH

# Verifier
echo $ORACLE_HOME
ls $ORACLE_HOME/lib/libclntsh*
```

### 1.6 Creer le repertoire TNS_ADMIN

```bash
# [SHELL]
sudo mkdir -p /etc/oracle
sudo chown postgres:postgres /etc/oracle
sudo chmod 750 /etc/oracle
```

---

## PARTIE 2 — Compilation et Installation d'oracle_fdw

### 2.1 Cloner le depot oracle_fdw

```bash
# [SHELL]
cd /tmp
git clone https://github.com/laurenz/oracle_fdw.git
cd oracle_fdw

# Verifier la version
git log --oneline -3
```

### 2.2 Compiler oracle_fdw

```bash
# [SHELL] S'assurer que les variables sont exportees
export ORACLE_HOME=/usr/lib/oracle/19.x/client64
export LD_LIBRARY_PATH=/usr/lib/oracle/19.x/client64/lib

# Compiler
make USE_PGXS=1

# Resultat attendu (extrait) :
# gcc -O2 -o oracle_fdw.so oracle_fdw.o oracle_utils.o oracle_gis.o ...
# La compilation doit se terminer sans erreur
```

### 2.3 Installer oracle_fdw

```bash
# [SHELL]
sudo make USE_PGXS=1 install

# Verifier l'installation
ls /usr/lib/postgresql/16/lib/oracle_fdw.so
ls /usr/share/postgresql/16/extension/oracle_fdw*
# Resultat attendu :
#   oracle_fdw--1.2.sql
#   oracle_fdw.control
```

### 2.4 Redemarrer PostgreSQL pour charger les variables d'environnement

```bash
# [SHELL]
sudo systemctl restart postgresql

# Verifier que le service a redemarré correctement
sudo systemctl status postgresql
psql -U postgres -p 5432 -c "SELECT version();"
```

---

## PARTIE 3 — Configuration cote Oracle 12c

> Ces commandes sont a executer sur le serveur Oracle 12c
> en se connectant avec un compte DBA (SYS ou SYSTEM).

### 3.1 Se connecter a Oracle en tant que DBA

```sql
-- [ORACLE] Connexion via sqlplus
-- sqlplus sys/password@ORACLE_IP_ADDR:1521/SERVICE_NAME as sysdba
-- Ou depuis le serveur Oracle :
-- sqlplus / as sysdba
-- ALTER SESSION SET CONTAINER = SERVICE_NAME;
```

### 3.2 Creer le schema de demonstration DEMO

```sql
-- [ORACLE] Creer le schema DEMO avec des tables de test

-- Creer l'utilisateur DEMO
CREATE USER demo IDENTIFIED BY "Demo2024!"
  DEFAULT TABLESPACE users
  TEMPORARY TABLESPACE temp
  QUOTA UNLIMITED ON users;

GRANT CREATE SESSION TO demo;
GRANT CREATE TABLE TO demo;
GRANT CREATE VIEW TO demo;
GRANT CREATE SEQUENCE TO demo;

-- Tables de demonstration
CREATE TABLE demo.employes (
    emp_id      NUMBER(10)      NOT NULL,
    nom         VARCHAR2(100)   NOT NULL,
    prenom      VARCHAR2(100),
    poste       VARCHAR2(100),
    salaire     NUMBER(10,2),
    dept_id     NUMBER(5),
    date_emb    DATE,
    email       VARCHAR2(200),
    actif       NUMBER(1)       DEFAULT 1,
    commentaire CLOB,
    CONSTRAINT pk_employes PRIMARY KEY (emp_id)
);

CREATE TABLE demo.departements (
    dept_id      NUMBER(5)      NOT NULL,
    nom          VARCHAR2(100)  NOT NULL,
    localisation VARCHAR2(200),
    budget       NUMBER(15,2),
    CONSTRAINT pk_departements PRIMARY KEY (dept_id)
);

CREATE TABLE demo.projets (
    projet_id   NUMBER(10)      NOT NULL,
    nom         VARCHAR2(200)   NOT NULL,
    debut       DATE,
    fin         DATE,
    budget      NUMBER(15,2),
    statut      VARCHAR2(20)    DEFAULT 'ACTIF',
    description CLOB,
    CONSTRAINT pk_projets PRIMARY KEY (projet_id),
    CONSTRAINT ck_statut CHECK (statut IN ('ACTIF','CLOTURE','SUSPENDU'))
);

-- Index pour les performances FDW
CREATE INDEX idx_employes_dept   ON demo.employes(dept_id);
CREATE INDEX idx_employes_actif  ON demo.employes(actif);
CREATE INDEX idx_projets_statut  ON demo.projets(statut);
```

### 3.3 Inserer les donnees de test

```sql
-- [ORACLE] Donnees de demonstration

INSERT INTO demo.departements VALUES (10, 'Direction Generale', 'Paris',     500000);
INSERT INTO demo.departements VALUES (20, 'Informatique',       'Lyon',      300000);
INSERT INTO demo.departements VALUES (30, 'Finance',            'Paris',     250000);
INSERT INTO demo.departements VALUES (40, 'Ressources Humaines','Bordeaux',  150000);
INSERT INTO demo.departements VALUES (50, 'Commercial',         'Marseille', 400000);

INSERT INTO demo.employes VALUES (1,  'Dupont',  'Alice',  'DBA',         4500, 20, DATE '2020-01-15', 'alice@test.com',  1, 'Specialiste PostgreSQL et Oracle');
INSERT INTO demo.employes VALUES (2,  'Martin',  'Bob',    'Developpeur', 3800, 20, DATE '2021-03-01', 'bob@test.com',    1, 'Developpeur Java/Python');
INSERT INTO demo.employes VALUES (3,  'Lebrun',  'Claire', 'DevOps',      4200, 20, DATE '2019-06-10', 'claire@test.com', 1, NULL);
INSERT INTO demo.employes VALUES (4,  'Moreau',  'David',  'Analyste',    3600, 30, DATE '2022-09-01', 'david@test.com',  1, 'Analyste financier senior');
INSERT INTO demo.employes VALUES (5,  'Lambert', 'Eve',    'Manager',     5500, 10, DATE '2018-01-01', 'eve@test.com',    1, 'Directrice des operations');
INSERT INTO demo.employes VALUES (6,  'Petit',   'Frank',  'Architecte',  5200, 20, DATE '2017-05-20', 'frank@test.com',  1, 'Architecte solutions cloud');
INSERT INTO demo.employes VALUES (7,  'Grand',   'Grace',  'RH',          3400, 40, DATE '2023-02-14', 'grace@test.com',  1, NULL);
INSERT INTO demo.employes VALUES (8,  'Bernard', 'Henri',  'Commercial',  3900, 50, DATE '2020-11-30', 'henri@test.com',  1, 'Account Manager');
INSERT INTO demo.employes VALUES (9,  'Thomas',  'Irene',  'DBA',         4800, 20, DATE '2016-08-01', 'irene@test.com',  1, 'DBA Oracle certifiee OCP');
INSERT INTO demo.employes VALUES (10, 'Robert',  'Jules',  'Stagiaire',   1200, 20, DATE '2024-09-01', 'jules@test.com',  0, 'Stage de fin etudes');

INSERT INTO demo.projets VALUES (1, 'Migration PostgreSQL', DATE '2024-01-01', DATE '2024-12-31', 150000, 'ACTIF',    'Migration Oracle vers PostgreSQL via oracle_fdw');
INSERT INTO demo.projets VALUES (2, 'Refonte SI RH',        DATE '2023-06-01', DATE '2024-06-30', 80000,  'CLOTURE',  'Refonte du systeme information RH');
INSERT INTO demo.projets VALUES (3, 'Cloud AWS',            DATE '2024-03-01', NULL,              200000, 'ACTIF',    'Migration infrastructure vers AWS');
INSERT INTO demo.projets VALUES (4, 'BI Dashboard',         DATE '2024-07-01', DATE '2025-03-31', 60000,  'SUSPENDU', 'Tableau de bord analytique');

COMMIT;
```

### 3.4 Creer l'utilisateur Oracle fdw_reader

```sql
-- [ORACLE] Compte dedie a l'acces depuis PostgreSQL via FDW
-- Principe du moindre privilege : lecture seule

CREATE USER fdw_reader IDENTIFIED BY "FdwReader2024!"
  DEFAULT TABLESPACE users
  TEMPORARY TABLESPACE temp;

-- Droits de connexion
GRANT CREATE SESSION TO fdw_reader;

-- Droits de lecture sur les tables du schema DEMO
GRANT SELECT ON demo.employes     TO fdw_reader;
GRANT SELECT ON demo.departements TO fdw_reader;
GRANT SELECT ON demo.projets      TO fdw_reader;

-- Acces aux vues du dictionnaire (utile pour IMPORT FOREIGN SCHEMA)
GRANT SELECT ON sys.all_tables      TO fdw_reader;
GRANT SELECT ON sys.all_tab_columns TO fdw_reader;
GRANT SELECT ON sys.all_constraints TO fdw_reader;

-- Verification
SELECT username, account_status FROM dba_users WHERE username = 'FDW_READER';
SELECT * FROM dba_sys_privs WHERE grantee = 'FDW_READER';
SELECT * FROM dba_tab_privs WHERE grantee = 'FDW_READER';
```

### 3.5 Verifier le service Oracle SERVICE_NAME

```sql
-- [ORACLE] Verifier que le service SERVICE_NAME est bien actif
SELECT name, network_name, pdb FROM v$services
WHERE LOWER(name) LIKE '%SERVICE_NAME%';

-- Verifier le listener depuis le shell Oracle :
-- lsnrctl status
-- Le service SERVICE_NAME doit apparaitre dans "Services Summary"
```

---

## PARTIE 4 — Configuration PostgreSQL

### 4.1 Creer la base de donnees et l'utilisateur PostgreSQL

```sql
-- [PSQL] Se connecter en postgres
-- psql -U postgres -p 5432

-- Creer la base dediee au lab
CREATE DATABASE lab_oracle_fdw
    ENCODING    'UTF8'
    LC_COLLATE  'en_US.UTF-8'
    LC_CTYPE    'en_US.UTF-8'
    TEMPLATE template0;

-- Creer l'utilisateur applicatif
CREATE ROLE fdw_user
    WITH LOGIN
    PASSWORD 'FdwUser2024!'
    NOSUPERUSER
    NOCREATEDB
    NOCREATEROLE;

-- Se connecter a la base
\c lab_oracle_fdw
```

### 4.2 Activer l'extension oracle_fdw

```sql
-- [PSQL] Dans la base lab_oracle_fdw (en tant que postgres superuser)
\c lab_oracle_fdw

-- Creer l'extension (necessite superuser)
CREATE EXTENSION oracle_fdw;

-- Verifier l'installation
SELECT name, default_version, installed_version
FROM pg_available_extensions
WHERE name = 'oracle_fdw';
-- Resultat attendu :
--    name    | default_version | installed_version
-- -----------+-----------------+-------------------
--  oracle_fdw| 1.2             | 1.2
```

### 4.3 Creer le schema de reception des foreign tables

```sql
-- [PSQL]
CREATE SCHEMA fdw_oracle;

-- Donner les droits a fdw_user
GRANT USAGE ON SCHEMA fdw_oracle TO fdw_user;
```

### 4.4 Declarer le serveur Oracle

```sql
-- [PSQL] Creer le FOREIGN SERVER pointant vers Oracle 12c SERVICE_NAME
CREATE SERVER oracle_SERVICE_NAME
    FOREIGN DATA WRAPPER oracle_fdw
    OPTIONS (
        dbserver        '//ORACLE_IP_ADDR:1521/SERVICE_NAME',
        isolation_level 'read_committed',
        nchar           'true'
    );

-- Donner l'usage du serveur a fdw_user
GRANT USAGE ON FOREIGN SERVER oracle_SERVICE_NAME TO fdw_user;

-- Verifier
SELECT srvname, srvfdw, srvoptions
FROM pg_foreign_server
WHERE srvname = 'oracle_SERVICE_NAME';
```

### 4.5 Creer les User Mappings

```sql
-- [PSQL] Associer les utilisateurs PostgreSQL au compte Oracle fdw_reader

-- Mapping pour le superuser postgres
CREATE USER MAPPING FOR postgres
    SERVER oracle_SERVICE_NAME
    OPTIONS (
        user     'fdw_reader',
        password 'FdwReader2024!'
    );

-- Mapping pour fdw_user
CREATE USER MAPPING FOR fdw_user
    SERVER oracle_SERVICE_NAME
    OPTIONS (
        user     'fdw_reader',
        password 'FdwReader2024!'
    );

-- Verifier (mots de passe masques pour les non-superusers)
SELECT usename, srvname
FROM pg_user_mappings
WHERE srvname = 'oracle_SERVICE_NAME';
```

---

## PARTIE 5 — Creation des Foreign Tables

### 5.1 Import automatique du schema Oracle (methode recommandee)

```sql
-- [PSQL] Importer toutes les tables du schema DEMO d'Oracle automatiquement
-- IMPORTANT : le nom du schema Oracle doit etre en MAJUSCULES

IMPORT FOREIGN SCHEMA "DEMO"
    FROM SERVER oracle_SERVICE_NAME
    INTO fdw_oracle;

-- Verifier les tables importees
SELECT foreign_table_schema, foreign_table_name
FROM information_schema.foreign_tables
WHERE foreign_table_schema = 'fdw_oracle'
ORDER BY foreign_table_name;

-- Resultat attendu :
--  foreign_table_schema | foreign_table_name
-- ----------------------+--------------------
--  fdw_oracle           | departements
--  fdw_oracle           | employes
--  fdw_oracle           | projets
```

### 5.2 Creation manuelle des foreign tables (controle total des types)

> Utiliser cette methode quand les types doivent etre personnalises
> ou certaines colonnes exclues.

```sql
-- [PSQL] Table EMPLOYES
CREATE FOREIGN TABLE fdw_oracle.employes (
    emp_id      INTEGER         OPTIONS (key 'true'),
    nom         VARCHAR(100)    NOT NULL,
    prenom      VARCHAR(100),
    poste       VARCHAR(100),
    salaire     NUMERIC(10,2),
    dept_id     INTEGER,
    date_emb    TIMESTAMP,
    email       VARCHAR(200),
    actif       SMALLINT,
    commentaire TEXT
)
SERVER oracle_SERVICE_NAME
OPTIONS (
    schema   '"DEMO"',
    table    '"EMPLOYES"',
    max_long '4194304'
);

-- Table DEPARTEMENTS
CREATE FOREIGN TABLE fdw_oracle.departements (
    dept_id      INTEGER        OPTIONS (key 'true'),
    nom          VARCHAR(100)   NOT NULL,
    localisation VARCHAR(200),
    budget       NUMERIC(15,2)
)
SERVER oracle_SERVICE_NAME
OPTIONS (
    schema '"DEMO"',
    table  '"DEPARTEMENTS"'
);

-- Table PROJETS
CREATE FOREIGN TABLE fdw_oracle.projets (
    projet_id   INTEGER         OPTIONS (key 'true'),
    nom         VARCHAR(200)    NOT NULL,
    debut       TIMESTAMP,
    fin         TIMESTAMP,
    budget      NUMERIC(15,2),
    statut      VARCHAR(20),
    description TEXT
)
SERVER oracle_SERVICE_NAME
OPTIONS (
    schema   '"DEMO"',
    table    '"PROJETS"',
    max_long '4194304'
);

-- Donner les droits de SELECT a fdw_user
GRANT SELECT ON fdw_oracle.employes     TO fdw_user;
GRANT SELECT ON fdw_oracle.departements TO fdw_user;
GRANT SELECT ON fdw_oracle.projets      TO fdw_user;
```

---

## PARTIE 6 — Tests et Verifications

### 6.1 Premier test de connexion

```sql
-- [PSQL] Test basique -- doit retourner les lignes Oracle
SELECT emp_id, nom, prenom, poste, salaire
FROM fdw_oracle.employes
ORDER BY emp_id;

-- Resultat attendu :
--  emp_id |   nom    | prenom  |    poste    | salaire
-- --------+----------+---------+-------------+---------
--       1 | Dupont   | Alice   | DBA         | 4500.00
--       2 | Martin   | Bob     | Developpeur | 3800.00
-- ...
```

### 6.2 Test du pushdown de predicats

```sql
-- [PSQL] Verifier que le WHERE est envoye a Oracle (pas de full scan)
EXPLAIN (VERBOSE, COSTS OFF)
SELECT emp_id, nom, salaire
FROM fdw_oracle.employes
WHERE dept_id = 20
  AND salaire > 4000;

-- Dans le plan, chercher la ligne "Oracle query:" :
-- Oracle query: SELECT "EMP_ID","NOM","SALAIRE"
--               FROM "DEMO"."EMPLOYES"
--               WHERE ("DEPT_ID" = 20) AND ("SALAIRE" > 4000)
-- Le filtre est pousse cote Oracle : pas de rapatriement de toutes les lignes
```

### 6.3 Jointure entre table locale et table Oracle

```sql
-- [PSQL] Creer une table locale PostgreSQL pour la jointure
CREATE TABLE public.equipes (
    dept_id     INTEGER PRIMARY KEY,
    chef_equipe VARCHAR(100),
    nb_membres  INTEGER
);

INSERT INTO public.equipes VALUES
    (10, 'Eve Lambert',   3),
    (20, 'Frank Petit',   5),
    (30, 'David Moreau',  4),
    (40, 'Grace Grand',   2),
    (50, 'Henri Bernard', 6);

-- Jointure PG local + Oracle distant
SELECT
    d.nom                                       AS departement,
    d.localisation,
    e.chef_equipe,
    e.nb_membres,
    COUNT(emp.emp_id)                           AS nb_employes,
    ROUND(AVG(emp.salaire)::numeric, 2)         AS salaire_moyen
FROM fdw_oracle.departements d
JOIN public.equipes e          ON d.dept_id = e.dept_id
LEFT JOIN fdw_oracle.employes emp ON d.dept_id = emp.dept_id
WHERE emp.actif = 1
GROUP BY d.nom, d.localisation, e.chef_equipe, e.nb_membres
ORDER BY salaire_moyen DESC;
```

### 6.4 Requete analytique sur les donnees Oracle

```sql
-- [PSQL] Analyse des salaires par poste et departement
SELECT
    d.nom                               AS departement,
    emp.poste,
    COUNT(*)                            AS nb_employes,
    MIN(emp.salaire)                    AS salaire_min,
    ROUND(AVG(emp.salaire)::numeric, 2) AS salaire_moy,
    MAX(emp.salaire)                    AS salaire_max,
    SUM(emp.salaire)                    AS masse_salariale
FROM fdw_oracle.employes emp
JOIN fdw_oracle.departements d ON emp.dept_id = d.dept_id
WHERE emp.actif = 1
GROUP BY d.nom, emp.poste
ORDER BY d.nom, salaire_moy DESC;
```

### 6.5 Lecture des colonnes CLOB (TEXT en PostgreSQL)

```sql
-- [PSQL] Les colonnes CLOB Oracle sont mappees en TEXT cote PostgreSQL
SELECT
    emp_id,
    nom,
    prenom,
    LEFT(commentaire, 50) AS extrait_commentaire
FROM fdw_oracle.employes
WHERE commentaire IS NOT NULL
ORDER BY emp_id;
```

### 6.6 Filtres sur les dates Oracle

```sql
-- [PSQL]
-- Oracle DATE = TIMESTAMP (contient heure et date)
-- Utiliser ::date pour extraire la date seule

SELECT
    emp_id,
    nom,
    prenom,
    date_emb::date                  AS date_embauche,
    EXTRACT(YEAR FROM date_emb)     AS annee_embauche,
    AGE(NOW(), date_emb)            AS anciennete
FROM fdw_oracle.employes
WHERE date_emb >= '2020-01-01'::timestamp
ORDER BY date_emb;
```

### 6.7 Projets actifs avec calcul de duree

```sql
-- [PSQL]
SELECT
    projet_id,
    nom,
    debut::date                             AS date_debut,
    COALESCE(fin::date, CURRENT_DATE)       AS date_fin,
    statut,
    budget,
    CASE
        WHEN fin IS NULL THEN
            (CURRENT_DATE - debut::date) || ' jours (en cours)'
        ELSE
            (fin::date - debut::date)::TEXT || ' jours'
    END AS duree
FROM fdw_oracle.projets
ORDER BY statut, debut;
```

---

## PARTIE 7 — Vues locales et abstraction

> Bonne pratique : creer des vues PostgreSQL locales sur les foreign tables.
> Les applications accedent aux vues, pas directement aux foreign tables.

### 7.1 Creer les vues d'abstraction

```sql
-- [PSQL]

-- Vue employes actifs avec informations departement
CREATE VIEW public.v_employes_actifs AS
SELECT
    e.emp_id,
    e.nom,
    e.prenom,
    e.poste,
    e.salaire,
    e.email,
    e.date_emb::date        AS date_embauche,
    d.nom                   AS departement,
    d.localisation
FROM fdw_oracle.employes e
LEFT JOIN fdw_oracle.departements d ON e.dept_id = d.dept_id
WHERE e.actif = 1;

-- Vue projets en cours
CREATE VIEW public.v_projets_actifs AS
SELECT
    projet_id,
    nom,
    debut::date                     AS date_debut,
    fin::date                       AS date_fin,
    budget,
    CURRENT_DATE - debut::date      AS jours_ecoules,
    LEFT(description, 100)          AS description
FROM fdw_oracle.projets
WHERE statut = 'ACTIF';

-- Vue recapitulatif RH par departement
CREATE VIEW public.v_recap_rh AS
SELECT
    d.dept_id,
    d.nom                               AS departement,
    d.localisation,
    d.budget                            AS budget_dept,
    COUNT(e.emp_id)                     AS nb_employes,
    SUM(e.salaire)                      AS masse_salariale,
    ROUND(AVG(e.salaire)::numeric, 2)   AS salaire_moyen
FROM fdw_oracle.departements d
LEFT JOIN fdw_oracle.employes e
    ON d.dept_id = e.dept_id AND e.actif = 1
GROUP BY d.dept_id, d.nom, d.localisation, d.budget;

-- Donner les droits a fdw_user
GRANT SELECT ON public.v_employes_actifs TO fdw_user;
GRANT SELECT ON public.v_projets_actifs  TO fdw_user;
GRANT SELECT ON public.v_recap_rh        TO fdw_user;
```

### 7.2 Utiliser les vues

```sql
-- [PSQL] Utilisation transparente : l'application ne sait pas que c'est Oracle
SELECT * FROM public.v_employes_actifs WHERE departement = 'Informatique';

SELECT * FROM public.v_projets_actifs ORDER BY jours_ecoules DESC;

SELECT * FROM public.v_recap_rh ORDER BY masse_salariale DESC;
```

---

## PARTIE 8 — Supervision et Monitoring

### 8.1 Inspecter les objets FDW crees

```sql
-- [PSQL] Liste des Foreign Data Wrappers installes
SELECT fdwname, fdwhandler::regproc AS handler
FROM pg_foreign_data_wrapper;

-- Liste des serveurs distants
SELECT
    s.srvname       AS serveur,
    w.fdwname       AS fdw,
    s.srvoptions    AS options
FROM pg_foreign_server s
JOIN pg_foreign_data_wrapper w ON s.srvfdw = w.oid;

-- Liste des foreign tables
SELECT
    n.nspname           AS schema_local,
    c.relname           AS table_locale,
    s.srvname           AS serveur_distant,
    ft.ftoptions        AS options
FROM pg_foreign_table ft
JOIN pg_class c          ON ft.ftrelid   = c.oid
JOIN pg_namespace n      ON c.relnamespace = n.oid
JOIN pg_foreign_server s ON ft.ftserver  = s.oid
ORDER BY schema_local, table_locale;

-- User mappings existants
SELECT usename, srvname
FROM pg_user_mappings
WHERE srvname = 'oracle_SERVICE_NAME';
```

### 8.2 Verifier le pushdown avec EXPLAIN

```sql
-- [PSQL] Toujours verifier ce qui est reellement envoye a Oracle
EXPLAIN (VERBOSE)
SELECT nom, prenom, salaire
FROM fdw_oracle.employes
WHERE dept_id = 20
  AND salaire BETWEEN 3000 AND 5000
ORDER BY salaire DESC;

-- Chercher dans la sortie :
-- Foreign Scan on fdw_oracle.employes
--   Output: nom, prenom, salaire
--   Oracle query: SELECT "NOM","PRENOM","SALAIRE"
--                 FROM "DEMO"."EMPLOYES"
--                 WHERE (("DEPT_ID" = 20) AND ("SALAIRE" >= 3000)
--                 AND ("SALAIRE" <= 5000))
--                 ORDER BY "SALAIRE" DESC
```

### 8.3 Script de supervision rapide

```sql
-- [PSQL] Dashboard de supervision du FDW Oracle
SELECT
    (SELECT COUNT(*) FROM fdw_oracle.employes)     AS nb_employes_oracle,
    (SELECT COUNT(*) FROM fdw_oracle.departements) AS nb_depts_oracle,
    (SELECT COUNT(*) FROM fdw_oracle.projets)      AS nb_projets_oracle,
    NOW()                                          AS heure_test;
```

---

## PARTIE 9 — Migration : Copie des donnees Oracle vers PostgreSQL

> Scenario typique de migration : lire depuis Oracle via FDW
> et inserer dans des tables PostgreSQL locales.

### 9.1 Creer les tables locales PostgreSQL cibles

```sql
-- [PSQL]
CREATE TABLE public.employes_local (
    emp_id          INTEGER         PRIMARY KEY,
    nom             VARCHAR(100)    NOT NULL,
    prenom          VARCHAR(100),
    poste           VARCHAR(100),
    salaire         NUMERIC(10,2),
    dept_id         INTEGER,
    date_embauche   DATE,
    email           VARCHAR(200),
    actif           BOOLEAN         DEFAULT true,
    commentaire     TEXT,
    migre_le        TIMESTAMPTZ     DEFAULT NOW(),
    source          TEXT            DEFAULT 'oracle_migration'
);

CREATE TABLE public.departements_local (
    dept_id         INTEGER         PRIMARY KEY,
    nom             VARCHAR(100)    NOT NULL,
    localisation    VARCHAR(200),
    budget          NUMERIC(15,2),
    migre_le        TIMESTAMPTZ     DEFAULT NOW()
);

CREATE TABLE public.projets_local (
    projet_id       INTEGER         PRIMARY KEY,
    nom             VARCHAR(200)    NOT NULL,
    debut           DATE,
    fin             DATE,
    budget          NUMERIC(15,2),
    statut          VARCHAR(20),
    description     TEXT,
    migre_le        TIMESTAMPTZ     DEFAULT NOW()
);
```

### 9.2 Migration initiale (INSERT ... SELECT depuis Oracle)

```sql
-- [PSQL] Copier les donnees Oracle vers PostgreSQL local
BEGIN;

-- Migrer les departements en premier (references par les employes)
INSERT INTO public.departements_local (dept_id, nom, localisation, budget)
SELECT dept_id, nom, localisation, budget
FROM fdw_oracle.departements;

-- Migrer les employes
INSERT INTO public.employes_local
    (emp_id, nom, prenom, poste, salaire, dept_id,
     date_embauche, email, actif, commentaire)
SELECT
    emp_id,
    nom,
    prenom,
    poste,
    salaire,
    dept_id,
    date_emb::date,
    email,
    CASE WHEN actif = 1 THEN TRUE ELSE FALSE END,
    commentaire
FROM fdw_oracle.employes;

-- Migrer les projets
INSERT INTO public.projets_local
    (projet_id, nom, debut, fin, budget, statut, description)
SELECT
    projet_id,
    nom,
    debut::date,
    fin::date,
    budget,
    statut,
    description
FROM fdw_oracle.projets;

COMMIT;

-- Verification post-migration
SELECT
    'employes'     AS table_name,
    (SELECT COUNT(*) FROM fdw_oracle.employes)       AS oracle_count,
    (SELECT COUNT(*) FROM public.employes_local)     AS pg_count
UNION ALL
SELECT
    'departements',
    (SELECT COUNT(*) FROM fdw_oracle.departements),
    (SELECT COUNT(*) FROM public.departements_local)
UNION ALL
SELECT
    'projets',
    (SELECT COUNT(*) FROM fdw_oracle.projets),
    (SELECT COUNT(*) FROM public.projets_local);
```

### 9.3 Validation croisee : comparer Oracle et PostgreSQL

```sql
-- [PSQL] Verification de l'integrite des donnees migreees

-- Comparaison des checksums salaires
SELECT
    'oracle'    AS source,
    COUNT(*)                            AS nb_lignes,
    SUM(salaire)                        AS total_salaires,
    ROUND(AVG(salaire)::numeric, 2)     AS salaire_moyen
FROM fdw_oracle.employes
UNION ALL
SELECT
    'postgresql',
    COUNT(*),
    SUM(salaire),
    ROUND(AVG(salaire)::numeric, 2)
FROM public.employes_local;

-- Lignes presentes dans Oracle mais absentes de PostgreSQL
SELECT 'Dans Oracle, absent de PG' AS situation, emp_id::text, nom
FROM (
    SELECT emp_id::text, nom FROM fdw_oracle.employes
    EXCEPT
    SELECT emp_id::text, nom FROM public.employes_local
) diff
UNION ALL
-- Lignes presentes dans PostgreSQL mais absentes d'Oracle
SELECT 'Dans PG, absent d Oracle', emp_id::text, nom
FROM (
    SELECT emp_id::text, nom FROM public.employes_local
    EXCEPT
    SELECT emp_id::text, nom FROM fdw_oracle.employes
) diff;
-- Resultat attendu : 0 lignes (migration parfaite)

-- Lignes avec salaire different entre Oracle et PostgreSQL
SELECT
    o.emp_id,
    o.nom,
    o.salaire AS salaire_oracle,
    p.salaire AS salaire_pg
FROM fdw_oracle.employes o
JOIN public.employes_local p ON o.emp_id = p.emp_id
WHERE o.salaire <> p.salaire;
-- Resultat attendu : 0 lignes
```

### 9.4 Upsert incremental (delta sync)

```sql
-- [PSQL] Synchronisation incrementale : mettre a jour les donnees modifiees
-- Pattern utilise pendant la phase de coexistence avant bascule complete

INSERT INTO public.employes_local
    (emp_id, nom, prenom, poste, salaire, dept_id,
     date_embauche, email, actif, commentaire, migre_le)
SELECT
    emp_id,
    nom,
    prenom,
    poste,
    salaire,
    dept_id,
    date_emb::date,
    email,
    CASE WHEN actif = 1 THEN TRUE ELSE FALSE END,
    commentaire,
    NOW()
FROM fdw_oracle.employes
ON CONFLICT (emp_id) DO UPDATE SET
    nom          = EXCLUDED.nom,
    prenom       = EXCLUDED.prenom,
    poste        = EXCLUDED.poste,
    salaire      = EXCLUDED.salaire,
    email        = EXCLUDED.email,
    actif        = EXCLUDED.actif,
    commentaire  = EXCLUDED.commentaire,
    migre_le     = NOW()
WHERE
    employes_local.salaire      <> EXCLUDED.salaire
    OR employes_local.poste     <> EXCLUDED.poste
    OR employes_local.actif     <> EXCLUDED.actif;
```

---

## PARTIE 10 — Depannage et Erreurs Frequentes

### Erreur : `OCI library not found`

```bash
# Symptome :
# ERROR: could not load library "oracle_fdw.so":
#        libclntsh.so.19.1: cannot open shared object file

# [SHELL] Verifier que ldconfig a bien enregistre les libs Oracle
ldconfig -p | grep libclntsh

# Si absent, verifier le chemin et relancer ldconfig
ls /usr/lib/oracle/19.x/client64/lib/libclntsh*
echo '/usr/lib/oracle/19.x/client64/lib' | \
    sudo tee /etc/ld.so.conf.d/oracle-instantclient.conf
sudo ldconfig

# Verifier les variables d'environnement PostgreSQL
sudo cat /etc/postgresql/16/main/environment

# Redemarrer PostgreSQL apres toute modification d'environment
sudo systemctl restart postgresql
```

### Erreur : `could not connect to Oracle server`

```sql
-- Symptome :
-- ERROR: cannot connect to foreign server "oracle_SERVICE_NAME"
-- DETAIL: ORA-12541: TNS:no listener

-- 1. Tester la connectivite reseau
-- [SHELL] nc -zv ORACLE_IP_ADDR 1521

-- 2. Tester avec sqlplus si disponible
-- [SHELL] sqlplus fdw_reader/FdwReader2024!@//ORACLE_IP_ADDR:1521/SERVICE_NAME

-- 3. Verifier la chaine de connexion dans le SERVER
SELECT srvoptions FROM pg_foreign_server WHERE srvname = 'oracle_SERVICE_NAME';

-- 4. Modifier si necessaire
ALTER SERVER oracle_SERVICE_NAME
    OPTIONS (SET dbserver '//ORACLE_IP_ADDR:1521/SERVICE_NAME');
```

### Erreur : `ORA-01017: invalid username/password`

```sql
-- Recreer le user mapping avec les bons credentials
DROP USER MAPPING IF EXISTS FOR fdw_user SERVER oracle_SERVICE_NAME;

CREATE USER MAPPING FOR fdw_user
    SERVER oracle_SERVICE_NAME
    OPTIONS (user 'fdw_reader', password 'FdwReader2024!');
```

### Erreur : `invalid input syntax for type` (problemes de types)

```sql
-- Symptome :
-- ERROR: invalid input syntax for type integer: "   10"
-- Cause : Oracle peut renvoyer des CHAR avec espaces de padding

-- Recreer la foreign table avec VARCHAR au lieu de CHAR
-- ou TRIM() dans une vue locale :
CREATE VIEW fdw_oracle.v_employes_clean AS
SELECT
    emp_id,
    TRIM(nom)    AS nom,
    TRIM(prenom) AS prenom,
    dept_id,
    salaire
FROM fdw_oracle.employes;
```

### Erreur : `User mapping not found`

```sql
-- Symptome :
-- ERROR: user mapping not found for "fdw_user"

-- Creer le mapping manquant
CREATE USER MAPPING FOR fdw_user
    SERVER oracle_SERVICE_NAME
    OPTIONS (user 'fdw_reader', password 'FdwReader2024!');
```

### Modifier le mot de passe du User Mapping

```sql
-- [PSQL]
ALTER USER MAPPING FOR fdw_user
    SERVER oracle_SERVICE_NAME
    OPTIONS (SET password 'NouveauMotDePasse!');
```

---

## PARTIE 11 — Nettoyage du Lab

```sql
-- [PSQL] Supprimer tous les objets crees lors du lab

\c lab_oracle_fdw

-- Supprimer les vues locales
DROP VIEW IF EXISTS public.v_employes_actifs CASCADE;
DROP VIEW IF EXISTS public.v_projets_actifs  CASCADE;
DROP VIEW IF EXISTS public.v_recap_rh        CASCADE;

-- Supprimer les tables locales de migration
DROP TABLE IF EXISTS public.employes_local     CASCADE;
DROP TABLE IF EXISTS public.departements_local CASCADE;
DROP TABLE IF EXISTS public.projets_local      CASCADE;
DROP TABLE IF EXISTS public.equipes            CASCADE;

-- Supprimer les foreign tables
DROP FOREIGN TABLE IF EXISTS fdw_oracle.employes     CASCADE;
DROP FOREIGN TABLE IF EXISTS fdw_oracle.departements CASCADE;
DROP FOREIGN TABLE IF EXISTS fdw_oracle.projets      CASCADE;

-- Supprimer le schema FDW
DROP SCHEMA IF EXISTS fdw_oracle CASCADE;

-- Supprimer les user mappings
DROP USER MAPPING IF EXISTS FOR postgres SERVER oracle_SERVICE_NAME;
DROP USER MAPPING IF EXISTS FOR fdw_user  SERVER oracle_SERVICE_NAME;

-- Supprimer le serveur Oracle
DROP SERVER IF EXISTS oracle_SERVICE_NAME CASCADE;

-- Supprimer l'extension
DROP EXTENSION IF EXISTS oracle_fdw CASCADE;

-- Se reconnecter a postgres pour supprimer la base
\c postgres

DROP DATABASE IF EXISTS lab_oracle_fdw;
DROP ROLE    IF EXISTS fdw_user;
```

---

## Reference : Mapping des Types Oracle vers PostgreSQL

| Type Oracle | Type PostgreSQL | Notes |
|---|---|---|
| `NUMBER(p,s)` | `NUMERIC(p,s)` | Precision exacte |
| `NUMBER(p)` | `BIGINT` si p<=18, sinon `NUMERIC` | |
| `NUMBER` | `FLOAT8` | Perte de precision possible |
| `VARCHAR2(n)` | `VARCHAR(n)` | n = caracteres |
| `NVARCHAR2(n)` | `VARCHAR(n)` | Activer `nchar='true'` |
| `CHAR(n)` | `CHAR(n)` | Padding avec espaces |
| `DATE` | `TIMESTAMP` | Oracle DATE contient l'heure ! |
| `TIMESTAMP(n)` | `TIMESTAMP(n)` | |
| `TIMESTAMP WITH TIME ZONE` | `TIMESTAMPTZ` | |
| `CLOB` / `NCLOB` | `TEXT` | Taille via `max_long` |
| `BLOB` | `BYTEA` | Donnees binaires |
| `RAW(n)` | `BYTEA` | |
| `XMLTYPE` | `XML` | Activer `xmltype='true'` |
| `INTEGER` | `INTEGER` | |
| `FLOAT` | `DOUBLE PRECISION` | |

---

## Recapitulatif des Parametres du Lab

| Objet | Valeur |
|---|---|
| **Oracle** | |
| Adresse Oracle | `ORACLE_IP_ADDR` |
| Port Listener | `1521` |
| Service PDB | `SERVICE_NAME` |
| Chaine OCI | `//ORACLE_IP_ADDR:1521/SERVICE_NAME` |
| User Oracle (lecture) | `fdw_reader` / `FdwReader2024!` |
| Schema Oracle | `DEMO` |
| **PostgreSQL** | |
| Port PostgreSQL | `5432` |
| Base de donnees | `lab_oracle_fdw` |
| User applicatif | `fdw_user` / `FdwUser2024!` |
| Schema FDW | `fdw_oracle` |
| Nom du SERVER | `oracle_SERVICE_NAME` |
| **Oracle Instant Client** | |
| Version | `19.x` (compatible Oracle 12c+) |
| Chemin installation | `/usr/lib/oracle/19.x/client64` |
| ORACLE_HOME | `/usr/lib/oracle/19.x/client64` |
| LD_LIBRARY_PATH | `/usr/lib/oracle/19.x/client64/lib` |

---

*Lab oracle_fdw -- PostgreSQL 16 (port 5432) vers Oracle 12c SERVICE_NAME (ORACLE_IP_ADDR:1521)*
