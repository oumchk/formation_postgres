
```sql
CREATE TABLE employes (
    id          SERIAL PRIMARY KEY,
    nom         VARCHAR(100) NOT NULL,
    poste       VARCHAR(100),
    salaire     NUMERIC(10,2),
    actif       BOOLEAN DEFAULT true,
    created_at  TIMESTAMP DEFAULT NOW()
);

CREATE TABLE transactions (
    id          SERIAL PRIMARY KEY,
    employe_id  INTEGER REFERENCES employes(id),
    montant     NUMERIC(10,2),
    type_op     VARCHAR(20),
    created_at  TIMESTAMP DEFAULT NOW()
);

INSERT INTO employes (nom, poste, salaire) VALUES
  ('Alice Dupont',  'DBA',        4500.00),
  ('Bob Martin',    'Développeur',3800.00),
  ('Claire Lebrun', 'DevOps',     4200.00),
  ('David Moreau',  'Analyste',   3600.00),
  ('Eve Lambert',   'Manager',    5500.00);

INSERT INTO transactions (employe_id, montant, type_op) VALUES
  (1,1500.00,'prime'),(2,800.00,'prime'),
  (3,1200.00,'remboursement'),(5,2000.00,'prime');

SELECT 'employes'     AS tbl, COUNT(*) FROM employes
UNION ALL
SELECT 'transactions', COUNT(*) FROM transactions;



INSERT INTO transactions (employe_id, montant, type_op)
SELECT
  (RANDOM()*4+1)::INTEGER,
  ROUND((RANDOM()*5000)::NUMERIC, 2),
  CASE WHEN RANDOM() < 0.5 THEN 'prime' ELSE 'remboursement' END
FROM generate_series(1, 100000);


```
