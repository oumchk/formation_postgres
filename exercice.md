# exercie
## Lab : ExerciCe 3
Changer de base de données.

Afficher la structure de la table customers.

Afficher la structure détaillée de la table customers, y compris les descriptions (commentaires).

Lister toutes les bases de données.

Lister tous les schémas.

Lister tous les tablespaces.

Exécuter une requête SQL et enregistrer le résultat dans un fichier.

Faire la même chose en enregistrant uniquement les données (sans les en-têtes de colonnes).

Créer un script SQL via une autre méthode, puis l’exécuter depuis psql.

Activer le mode d’affichage étendu des tables (expanded mode).

Lister les tables, vues et séquences avec leurs privilèges d’accès associés.

Afficher le répertoire de travail courant.


# 1-LAB Ercercice 3 
## 1. 
`psql -h localhost -p 5432 postgres postgres`
 
## 2. 
`\c formation storeuser `
## 3.  
` \d customers  `
## 4. 
`\d+ customers`
## 5.  
\l
## 6.  
\dn
## 7.  
\db
## 8.  
```
\o customer_data.txt
SELECT * FROM customers;
\o
```
## 9. 
```
\t
\o customer_data.txt
SELECT * FROM customers;
\o
\t
```

## 10. 
```
 nano emp.sql
 SELECT * FROM emp; 

psql -f emp.sql -d formation -U storeuser  

psql -d formation -U storeuser
```
## 11.  
```
\x
SELECT * FROM dept;
\x
```
## 12. 
 \dp
## 13.  
\! pwd


