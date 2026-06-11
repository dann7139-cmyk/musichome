-- ============================================================
-- DARICEFY - 32_penalizacion_y_chat.sql
-- Penalización ligera por cancelación tardía + sistema de chat
-- Ejecutar en Supabase SQL Editor
-- ============================================================

-- ─────────────────────────────────────────────────────────────
-- 1. Penalización: nuevas columnas
-- ─────────────────────────────────────────────────────────────
ALTER TABLE public.groups
  ADD COLUMN IF NOT EXISTS search_penalty INTEGER NOT NULL DEFAULT 0;

ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS late_cancellation BOOLEAN NOT NULL DEFAULT false;

-- ─────────────────────────────────────────────────────────────
-- 2. Actualizar trigger de reputación con lógica de penalización
--    (reemplaza la función creada en 31_niveles_reputacion.sql)
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.update_group_reputation()
RETURNS TRIGGER AS $func$
BEGIN
  IF OLD.status = NEW.status THEN
    RETURN NEW;
  END IF;

  -- ── Evento completado → +10 puntos, +1 evento, bajar penalización ──
  IF NEW.status = 'completed' AND OLD.status != 'completed' THEN
    UPDATE public.groups
    SET
      total_eventos_completados = total_eventos_completados + 1,
      puntos_reputacion         = puntos_reputacion + 10,
      search_penalty            = GREATEST(0, search_penalty - 5), -- recupera 5 por evento bueno
      nivel = public.calculate_group_level(
        total_eventos_completados + 1,
        COALESCE(rating, 4.5),
        cancelaciones
      )
    WHERE id = NEW.group_id;
  END IF;

  -- ── Grupo cancela reserva ya aceptada/confirmada → penalización ──
  IF NEW.status = 'cancelled' AND OLD.status IN ('accepted', 'confirmed') THEN
    -- Marcar la reserva como cancelación tardía
    NEW.late_cancellation := true;

    UPDATE public.groups
    SET
      cancelaciones     = cancelaciones + 1,
      puntos_reputacion = GREATEST(0, puntos_reputacion - 20),
      search_penalty    = LEAST(100, search_penalty + 25), -- máx 100
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
-- 3. Tabla de mensajes del chat (por reserva)
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.reservation_messages (
  id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  reservation_id UUID        NOT NULL REFERENCES public.reservations(id) ON DELETE CASCADE,
  sender_id      UUID        NOT NULL REFERENCES public.profiles(id),
  sender_name    TEXT        NOT NULL,
  sender_role    TEXT        NOT NULL CHECK (sender_role IN ('group', 'client')),
  content        TEXT        NOT NULL CHECK (char_length(content) BETWEEN 1 AND 500),
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Índice para consultas rápidas por reserva
CREATE INDEX IF NOT EXISTS idx_reservation_messages_reservation
  ON public.reservation_messages(reservation_id, created_at);

-- ─────────────────────────────────────────────────────────────
-- 4. RLS en reservation_messages
-- ─────────────────────────────────────────────────────────────
ALTER TABLE public.reservation_messages ENABLE ROW LEVEL SECURITY;

-- Admin: acceso total
CREATE POLICY "admin_all_messages" ON public.reservation_messages
  FOR ALL
  TO authenticated
  USING (
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- Grupo: puede leer/escribir en reservas donde es el dueño del grupo
CREATE POLICY "group_own_messages" ON public.reservation_messages
  FOR ALL
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.reservations r
      JOIN public.groups g ON g.id = r.group_id
      WHERE r.id = reservation_messages.reservation_id
        AND g.owner_id = auth.uid()
    )
  );

-- Cliente: puede leer/escribir en sus propias reservas
CREATE POLICY "client_own_messages" ON public.reservation_messages
  FOR ALL
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.reservations r
      WHERE r.id = reservation_messages.reservation_id
        AND r.client_id = auth.uid()
    )
  );

-- ─────────────────────────────────────────────────────────────
-- 5. Trigger: eliminar mensajes automáticamente al terminar evento
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.cleanup_event_messages()
RETURNS TRIGGER AS $func$
BEGIN
  -- Cuando se establece event_ended_at (antes era NULL, ahora tiene valor)
  IF NEW.event_ended_at IS NOT NULL AND OLD.event_ended_at IS NULL THEN
    DELETE FROM public.reservation_messages
    WHERE reservation_id = NEW.id;
  END IF;
  RETURN NEW;
END;
$func$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS cleanup_messages_on_event_end ON public.reservations;
CREATE TRIGGER cleanup_messages_on_event_end
  AFTER UPDATE ON public.reservations
  FOR EACH ROW
  EXECUTE FUNCTION public.cleanup_event_messages();

-- ─────────────────────────────────────────────────────────────
-- 6. Activar Realtime para el chat en tiempo real
-- ─────────────────────────────────────────────────────────────

-- Necesario para que Supabase transmita cambios individuales de fila
ALTER TABLE public.reservation_messages REPLICA IDENTITY FULL;

-- Agregar la tabla a la publicación de Realtime
ALTER PUBLICATION supabase_realtime ADD TABLE public.reservation_messages;

SELECT 'Penalización y chat configurados correctamente ✅' AS status;
