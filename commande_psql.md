# commande 
## Historique des commandes
### \s Affiche l’historique
### \s file.sql Sauvegarde l’historique
### \e Édite et exécute le buffer (default vi)
### \setenv EDITOR nano   
### \e file.sql Édite un fichier et l’exécute
### \w file.sql Sauvegarde le buffer
### \set variable value : définir une variable 
### \unset variable : supprimer une variable
### \g exécuter la dernière commande

## Rediriger la sortie
### psql -o file Redirige la sortie vers un fichier
### \o file Redirige la sortie dans psql (-o)
### \g file Exécute et envoie le résultat vers un fichier
### \watch 5 Réexécute la requête toutes les 5 secondes
### \i file.sql executer le contenu du fichier 
### \set : variables internes de psql 
### \pset : liste format d’affichage des résultats.

## Commandes d’information
### \d[(i|s|t|v|b|S)][+] : Liste des objet (index, séquences, tables, vues,  )
### \d[+] [pattern] : decrire la structure detaillée d’un objet
### \l[ist][+] : Liste les base de donnée dans un cluster
### \dn+ [pattern] :Liste les schemas 
### \df[+] [pattern] : Liste les fonctions 
### \q or  ^d or quit or exit


## Commandes d’information
### \cd [ directory ] : changer le répertoire courant
### \! [ command ] : execute une commande systeme (linux/window)
### \conninfo : affiche les information de la connection courante
### \?: aides sur les commandes psql 
### \h [command] : aide sur les commandes SQL
