-- ══════════════════════════════════════════════════════════════════════════════
-- 26_member_reservations.sql
-- Sistema de confirmaciones de integrantes para reservas de grupo.
-- Ejecutar en Supabase SQL Editor.
-- ══════════════════════════════════════════════════════════════════════════════

-- ── 1. Tabla: reservation_member_confirmations ────────────────────────────────
CREATE TABLE IF NOT EXISTS reservation_member_confirmations (
  id              uuid        DEFAULT gen_random_uuid() PRIMARY KEY,
  reservation_id  uuid        REFERENCES reservations(id) ON DELETE CASCADE NOT NULL,
  user_id         uuid        REFERENCES profiles(id)     ON DELETE CASCADE NOT NULL,
  status          text        DEFAULT 'pending'
                              CHECK (status IN ('pending', 'confirmed', 'declined')),
  confirmed_at    timestamptz,
  created_at      timestamptz DEFAULT now(),
  UNIQUE (reservation_id, user_id)
);

-- ── 2. RLS ────────────────────────────────────────────────────────────────────
ALTER TABLE reservation_member_confirmations ENABLE ROW LEVEL SECURITY;

-- Cualquier miembro del grupo (o el dueño) puede leer los confirmaciones de su reserva
CREATE POLICY "Group members can view confirmations"
  ON reservation_member_confirmations FOR SELECT
  USING (
    user_id = auth.uid()
    OR EXISTS (
      SELECT 1 FROM reservations r
      WHERE r.id = reservation_id
        AND (
          -- es el dueño del grupo
          r.group_id IN (SELECT id FROM groups WHERE owner_id = auth.uid())
          OR
          -- es un integrante aceptado del grupo
          r.group_id IN (
            SELECT group_id FROM job_invitations
            WHERE invited_user_id = auth.uid()
              AND status = 'accepted'
              AND event_id IS NULL
          )
        )
    )
  );

-- Cada usuario sólo actualiza su propia fila
CREATE POLICY "Members can update their own confirmation"
  ON reservation_member_confirmations FOR UPDATE
  USING (user_id = auth.uid());

-- ── 3. RPC: get_reservation_confirmations ────────────────────────────────────
-- Devuelve todas las confirmaciones de una reserva con datos del perfil.
-- SECURITY DEFINER para evitar recursión de RLS.
CREATE OR REPLACE FUNCTION get_reservation_confirmations(p_reservation_id uuid)
RETURNS TABLE (
  id             uuid,
  reservation_id uuid,
  user_id        uuid,
  status         text,
  confirmed_at   timestamptz,
  full_name      text,
  avatar_url     text,
  is_owner       boolean
) LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  RETURN QUERY
    SELECT
      rmc.id,
      rmc.reservation_id,
      rmc.user_id,
      rmc.status,
      rmc.confirmed_at,
      p.full_name,
      p.avatar_url,
      (g.owner_id = rmc.user_id) AS is_owner
    FROM reservation_member_confirmations rmc
    JOIN profiles p ON p.id = rmc.user_id
    JOIN reservations r ON r.id = rmc.reservation_id
    JOIN groups g ON g.id = r.group_id
    WHERE rmc.reservation_id = p_reservation_id;
END;
$$;

-- ── 4. RPC: confirm_member_attendance ────────────────────────────────────────
-- El integrante confirma o declina su asistencia.
-- Cuando TODOS confirman → la reserva pasa a 'confirmed' y se notifica al cliente.
CREATE OR REPLACE FUNCTION confirm_member_attendance(
  p_reservation_id uuid,
  p_status         text   -- 'confirmed' | 'declined'
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_total     int;
  v_confirmed int;
  v_client_id uuid;
  v_event_date text;
  v_res_status text;
BEGIN
  -- 1. Actualizar la fila del usuario actual
  UPDATE reservation_member_confirmations
  SET status       = p_status,
      confirmed_at = CASE WHEN p_status = 'confirmed' THEN now() ELSE NULL END
  WHERE reservation_id = p_reservation_id
    AND user_id = auth.uid();

  -- 2. Sólo si el usuario confirmó (no declinó), checar si todos confirmaron
  IF p_status = 'confirmed' THEN
    SELECT COUNT(*) INTO v_total
    FROM reservation_member_confirmations
    WHERE reservation_id = p_reservation_id;

    SELECT COUNT(*) INTO v_confirmed
    FROM reservation_member_confirmations
    WHERE reservation_id = p_reservation_id
      AND status = 'confirmed';

    -- 3. Si todos confirman → reserva confirmada
    IF v_total > 0 AND v_confirmed = v_total THEN
      SELECT status INTO v_res_status FROM reservations WHERE id = p_reservation_id;

      IF v_res_status IN ('pending', 'pending_group_confirmation', 'pending_payment') THEN
        UPDATE reservations
        SET status = 'confirmed'
        WHERE id = p_reservation_id;

        -- 4. Notificar al cliente
        SELECT client_id, event_date
        INTO v_client_id, v_event_date
        FROM reservations WHERE id = p_reservation_id;

        IF v_client_id IS NOT NULL THEN
          INSERT INTO notifications (user_id, type, title, message, reference_id)
          VALUES (
            v_client_id,
            'reservation',
            '✅ Reserva confirmada',
            'El grupo confirmó tu reserva para el ' || v_event_date || '. ¡Todo listo!',
            p_reservation_id
          );
        END IF;
      END IF;
    END IF;
  END IF;
END;
$$;

-- ── 5. Función: crear confirmaciones cuando llega una reserva ─────────────────
CREATE OR REPLACE FUNCTION create_member_confirmations_on_reservation()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_owner_id  uuid;
  v_member_id uuid;
BEGIN
  -- Sólo para reservas de grupo
  IF NEW.group_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- Obtener el dueño del grupo
  SELECT owner_id INTO v_owner_id FROM groups WHERE id = NEW.group_id;

  -- Crear fila para el dueño
  IF v_owner_id IS NOT NULL THEN
    INSERT INTO reservation_member_confirmations (reservation_id, user_id, status)
    VALUES (NEW.id, v_owner_id, 'pending')
    ON CONFLICT (reservation_id, user_id) DO NOTHING;
  END IF;

  -- Crear fila y notificación para cada integrante aceptado
  FOR v_member_id IN
    SELECT ji.invited_user_id
    FROM job_invitations ji
    WHERE ji.group_id = NEW.group_id
      AND ji.status   = 'accepted'
      AND ji.event_id IS NULL
      AND (v_owner_id IS NULL OR ji.invited_user_id != v_owner_id)
  LOOP
    INSERT INTO reservation_member_confirmations (reservation_id, user_id, status)
    VALUES (NEW.id, v_member_id, 'pending')
    ON CONFLICT (reservation_id, user_id) DO NOTHING;

    -- Notificar al integrante
    INSERT INTO notifications (user_id, type, title, message, reference_id)
    VALUES (
      v_member_id,
      'reservation',
      '🎵 Nueva reserva del grupo',
      'Tu grupo recibió una nueva reserva. Entra para confirmar tu disponibilidad.',
      NEW.id
    );
  END LOOP;

  RETURN NEW;
END;
$$;

-- Crear el trigger (si ya existe, eliminarlo primero para recrear)
DROP TRIGGER IF EXISTS trg_create_member_confirmations ON reservations;
CREATE TRIGGER trg_create_member_confirmations
  AFTER INSERT ON reservations
  FOR EACH ROW EXECUTE FUNCTION create_member_confirmations_on_reservation();

-- ── 6. Función: notificar a integrantes cuando el evento inicia ───────────────
CREATE OR REPLACE FUNCTION notify_members_on_event_start()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_member_id uuid;
BEGIN
  -- Sólo cuando cambia a in_progress y es reserva de grupo
  IF (OLD.status IS DISTINCT FROM NEW.status)
     AND NEW.status = 'in_progress'
     AND NEW.group_id IS NOT NULL
  THEN
    FOR v_member_id IN
      SELECT user_id
      FROM reservation_member_confirmations
      WHERE reservation_id = NEW.id
        AND status = 'confirmed'
        AND user_id != auth.uid()  -- no notificar a quien inició
    LOOP
      INSERT INTO notifications (user_id, type, title, message, reference_id)
      VALUES (
        v_member_id,
        'reservation',
        '🎵 ¡El evento comenzó!',
        'El evento de tu grupo ha iniciado. Puedes ver el temporizador en vivo.',
        NEW.id
      );
    END LOOP;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_members_event_start ON reservations;
CREATE TRIGGER trg_notify_members_event_start
  AFTER UPDATE ON reservations
  FOR EACH ROW EXECUTE FUNCTION notify_members_on_event_start();
