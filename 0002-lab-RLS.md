## policie 1 
-- liste des roles 
select rolname from pg_roles where rolcanlogin ;
-
```
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO storeuser;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA storeuser TO storeuser;

ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON TABLES TO storeuser;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON SEQUENCES TO storeuser;

ALTER DEFAULT PRIVILEGES IN SCHEMA storeuser GRANT ALL PRIVILEGES ON TABLES TO storeuser;
ALTER DEFAULT PRIVILEGES IN SCHEMA storeuser GRANT ALL PRIVILEGES ON SEQUENCES TO storeuser;

create table storeuser.compte (gestionnaire text, company text,contact_email text);

select * from pg_roles where rolcanlogin;

INSERT INTO storeuser.compte (gestionnaire, company, contact_email)
SELECT (ARRAY['user_responsable','user_admin','storeuser','user_agent'])[floor(random() * 4 + 1)::int] AS gestionnaire,
    'company_' || gs AS company,
	'contact' || gs || '@example.com' AS contact_email
FROM generate_series(1,10000) AS gs;

select count(*),gestionnaire 
from  storeuser.compte
group by 2 ;

ALTER TABLE  storeuser.compte ENABLE ROW LEVEL SECURITY;

CREATE POLICY gestionnaire_view_own ON storeuser.compte FOR SELECT USING (gestionnaire = current_user);
CREATE POLICY admin_access ON storeuser.compte FOR SELECT TO adm USING (true);

```
 

changer les compte utilisateurs pour verifier  'user_responsable','user_admin','storeuser','user_agent'
et faire et 

```
sur le terminal 
se connecter en tant que storeuser e executer 
select count(*),gestionnaire 
from  storeuser.compte
group by 2 ;


refaire la meme operation pour les comptes 'user_responsable','user_admin','user_agent'
```
---------


## policie 2
```

verifier salaire max
select max(sal) from storeuser.emp ;
select count(*)  from storeuser.emp ;

ALTER TABLE storeuser.emp ENABLE ROW LEVEL SECURITY;


CREATE POLICY agent_salary_policy
ON storeuser.emp
FOR SELECT TO agent USING (sal <= 2000 );

CREATE POLICY resp_full_access_policy
ON storeuser.emp
FOR SELECT
TO responsable
USING (true);

sur le terminal
se connecter avec user_agent executer
select max(sal) from storeuser.emp ;
select count(*)  from storeuser.emp ;

faire la meme operation avec user_responsable


--- update 
CREATE POLICY agent_salary_update_policy
ON storeuser.emp
FOR UPDATE
TO agent
USING (sal <= 2000)
WITH CHECK (sal <= 2000);

CREATE POLICY resp_salary_update_policy
ON storeuser.emp
FOR UPDATE
TO responsable
-- USING (sal <= 2000)
WITH CHECK (true);
```
-----------------------------------------------------------