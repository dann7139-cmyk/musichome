-- ============================================================
-- sql/516_f1_constraint.sql — F1 PASO FINAL: EL CANDADO DE MOTOR
--
-- ⚠️ Ejecutar SOLO cuando:
--   1. sql/513 (auditoría) haya dado 0 traslapes (Resultado 1 vacío)
--      y hayas resuelto los zombis/datos incompletos que decidas.
--   2. sql/514 esté aplicado y sql/515 haya pasado.
--
-- PostgreSQL NO permite NOT VALID en constraints de exclusión, así
-- que este archivo PRE-VERIFICA por sí mismo: si existe un solo
-- traslape entre ocupantes, ABORTA sin tocar nada.
--
-- El lock de construcción del índice dura segundos con el volumen
-- actual — ejecutar en horario tranquilo.
-- ============================================================

BEGIN;

-- Pre-verificación dura: aborta si hay traslapes (no confía en nadie)
DO $$
DECLARE v_conflictos INT;
BEGIN
  SELECT COUNT(*) INTO v_conflictos
  FROM reservations a
  JOIN reservations b
    ON b.group_id = a.group_id AND b.id > a.id
   AND a.busy_range && b.busy_range
  WHERE a.status = ANY (public.estados_que_ocupan())
    AND b.status = ANY (public.estados_que_ocupan());
  IF v_conflictos > 0 THEN
    RAISE EXCEPTION 'ABORTADO: % traslape(s) entre ocupantes — resuelve la auditoría 513 primero', v_conflictos;
  END IF;
END $$;

-- Extensión necesaria para mezclar igualdad (uuid) con rangos en GiST
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- 🔒 EL CANDADO: dos ocupantes del mismo grupo JAMÁS se traslapan.
-- Garantía de motor — inmune a RPCs olvidados, webhooks y UPDATEs directos.
ALTER TABLE public.reservations
  ADD CONSTRAINT excl_group_busy_range
  EXCLUDE USING gist (group_id WITH =, busy_range WITH &&)
  WHERE (status = ANY (public.estados_que_ocupan()) AND busy_range IS NOT NULL);

COMMIT;

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
SELECT conname, contype FROM pg_constraint WHERE conname = 'excl_group_busy_range';
-- Esperado: 1 fila, contype 'x' (exclusión)

SELECT '516_f1_constraint.sql ejecutado ✅ — candado de motor ACTIVO' AS status;
