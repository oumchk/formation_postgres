CREATE TABLE IF NOT EXISTS public.transactions
(
    id integer NOT NULL DEFAULT nextval('transactions_id_seq'::regclass),
    employe_id integer,
    montant numeric(10,2),
    type_op character varying(20) COLLATE pg_catalog."default",
    created_at timestamp without time zone DEFAULT now(),
    CONSTRAINT transactions_pkey PRIMARY KEY (id),
    CONSTRAINT transactions_employe_id_fkey FOREIGN KEY (employe_id)
        REFERENCES public.employes (id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION
)

TABLESPACE pg_default;

ALTER TABLE IF EXISTS public.transactions
    OWNER to postgres;

CREATE TABLE IF NOT EXISTS public.employes
(
    id integer NOT NULL DEFAULT nextval('employes_id_seq'::regclass),
    nom character varying(100) COLLATE pg_catalog."default" NOT NULL,
    poste character varying(100) COLLATE pg_catalog."default",
    salaire numeric(10,2),
    actif boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT now(),
    CONSTRAINT employes_pkey PRIMARY KEY (id)
)

TABLESPACE pg_default;

