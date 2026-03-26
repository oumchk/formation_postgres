# Installer DBD::Oracle via CPAN
apt install -y libdbi-perl 
cpan DBD::Oracle
sudo env ORACLE_HOME=/opt/oracle/instantclient_12_2 \
cpan install DBD::Oracle
 
wget https://github.com/darold/ora2pg/archive/refs/tags/v24.0.tar.gz
tar xzf v24.0.tar.gz
cd ora2pg-24.0
perl Makefile.PL
make
sudo make install
 
# Vérifier l'installation
ora2pg --version

# Iinitialiser le projet 
ora2pg --init_project nom_prj
 
 # Iinitialiser le projet 
ora2pg -c config/ora2pg.conf -t SHOW_VERSION
 
# generer rapport d’audit
ora2pg -c config/ora2pg.conf -t SHOW_REPORT --estimate_cost 

 # Lister des objets 
ora2pg -c config/ora2pg.conf -t SHOW_TABLE

ora2pg -c config/ora2pg.conf -t SHOW_COLUMN

ora2pg -c config/ora2pg.conf -t SHOW_INDEX

# generer ddl 
ora2pg -c config/ora2pg.conf -t ALL 

ora2pg -c config/ora2pg.conf -t TABLE(TRIGGER,INDEX ... ) -o schema.sql
