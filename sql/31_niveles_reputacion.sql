-- ============================================================
-- DARICEFY - 31_niveles_reputacion.sql
-- Sistema de niveles y reputación para grupos
-- Ejecutar en Supabase SQL Editor
-- ============================================================

-- ─────────────────────────────────────────────────────────────
-- 1. Agregar columnas a la tabla groups
-- ─────────────────────────────────────────────────────────────
ALTER TABLE public.groups
  ADD COLUMN IF NOT EXISTS total_eventos_completados INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS cancelaciones             INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS puntos_reputacion         INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS nivel                     TEXT    NOT NULL DEFAULT 'bronce'
    CHECK (nivel IN ('bronce', 'plata', 'oro', 'elite'));

-- ─────────────────────────────────────────────────────────────
-- 2. Función pura para calcular el nivel según reglas
-- ─────────────────────────────────────────────────────────────
-- ELITE : 51+ eventos, rating >= 4.7, cancelaciones <= 1
-- ORO   : 21-50 eventos, rating >= 4.3, cancelaciones <= 3
-- PLATA : 6-20 eventos, rating >= 4.0
-- BRONCE: el resto
CREATE OR REPLACE FUNCTION public.calculate_group_level(
  p_eventos       INTEGER,
  p_rating        DECIMAL,
  p_cancelaciones INTEGER
) RETURNS TEXT AS $func$
BEGIN
  IF p_eventos >= 51 AND p_rating >= 4.7 AND p_cancelaciones <= 1 THEN
    RETURN 'elite';
  ELSIF p_eventos >= 21 AND p_rating >= 4.3 AND p_cancelaciones <= 3 THEN
    RETURN 'oro';
  ELSIF p_eventos >= 6 AND p_rating >= 4.0 THEN
    RETURN 'plata';
  ELSE
    RETURN 'bronce';
  END IF;
END;
$func$ LANGUAGE plpgsql IMMUTABLE;

-- ─────────────────────────────────────────────────────────────
-- 3. Trigger: actualizar reputación al cambiar estado de reserva
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.update_group_reputation()
RETURNS TRIGGER AS $func$
BEGIN
  -- Sin cambio real de estado → ignorar
  IF OLD.status = NEW.status THEN
    RETURN NEW;
  END IF;

  -- ── Evento completado → +10 puntos, +1 evento ──────────────
  IF NEW.status = 'completed' AND OLD.status != 'completed' THEN
    UPDATE public.groups
    SET
      total_eventos_completados = total_eventos_completados + 1,
      puntos_reputacion         = puntos_reputacion + 10,
      nivel = public.calculate_group_level(
        total_eventos_completados + 1,
        COALESCE(rating, 4.5),
        cancelaciones
      )
    WHERE id = NEW.group_id;
  END IF;

  -- ── Grupo cancela reserva ya aceptada → -20 puntos, +1 cancelación ──
  IF NEW.status = 'cancelled' AND OLD.status IN ('accepted', 'confirmed') THEN
    UPDATE public.groups
    SET
      cancelaciones     = cancelaciones + 1,
      puntos_reputacion = GREATEST(0, puntos_reputacion - 20),
      nivel = public.calculate_group_level(
        total_eventos_completados,
        COALESCE(rating, 4.5),
        cancelaciones + 1
      )
    WHERE id = NEW.group_id;
  END IF;

  RETURN NEW;
END;
$func$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS update_reputation_on_reservation ON public.reservations;
CREATE TRIGGER update_reputation_on_reservation
  AFTER UPDATE ON public.reservations
  FOR EACH ROW
  EXECUTE FUNCTION public.update_group_reputation();

-- ─────────────────────────────────────────────────────────────
-- 4. Recalcular nivel de grupos existentes según sus datos actuales
-- ─────────────────────────────────────────────────────────────
UPDATE public.groups
SET nivel = public.calculate_group_level(
  COALESCE(total_eventos_completados, 0),
  COALESCE(rating, 4.5),
  COALESCE(cancelaciones, 0)
);

SELECT 'Sistema de niveles creado correctamente ✅' AS status;
