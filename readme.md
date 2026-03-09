



## Insatallation 
useradd postgres
passwd postgres
sudo apt install -y postgresql-common
sudo apt install postgresql-16 postgresql-client-16

## REDHAT rockylinux
useradd postgres 
passwd postgres
sudo dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm 
sudo dnf -qy module disable postgresql
sudo dnf install -y postgresql16-server
sudo /usr/pgsql-16/bin/postgresql-16-setup initdb
sudo systemctl enable postgresql-16
sudo systemctl start postgresql-16

## Ubuntu
useradd postgres 
passwd postgres
sudo apt install -y postgresql-common
sudo apt install postgresql-16 postgresql-client-16

#Repertoire d'installation
Debian/Ubuntu	/var/lib/postgresql/16/main
RedHat/CentOS	/var/lib/pgsql/16/data
Windows	C:\Program Files\PostgreSQL\16\data
