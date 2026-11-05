-- ═══════════════════════════════════════════════════════════════════════════════════════════
-- Aislamiento por servicio en truckcar_db: un rol y un esquema por microservicio.
-- Idempotente; lo ejecuta el job db-init (docker-compose) como administrador en cada arranque.
--
--  * Cada servicio se conecta con su propio rol, dueño solo de su esquema: no puede leer ni escribir
--    las tablas de otro servicio. search_path del rol = <esquema>, public (PostGIS vive en public).
--  * Migración de bases existentes: las tablas que Hibernate creó en public se mueven al esquema de su
--    servicio (ALTER TABLE ... SET SCHEMA conserva filas, índices, restricciones y secuencias).
--  * Después cada servicio aplica sus migraciones Flyway en su esquema (V1 idempotente).
--
-- Variables psql: una contraseña por rol (pw_<esquema>), definidas en docker-compose.yml.
-- ═══════════════════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on

-- PostGIS en public (la imagen postgis ya la crea en truckcar_db; aquí por si la base se creó a mano).
CREATE EXTENSION IF NOT EXISTS postgis;

CREATE TEMP TABLE service_schemas (schema_name text PRIMARY KEY, role_password text NOT NULL, tables text[] NOT NULL);
INSERT INTO service_schemas VALUES
    ('user_identity',        :'pw_user_identity',        ARRAY['users', 'refresh_tokens']),
    ('load_allocation',      :'pw_load_allocation',      ARRAY['freight_loads', 'freight_load_discarded_drivers',
                                                               'freight_load_pod_media', 'load_allocation_outbox_events']),
    ('fleets_drivers',       :'pw_fleets_drivers',       ARRAY['fleets_drivers_outbox_events']),
    ('community_alerts',     :'pw_community_alerts',     ARRAY['road_alerts', 'road_alert_confirmations',
                                                               'community_alerts_outbox_events']),
    ('routing_restrictions', :'pw_routing_restrictions', ARRAY['road_restrictions']),
    ('fleet_allocation',     :'pw_fleet_allocation',     ARRAY['allocation_decisions']),
    ('route_ai_agent',       :'pw_route_ai_agent',       ARRAY['route_decision_logs']),
    ('notifications',        :'pw_notifications',        ARRAY['notifications', 'notification_templates', 'audio_cache']);

DO $$
DECLARE
    svc record;
    tbl text;
    obj record;
    has_migrations boolean;
BEGIN
    FOR svc IN SELECT * FROM service_schemas LOOP
        -- La contraseña solo se asigna al crear el rol. Volver a asignarla en cada arranque cambia la sal SCRAM y
        -- PgBouncer (que se autentica en PostgreSQL con las claves obtenidas al iniciar sesión el cliente) deja de
        -- poder abrir conexiones nuevas hasta que los servicios reconectan. Rotación: ALTER ROLE manual y reinicio.
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = svc.schema_name) THEN
            EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', svc.schema_name, svc.role_password);
        END IF;
        -- RDS y Azure Flexible Server (PostgreSQL 16): el administrador no es superusuario y crear un rol solo le da
        -- ADMIN OPTION; para darle el esquema y sus tablas necesita SET ROLE. Sin INHERIT: no hereda sus permisos.
        IF NOT pg_has_role(current_user, svc.schema_name, 'SET') THEN
            EXECUTE format('GRANT %I TO %I WITH SET TRUE, INHERIT FALSE', svc.schema_name, current_user);
        END IF;
        EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I AUTHORIZATION %I', svc.schema_name, svc.schema_name);
        EXECUTE format('ALTER SCHEMA %I OWNER TO %I', svc.schema_name, svc.schema_name);
        EXECUTE format('ALTER ROLE %I SET search_path = %I, public', svc.schema_name, svc.schema_name);
        -- Tipos y funciones de PostGIS (geometry, ST_DWithin) están en public: uso, no creación.
        EXECUTE format('GRANT USAGE ON SCHEMA public TO %I', svc.schema_name);
        EXECUTE format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), svc.schema_name);

        -- Base existente: mover las tablas del servicio desde public, solo si aún no existen en su esquema.
        FOREACH tbl IN ARRAY svc.tables LOOP
            IF to_regclass(format('public.%I', tbl)) IS NOT NULL THEN
                IF to_regclass(format('%I.%I', svc.schema_name, tbl)) IS NULL THEN
                    EXECUTE format('ALTER TABLE public.%I SET SCHEMA %I', tbl, svc.schema_name);
                    RAISE NOTICE 'Tabla public.% movida al esquema %', tbl, svc.schema_name;
                ELSE
                    RAISE WARNING 'public.% y %.% existen a la vez: se conserva public.% para revisión manual',
                        tbl, svc.schema_name, tbl, tbl;
                END IF;
            END IF;
        END LOOP;

        -- El rol del servicio es dueño de todo lo que hay en su esquema (Flyway necesita ALTER/CREATE).
        FOR obj IN SELECT c.relname, c.relkind FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                    WHERE n.nspname = svc.schema_name AND c.relkind IN ('r', 'p', 'v', 'm')
        LOOP
            EXECUTE format('ALTER TABLE %I.%I OWNER TO %I', svc.schema_name, obj.relname, svc.schema_name);
        END LOOP;
        FOR obj IN SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                    WHERE n.nspname = svc.schema_name AND c.relkind = 'S'
                      AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = c.oid AND d.deptype IN ('a', 'i'))
        LOOP
            EXECUTE format('ALTER SEQUENCE %I.%I OWNER TO %I', svc.schema_name, obj.relname, svc.schema_name);
        END LOOP;
    END LOOP;

    -- Historiales de Flyway que vivían en public (antes del aislamiento): cada servicio lleva ahora el suyo
    -- dentro de su esquema.
    DROP TABLE IF EXISTS public.flyway_schema_history_user_identity;
    DROP TABLE IF EXISTS public.flyway_schema_history_community_alerts;
    -- SQL dinámico: la tabla puede no existir (ya se borró en un arranque anterior) y PL/pgSQL no la resolvería.
    IF to_regclass('public.flyway_schema_history') IS NOT NULL THEN
        EXECUTE 'SELECT EXISTS (SELECT 1 FROM public.flyway_schema_history WHERE type <> ''BASELINE'')' INTO has_migrations;
        IF NOT has_migrations THEN
            DROP TABLE public.flyway_schema_history;
        END IF;
    END IF;
END $$;
