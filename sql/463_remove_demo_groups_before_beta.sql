-- ============================================================
-- sql/463_remove_demo_groups_before_beta.sql
--
-- ⚠️ CORRER JUSTO ANTES DE LA BETA CERRADA (no antes).
--
-- Elimina TODOS los datos demo/test para que ningún usuario real
-- pueda ver o reservar un grupo falso:
--   - grupos demo de Jalisco (sql/462, jaldemo*@mhtest.dev)
--   - grupos test anteriores (sql/261/265, *@mhtest.dev)
--   - grupos con 🧪 en el nombre
--
-- Regla acordada (2026-07-10): los demo solo se quedan si están
-- claramente marcados y no pueden recibir reservas reales.
-- Como pueden confundirse con grupos reales → se quitan.
-- ============================================================

-- 0. Vista previa: qué se va a borrar (correr primero SOLO esto)
SELECT g.id, g.name, g.city, g.state, u.email
FROM public.groups g
JOIN auth.users u ON u.id = g.owner_id
WHERE u.email LIKE '%@mhtest.dev' OR g.name LIKE '🧪%';

-- 1. Guard: abortar si algún grupo demo tiene reservas REALES pagadas
DO $$
DECLARE
  n INT;
BEGIN
  SELECT COUNT(*) INTO n
  FROM public.reservations r
  JOIN public.groups g ON g.id = r.group_id
  JOIN auth.users u ON u.id = g.owner_id
  WHERE (u.email LIKE '%@mhtest.dev' OR g.name LIKE '🧪%')
    AND r.payment_status IN ('paid', 'fully_paid');
  IF n > 0 THEN
    RAISE EXCEPTION 'Hay % reservas pagadas ligadas a grupos demo. Revisar manualmente antes de borrar.', n;
  END IF;
END;
$$;

-- 2. Borrar grupos 🧪 sueltos (dueños reales, solo el grupo)
DELETE FROM public.groups WHERE name LIKE '🧪%';

-- 3. Borrar usuarios de prueba (cascada: profiles + groups + datos ligados)
DELETE FROM auth.users WHERE email LIKE '%@mhtest.dev';

-- 4. Verificación: debe regresar 0 filas en ambas
SELECT id, name FROM public.groups WHERE name LIKE '🧪%';
SELECT id, email FROM auth.users WHERE email LIKE '%@mhtest.dev';
