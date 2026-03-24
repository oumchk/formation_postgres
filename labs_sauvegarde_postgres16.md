# Sauvegarde & Restauration PostgreSQL 16

> **OS :** Ubuntu 24.04 LTS · **Outils :** natifs PostgreSQL uniquement · **

| Élément | Valeur |
|---|---|
| Instance PostgreSQL | Port 5432 — `/var/lib/postgresql/16/main` |
| Base de données de test | `formation` |
| Répertoire sauvegardes | `/var/lib/postgresql/sauvegardes/` |
| Répertoire archives WAL | `/var/lib/postgresql/16/sauvegardes/archives/` |
| Serveur SSH simulé | `backupssh@localhost` — `/srv/backup-ssh/` |
| Serveur FTP simulé | `backupftp@localhost` — `/srv/backup-ftp/` (port 21) |



##  0 — Prérequis : Installation et préparation 

### 0.1 Vérification de l'installation PostgreSQL 16

```bash
# Vérifier la version installée
psql --version

# Vérifier l'état du service
sudo systemctl status postgresql

# Activer le démarrage automatique
sudo systemctl enable postgresql

# Démarrer si nécessaire
sudo systemctl start postgresql
```

### 0.2 Création des répertoires de travail

```bash
sudo mkdir -p /var/lib/postgresql/sauvegardes/{logique,physique,basebackup}
sudo mkdir -p /var/lib/postgresql/16/sauvegardes/archives
sudo chown -R postgres:postgres /var/lib/postgresql/sauvegardes
sudo chown -R postgres:postgres /var/lib/postgresql/16/sauvegardes
sudo chmod 700 /var/lib/postgresql/sauvegardes
sudo chmod 700 /var/lib/postgresql/16/sauvegardes
```

### 0.3 Création de la base et des tables de test

```sql
-- Se connecter en tant que postgres
-- sudo -u postgres psql

-- Créer la base de test
CREATE DATABASE formation;
\c formation

-- Table commandes (sera supprimée dans les tests)
CREATE TABLE commandes (
  id          SERIAL PRIMARY KEY,
  produit     TEXT NOT NULL,
  quantite    INTEGER,
  montant     NUMERIC(10,2),
  created_at  TIMESTAMP DEFAULT now()
);

-- Table clients (recevra des données dans les tests)
CREATE TABLE clients (
  id          SERIAL PRIMARY KEY,
  nom         TEXT NOT NULL,
  email       TEXT,
  created_at  TIMESTAMP DEFAULT now()
);

-- Table journaux_operations (log des opérations)
CREATE TABLE journaux_operations (
  id        SERIAL PRIMARY KEY,
  operation TEXT,
  ts        TIMESTAMP DEFAULT now()
);

-- Insérer des données initiales dans commandes
INSERT INTO commandes (produit, quantite, montant) VALUES
  ('Laptop Pro',          2,  2499.00),
  ('Souris ergonomique', 10,   349.90),
  ('Écran 27"',           5,  1875.50),
  ('Clavier mécanique',   8,   640.00),
  ('Casque USB',          3,   225.00);

-- Insérer quelques clients initiaux
INSERT INTO clients (nom, email) VALUES
  ('Alice Dupont', 'alice@example.com'),
  ('Bob Martin',   'bob@example.com');

-- Vérifier
SELECT * FROM commandes;
SELECT * FROM clients;
\q
```

### 0.4 Simulation de serveurs SSH et FTP locaux


```bash
# Créer un utilisateur dédié SSH
sudo useradd -m -d /srv/backup-ssh -s /bin/bash backupssh
sudo mkdir -p /srv/backup-ssh
sudo chown backupssh:backupssh /srv/backup-ssh

# Configurer les clés SSH (sans mot de passe pour les scripts)
sudo -u postgres ssh-keygen -t rsa -b 4096 -f /var/lib/postgresql/.ssh/id_rsa -N ''
sudo mkdir -p /srv/backup-ssh/.ssh
sudo cat /var/lib/postgresql/.ssh/id_rsa.pub | sudo tee -a /srv/backup-ssh/.ssh/authorized_keys
sudo chown -R backupssh:backupssh /srv/backup-ssh/.ssh
sudo chmod 700 /srv/backup-ssh/.ssh
sudo chmod 600 /srv/backup-ssh/.ssh/authorized_keys

# Tester la connexion SSH
sudo -u postgres ssh backupssh@localhost 'echo Connexion SSH OK'

# Installer vsftpd pour le FTP
sudo apt install -y vsftpd

# Créer un utilisateur FTP
sudo useradd -m -d /srv/backup-ftp -s /bin/bash backupftp
echo 'backupftp:MotDePasseSecure123' | sudo chpasswd
sudo mkdir -p /srv/backup-ftp
sudo chown backupftp:backupftp /srv/backup-ftp

# Installer lftp pour les scripts
sudo apt install -y lftp
```

---

##  1 — Sauvegarde logique (pg_dump / pg_restore) 


### 1.1 Sauvegarde en format SQL (plain text)

```bash
# Format plain : fichier .sql lisible
sudo -u postgres pg_dump -U postgres -d formation \
  --format=plain \
  --file=/var/lib/postgresql/sauvegardes/logique/formation_plain_$(date +%Y%m%d_%H%M%S).sql

# Vérifier la taille
ls -lh /var/lib/postgresql/sauvegardes/logique/

# Consulter les 30 premières lignes
head -30 /var/lib/postgresql/sauvegardes/logique/formation_plain_*.sql
```

### 1.2 Sauvegarde en format custom (recommandé)

```bash
# Format custom : compressé, permet la restauration sélective
sudo -u postgres pg_dump -U postgres -d formation \
  --format=custom \
  --compress=9 \
  --file=/var/lib/postgresql/sauvegardes/logique/formation_custom_$(date +%Y%m%d_%H%M%S).dump

# Lister le contenu de l'archive
sudo -u postgres pg_restore --list \
  /var/lib/postgresql/sauvegardes/logique/formation_custom_*.dump
```

### 1.3 Sauvegarde d'une seule table

```bash
# Sauvegarder uniquement la table commandes
sudo -u postgres pg_dump -U postgres -d formation \
  --table=commandes \
  --format=custom \
  --file=/var/lib/postgresql/sauvegardes/logique/table_commandes_$(date +%Y%m%d).dump

# Sauvegarder avec données seulement (sans DDL)
sudo -u postgres pg_dump -U postgres -d formation \
  --table=commandes \
  --data-only \
  --format=plain \
  --file=/var/lib/postgresql/sauvegardes/logique/data_commandes_$(date +%Y%m%d).sql
```

### 1.4 Copie vers serveur SSH et FTP

```bash
# Copier vers serveur SSH (scp)
sudo -u postgres scp /var/lib/postgresql/sauvegardes/logique/formation_custom_*.dump \
  backupssh@localhost:/srv/backup-ssh/

# Ou avec rsync (plus efficace pour incrémentiel)
sudo -u postgres rsync -avz \
  /var/lib/postgresql/sauvegardes/logique/ \
  backupssh@localhost:/srv/backup-ssh/logique/

# Copier vers serveur FTP (lftp)
sudo -u postgres lftp -c "
  open -u backupftp,MotDePasseSecure123 ftp://localhost;
  mput /var/lib/postgresql/sauvegardes/logique/*.dump;
  bye"
```

### 1.5 Restauration logique — Scénarios

#### Scénario A : Restauration complète sur nouvelle base

```bash
# 1. Créer une base de réception
sudo -u postgres psql -c "CREATE DATABASE formation_restore;"

# 2. Restaurer depuis format custom
sudo -u postgres pg_restore \
  --dbname=formation_restore \
  --verbose \
  /var/lib/postgresql/sauvegardes/logique/formation_custom_*.dump

# 3. Vérifier
sudo -u postgres psql -d formation_restore -c "SELECT * FROM commandes;"
sudo -u postgres psql -d formation_restore -c "\dt"
```

#### Scénario B : Restauration d'une seule table

```bash
# Restaurer uniquement la table commandes dans la base existante
sudo -u postgres pg_restore \
  --dbname=formation \
  --table=commandes \
  --clean \
  /var/lib/postgresql/sauvegardes/logique/formation_custom_*.dump
```

#### Scénario C : Restauration depuis format SQL plain

```bash
# Créer une base vide
sudo -u postgres psql -c "CREATE DATABASE formation_plain_restore;"

# Restaurer depuis fichier SQL
sudo -u postgres psql -d formation_plain_restore \
  -f /var/lib/postgresql/sauvegardes/logique/formation_plain_*.sql

# Vérifier
sudo -u postgres psql -d formation_plain_restore -c "SELECT count(*) FROM commandes;"
```

---

##  2 — Sauvegarde physique à froid 


### 2.1 Procédure de sauvegarde à froid

```bash
# ÉTAPE 1 : Arrêter PostgreSQL
sudo systemctl stop postgresql
sudo systemctl status postgresql  # Vérifier STOPPED

# ÉTAPE 2 : Copier le répertoire de données
sudo tar -czf \
  /var/lib/postgresql/sauvegardes/physique/froid_$(date +%Y%m%d_%H%M%S).tar.gz \
  /var/lib/postgresql/16/main/

# ÉTAPE 3 : Vérifier l'archive
ls -lh /var/lib/postgresql/sauvegardes/physique/
sudo tar -tzf /var/lib/postgresql/sauvegardes/physique/froid_*.tar.gz | head -20

# ÉTAPE 4 : Redémarrer PostgreSQL
sudo systemctl start postgresql
sudo systemctl status postgresql
```

### 2.2 Copie vers serveur SSH/FTP

```bash
# SSH — transfert sécurisé
sudo -u postgres rsync -avz --progress \
  /var/lib/postgresql/sauvegardes/physique/ \
  backupssh@localhost:/srv/backup-ssh/physique/

# FTP — transfert avec lftp
sudo lftp -u backupftp,MotDePasseSecure123 ftp://localhost <<EOF
mkdir -p /physique
mput /var/lib/postgresql/sauvegardes/physique/froid_*.tar.gz
bye
EOF
```

### 2.3 Restauration à froid complète

```bash
# ÉTAPE 1 : Arrêter PostgreSQL
sudo systemctl stop postgresql

# ÉTAPE 2 : Sauvegarder l'actuel (par précaution)
sudo mv /var/lib/postgresql/16/main /var/lib/postgresql/16/main.bak.$(date +%s)

# ÉTAPE 3 : Extraire la sauvegarde
sudo mkdir -p /var/lib/postgresql/16/main
sudo tar -xzf /var/lib/postgresql/sauvegardes/physique/froid_*.tar.gz \
  -C / --strip-components=0

# ÉTAPE 4 : Corriger les permissions
sudo chown -R postgres:postgres /var/lib/postgresql/16/main
sudo chmod 700 /var/lib/postgresql/16/main

# ÉTAPE 5 : Démarrer PostgreSQL
sudo systemctl start postgresql
sudo systemctl status postgresql

# ÉTAPE 6 : Vérifier
sudo -u postgres psql -c "SELECT datname FROM pg_database;"
sudo -u postgres psql -d formation -c "SELECT count(*) FROM commandes;"
```

---

##  3 — Sauvegarde physique à chaud (pg_basebackup) 

### 3.1 Configuration PostgreSQL pour pg_basebackup

```ini
# /etc/postgresql/16/main/postgresql.conf
wal_level       = replica
archive_mode    = on
archive_command = 'cp %p /var/lib/postgresql/16/sauvegardes/archives/%f'
archive_timeout = 300
max_wal_senders = 3
wal_keep_size   = 512
```

```conf
# /etc/postgresql/16/main/pg_hba.conf — ajouter à la fin :
local   replication   postgres                    trust
host    replication   postgres   127.0.0.1/32     trust
```

```bash
# Redémarrer PostgreSQL pour appliquer
sudo systemctl restart postgresql

# Vérifier les paramètres
sudo -u postgres psql -c "SHOW wal_level;"
sudo -u postgres psql -c "SHOW archive_mode;"
sudo -u postgres psql -c "SHOW archive_command;"

# Forcer un checkpoint et archivage pour test
sudo -u postgres psql -c "CHECKPOINT;"
sudo -u postgres psql -c "SELECT pg_switch_wal();"

# Vérifier que les archives se créent
ls -la /var/lib/postgresql/16/sauvegardes/archives/
```

### 3.2 Exécution de pg_basebackup

#### Format tar (recommandé pour la portabilité)

```bash
sudo -u postgres pg_basebackup \
  -h localhost \
  -U postgres \
  -D /var/lib/postgresql/sauvegardes/basebackup/bb_$(date +%Y%m%d_%H%M%S) \
  --format=tar \
  --gzip \
  --wal-method=stream \
  --checkpoint=fast \
  --progress \
  --verbose

ls -lh /var/lib/postgresql/sauvegardes/basebackup/bb_*/
```

#### Format plain (prêt à l'emploi)

```bash
sudo -u postgres pg_basebackup \
  -h localhost \
  -U postgres \
  -D /var/lib/postgresql/sauvegardes/basebackup/plain_$(date +%Y%m%d_%H%M%S) \
  --format=plain \
  --wal-method=stream \
  --checkpoint=fast \
  --progress
```

### 3.3 Restauration depuis pg_basebackup

```bash
# ÉTAPE 1 : Arrêter PostgreSQL
sudo systemctl stop postgresql

# ÉTAPE 2 : Archiver le répertoire actuel
sudo mv /var/lib/postgresql/16/main /var/lib/postgresql/16/main_old_$(date +%s)
sudo mkdir -p /var/lib/postgresql/16/main

# ÉTAPE 3 : Extraire le backup (format tar)
sudo tar -xzf /var/lib/postgresql/sauvegardes/basebackup/bb_*/base.tar.gz \
  -C /var/lib/postgresql/16/main/

# Extraire aussi le WAL
sudo tar -xzf /var/lib/postgresql/sauvegardes/basebackup/bb_*/pg_wal.tar.gz \
  -C /var/lib/postgresql/16/main/pg_wal/

# ÉTAPE 4 : Permissions
sudo chown -R postgres:postgres /var/lib/postgresql/16/main
sudo chmod 700 /var/lib/postgresql/16/main

# ÉTAPE 5 : Démarrer
sudo systemctl start postgresql
sudo -u postgres psql -c "SELECT count(*) FROM pg_stat_user_tables;"
```

---

##  4 — Archivage continu WAL 


### 4.1 Configuration complète

```ini
# postgresql.conf — Section WAL
wal_level       = replica
archive_mode    = on
archive_command = 'test ! -f /var/lib/postgresql/16/sauvegardes/archives/%f && cp %p /var/lib/postgresql/16/sauvegardes/archives/%f'
archive_timeout = 300
```

```bash
# Appliquer
sudo systemctl reload postgresql

# Vérifier l'archivage
sudo -u postgres psql -c "SELECT * FROM pg_stat_archiver;"
```
##### cree la sauvegarde de base 
```bash
sudo -u postgres pg_basebackup \
  -h localhost \
  -U postgres \
  -D /var/lib/postgresql/sauvegardes/basebackup/plain_$(date +%Y%m%d_%H%M%S) \
  --format=plain \
  --wal-method=stream \
  --checkpoint=fast \
  --progress
```

### 4.2 Surveillance des archives WAL

```sql
-- Forcer la création d'un segment WAL
INSERT INTO journaux_operations(operation) VALUES ('test WAL archivage');
SELECT pg_switch_wal();
```

```bash
# Vérifier les archives créées
ls -lh /var/lib/postgresql/16/sauvegardes/archives/ | tail -10
```

```sql
-- Statistiques archiveur
SELECT archived_count, last_archived_wal,
       last_archived_time, failed_count
FROM pg_stat_archiver;
```

### 4.3 Script de synchronisation automatique vers SSH

```bash
# Créer /usr/local/bin/sync_wal_archives.sh
sudo tee /usr/local/bin/sync_wal_archives.sh << 'SCRIPT'
#!/bin/bash
ARCHIVE_DIR=/var/lib/postgresql/16/sauvegardes/archives
SSH_DEST=backupssh@localhost:/srv/backup-ssh/archives/
rsync -avz --progress $ARCHIVE_DIR/ $SSH_DEST
SCRIPT
sudo chmod +x /usr/local/bin/sync_wal_archives.sh

# Créer une tâche cron (toutes les 15 min)
sudo crontab -u postgres -l > /tmp/cron_postgres
echo '*/15 * * * * /usr/local/bin/sync_wal_archives.sh' >> /tmp/cron_postgres
sudo crontab -u postgres /tmp/cron_postgres

# Tester manuellement
sudo -u postgres /usr/local/bin/sync_wal_archives.sh
```

---

##  5 — PITR : Point-In-Time Recovery (4 modes) 


### 5.1 Préparation du scénario PITR — Création de la timeline
##### $BACKUP_DIR faire un backup ------ initial en format plain 
```sql
-- sudo -u postgres psql -d formation
--Notez précisément les horodatages T0, T1 et T2.** Ils sont indispensables pour le PITR par timestamp.

-- T0 : État initial — noter l'heure
SELECT now() AS t0_debut;

-- Insérer des données dans clients
INSERT INTO clients (nom, email) VALUES
  ('Charles Durand', 'charles@lab.com'),
  ('Diane Petit',    'diane@lab.com'),
  ('Éric Blanc',     'eric@lab.com');

SELECT pg_switch_wal();

-- T1 : Avant la catastrophe — NOTER CET HORODATAGE
SELECT now() AS t1_avant_suppression;
-- Exemple : 2024-03-15 14:30:00

SELECT pg_sleep(2);

-- ÉVÉNEMENT CATASTROPHIQUE
DROP TABLE commandes;

-- T2 : Après la catastrophe
SELECT now() AS t2_apres_suppression;

-- Ajouter encore des données post-catastrophe
INSERT INTO clients (nom, email) VALUES ('Frank Roger', 'frank@lab.com');
SELECT pg_switch_wal();
```


### 5.2 Mode 1 — PITR par Timestamp (`recovery_target_time`)

**Objectif :** Revenir à T1, juste AVANT la suppression de la table `commandes`.

```bash
# ÉTAPE 1 : Arrêter PostgreSQL
sudo systemctl stop postgresql

# ÉTAPE 2 : Sauvegarder le répertoire actuel
sudo mv /var/lib/postgresql/16/main /var/lib/postgresql/16/main.avant_pitr

# ÉTAPE 3 : Copier le basebackup dans main
sudo cp -a $BACKUP_DIR /var/lib/postgresql/16/main
sudo chown -R postgres:postgres /var/lib/postgresql/16/main
sudo chmod 700 /var/lib/postgresql/16/main

# ÉTAPE 4 : Configurer la cible de restauration
## UBBUNUTU le chemin   /etc/postgresql/16/main/postgresql.conf
sudo tee -a /var/lib/postgresql/16/main/postgresql.conf << 'EOF'
# PITR — Mode 1 : Timestamp
restore_command         = 'cp /var/lib/postgresql/16/sauvegardes/archives/%f %p'
recovery_target_time    = 'YYYY-MM-DD h:s:00'   # <-- REMPLACER par T1
recovery_target_action  = 'promote'
recovery_target_inclusive = true
EOF

# ÉTAPE 5 : Créer le fichier signal de recovery
sudo -u postgres touch /var/lib/postgresql/16/main/recovery.signal

# ÉTAPE 6 : Démarrer PostgreSQL en mode recovery
sudo systemctl start postgresql

# ÉTAPE 7 : Surveiller les logs
sudo tail -f /var/log/postgresql/postgresql-16-main.log

# ÉTAPE 8 : Vérifier après recovery
sudo -u postgres psql -d formation -c "SELECT * FROM commandes;"  # doit exister !
sudo -u postgres psql -d formation -c "SELECT * FROM clients;"
```

> ✅ Chercher dans les logs : `recovery stopping before commit` et `database system is ready to accept read-only connections`. Le fichier `recovery.signal` disparaît automatiquement une fois le recovery terminé.

### 5.3 Mode 2 — PITR par LSN (`recovery_target_lsn`)

```sql
-- AVANT le test : récupérer le LSN courant
SELECT pg_current_wal_lsn() AS lsn_avant_drop;
-- Exemple de retour : 0/1A3F5028
```

```bash
sudo tee -a /var/lib/postgresql/16/main/postgresql.conf << 'EOF'
restore_command        = 'cp /var/lib/postgresql/16/sauvegardes/archives/%f %p'
recovery_target_lsn    = '0/1A3F5028'   # <-- LSN noté avant le DROP
recovery_target_action = 'promote'
EOF

sudo -u postgres touch /var/lib/postgresql/16/main/recovery.signal
sudo systemctl start postgresql
```

### 5.4 Mode 3 — PITR par Nom (`recovery_target_name`)

```sql
-- Créer un point de sauvegarde nommé AVANT les opérations
SELECT pg_create_restore_point('avant_maintenance_20240315');
```

```bash
sudo tee -a /var/lib/postgresql/16/main/postgresql.conf << 'EOF'
restore_command          = 'cp /var/lib/postgresql/16/sauvegardes/archives/%f %p'
recovery_target_name     = 'avant_maintenance_20240315'
recovery_target_action   = 'promote'
EOF

sudo -u postgres touch /var/lib/postgresql/16/main/recovery.signal
sudo systemctl start postgresql
```

### 5.5 Mode 4 — PITR Immediate (`recovery_target = 'immediate'`)

Restaure jusqu'au point de cohérence le plus récent du basebackup — utile quand les archives WAL sont corrompues ou manquantes.

```bash
sudo tee -a /var/lib/postgresql/16/main/postgresql.conf << 'EOF'
restore_command        = 'cp /var/lib/postgresql/16/sauvegardes/archives/%f %p'
recovery_target        = 'immediate'
recovery_target_action = 'promote'
EOF

sudo -u postgres touch /var/lib/postgresql/16/main/recovery.signal
sudo systemctl start postgresql
```

### 5.6 Tableau récapitulatif des 4 modes PITR

| Mode | Paramètre | Précision | Cas d'usage |
|---|---|---|---|
| 1 — Timestamp | `recovery_target_time` | À la seconde | Erreur humaine datée |
| 2 — LSN | `recovery_target_lsn` | Maximale (octet WAL) | Précision technique absolue |
| 3 — Nom | `recovery_target_name` | Point marqué manuellement | Maintenance planifiée |
| 4 — Immediate | `recovery_target = 'immediate'` | Fin du basebackup | WAL corrompus/manquants |

---

##  6 — Scénarios de sinistres 

### 6.1 Scénario A — DROP TABLE accidentel

```sql
-- SIMULER L'ACCIDENT
-- sudo -u postgres psql -d formation

SELECT now() AS avant_accident;

INSERT INTO commandes (produit, quantite, montant) VALUES ('Webcam HD', 4, 320.00);
SELECT pg_switch_wal();
SELECT pg_sleep(2);

-- L'ACCIDENT
DROP TABLE commandes;

SELECT now() AS moment_accident;
\dt  -- vérifier la disparition
```

```bash
# Option 1 : PITR par timestamp (préféré si archives WAL disponibles)
# → Voir Section 5.2 — utiliser le timestamp 'avant_accident'

# Option 2 : Restauration depuis pg_dump (si sauvegarde logique récente)
sudo -u postgres pg_restore \
  --dbname=formation \
  --table=commandes \
  --clean \
  /var/lib/postgresql/sauvegardes/logique/formation_custom_*.dump

# Vérifier la récupération
sudo -u postgres psql -d formation -c "SELECT count(*) FROM commandes;"
sudo -u postgres psql -d formation -c "SELECT * FROM commandes ORDER BY id;"
```

### 6.2 Scénario B — Insertion erronée en masse + retour arrière

```sql
-- SIMULER L'INSERTION ERRONÉE
SELECT now() AS avant_insertion_erronee;
SELECT pg_create_restore_point('avant_insert_massif');

INSERT INTO clients (nom, email) VALUES ('Georges', 'g@lab.com');
SELECT pg_sleep(1);

-- L'ERREUR : insertion en masse de faux clients
INSERT INTO clients (nom, email)
SELECT 'Faux_' || g, 'faux' || g || '@spam.com'
FROM generate_series(1, 1000) AS g;

SELECT count(*) FROM clients;  -- 1002+ lignes !
SELECT pg_switch_wal();
```

```bash
# RESTAURATION PAR PITR NOMMÉ
sudo systemctl stop postgresql
sudo mv /var/lib/postgresql/16/main /var/lib/postgresql/16/main.sinistre
sudo cp -a /var/lib/postgresql/sauvegardes/basebackup/bb_*/ /var/lib/postgresql/16/main
sudo chown -R postgres:postgres /var/lib/postgresql/16/main
sudo chmod 700 /var/lib/postgresql/16/main

sudo tee -a /var/lib/postgresql/16/main/postgresql.conf << 'EOF'
restore_command          = 'cp /var/lib/postgresql/16/sauvegardes/archives/%f %p'
recovery_target_name     = 'avant_insert_massif'
recovery_target_action   = 'promote'
EOF

sudo -u postgres touch /var/lib/postgresql/16/main/recovery.signal
sudo systemctl start postgresql

# Vérifier : nombre de clients redevenu normal
sudo -u postgres psql -d formation -c "SELECT count(*) FROM clients;"
```

### 6.3 Scénario C — Perte totale du serveur (restauration depuis SSH)

```bash
# ÉTAPE 1 : Récupérer le basebackup depuis SSH
sudo -u postgres rsync -avz \
  backupssh@localhost:/srv/backup-ssh/basebackup/bb_*/ \
  /var/lib/postgresql/sauvegardes/basebackup/recovered/

# ÉTAPE 2 : Récupérer les archives WAL depuis SSH
sudo -u postgres rsync -avz \
  backupssh@localhost:/srv/backup-ssh/archives/ \
  /var/lib/postgresql/16/sauvegardes/archives/

# ÉTAPE 3 : Arrêter le service (si encore actif)
sudo systemctl stop postgresql

# ÉTAPE 4 : Préparer le répertoire de données
sudo rm -rf /var/lib/postgresql/16/main
sudo mkdir -p /var/lib/postgresql/16/main
sudo cp -a /var/lib/postgresql/sauvegardes/basebackup/recovered/. \
  /var/lib/postgresql/16/main/
sudo chown -R postgres:postgres /var/lib/postgresql/16/main
sudo chmod 700 /var/lib/postgresql/16/main

# ÉTAPE 5 : Configurer recovery jusqu'au dernier WAL disponible
sudo tee -a /var/lib/postgresql/16/main/postgresql.conf << 'EOF'
restore_command        = 'cp /var/lib/postgresql/16/sauvegardes/archives/%f %p'
recovery_target_action = 'promote'
EOF

sudo -u postgres touch /var/lib/postgresql/16/main/recovery.signal

# ÉTAPE 6 : Redémarrer
sudo systemctl start postgresql
sudo -u postgres psql -c "SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database;"
```

---

##  7 — Vérification et checklist finale 

### 7.1 Requêtes de validation post-restauration

```sql
-- sudo -u postgres psql -d formation

-- 1. Lister toutes les tables
\dt

-- 2. Vérifier l'intégrité des données
SELECT 'commandes'           AS table, count(*) FROM commandes
UNION ALL
SELECT 'clients',                      count(*) FROM clients
UNION ALL
SELECT 'journaux_operations',          count(*) FROM journaux_operations;

-- 3. Vérifier les séquences
SELECT sequencename, last_value FROM pg_sequences;

-- 4. Vérifier la cohérence transactionnelle
SELECT pg_is_in_recovery();  -- doit retourner false après promote

-- 5. Vérifier l'état de l'archivage
SELECT archived_count, last_archived_wal, failed_count FROM pg_stat_archiver;

-- 6. Vérifier les connexions actives
SELECT count(*) FROM pg_stat_activity WHERE state = 'active';
```
