-- ══════════════════════════════════════════════════════════════════════════════
-- 36_fix_packages_group_link.sql
-- Vincula los paquetes existentes (group_id = NULL) al grupo correcto.
-- Ejecutar DESPUÉS de 33_package_distribution.sql.
-- ══════════════════════════════════════════════════════════════════════════════

-- ── 1. Ver tus grupos (para confirmar el ID) ───────────────────────────────
SELECT id, name, owner_id FROM public.groups ORDER BY created_at;

-- ── 2. Ver paquetes sin grupo ──────────────────────────────────────────────
SELECT id, name, price FROM public.packages WHERE group_id IS NULL;

-- ── 3. Vincular automáticamente ───────────────────────────────────────────
-- Si solo tienes UN grupo, este query lo hace de forma segura.
-- Si tienes más de uno, comenta este bloque y usa el manual de abajo.
UPDATE public.packages
SET group_id = (
  SELECT id FROM public.groups ORDER BY created_at LIMIT 1
)
WHERE group_id IS NULL;

-- ── (Alternativa manual si tienes varios grupos) ──────────────────────────
-- Pega el ID de tu grupo aquí:
-- UPDATE public.packages SET group_id = 'PEGA-AQUI-EL-ID-DEL-GRUPO' WHERE group_id IS NULL;

-- ── 4. Verificar ──────────────────────────────────────────────────────────
SELECT p.id, p.name, p.price, g.name AS grupo
FROM public.packages p
LEFT JOIN public.groups g ON g.id = p.group_id
ORDER BY p.created_at;

SELECT 'Paquetes vinculados al grupo ✅' AS status;
