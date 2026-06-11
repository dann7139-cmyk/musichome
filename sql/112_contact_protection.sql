-- ════════════════════════════════════════════════════════════════════════════
-- 112_contact_protection.sql
-- Protección de contacto: filtro server-side, reseñas blindadas,
-- dirección enmascarada y advertencias automáticas por intentos repetidos.
--
-- ESTADO PREVIO (ya implementado — NO se reimplementa):
--   32  → reservation_messages table + RLS
--   42  → contact_violation_logs table + RLS + RLS insert policy
--   phoneFilter.ts → filtro client-side (chat + reviews)
--   ChatScreen.tsx → bloqueo UI + log de violaciones
--
-- LO QUE AGREGA ESTE ARCHIVO:
--   1. Filtro server-side en reservation_messages (defensa en profundidad)
--      Trigger BEFORE INSERT rechaza mensajes con teléfonos/emails/keywords.
--   2. submit_review actualizado — valida el comentario antes de guardar.
--   3. get_reservation_address() — devuelve dirección completa solo si el
--      anticipo está pagado; antes muestra solo ciudad + zona aproximada.
--   4. Auto-advertencia push cuando un usuario acumula ≥3 violaciones en 24h.
--
-- No modifica el flujo de pagos ni de reservas.
-- Ejecutar DESPUÉS de 111_cancellation_protection.sql
-- ════════════════════════════════════════════════════════════════════════════


-- ── 1. Función auxiliar: detectar contacto en texto ──────────────────────────
-- Usada por el trigger de mensajes y por submit_review.
-- Devuelve TRUE si el texto contiene información de contacto prohibida.

CREATE OR REPLACE FUNCTION public.text_has_contact_info(p_text TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
IMMUTABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_stripped TEXT;
BEGIN
  IF p_text IS NULL OR p_text = '' THEN
    RETURN FALSE;
  END IF;

  -- Quitar separadores comunes para detectar dígitos disfrazados
  v_stripped := regexp_replace(p_text, '[\s\-\(\)\+\.]', '', 'g');

  -- 7+ dígitos consecutivos (números de teléfono)
  IF v_stripped ~ '\d{7,}' THEN
    RETURN TRUE;
  END IF;

  -- Patrones de email
  IF p_text ~* '@[a-z0-9]'
    OR p_text ~* '\.(com|net|org|mx|io|app|co|me)\M'
  THEN
    RETURN TRUE;
  END IF;

  -- Keywords de redes sociales y contacto fuera de plataforma
  IF p_text ~* 'll[aá]mam[ei]'
    OR p_text ~* 'wh?[a4]ts[a4]pp?'
    OR p_text ~* 'wa\.me'
    OR p_text ~* 'telegr[a4]m'
    OR p_text ~* 't\.me/'
    OR p_text ~* 'cont[a4]ct[a4]me'
    OR p_text ~* 'busca[nm]e\s+en'
    OR p_text ~* 'inst[a4]gr[a4]m'
    OR p_text ~* 'f[a4]c[e3]b[o0]{2}k'
    OR p_text ~* 'tiktok'
    OR p_text ~* 'twitter|x\.com'
    OR p_text ~* 'ig\s*[:=@]'
    OR p_text ~* 'fb\s*[:=@]'
  THEN
    RETURN TRUE;
  END IF;

  RETURN FALSE;
END;
$$;

GRANT EXECUTE ON FUNCTION public.text_has_contact_info(TEXT) TO authenticated, service_role;


-- ── 2. Trigger: filtro server-side en reservation_messages ───────────────────
-- Rechaza el INSERT si el contenido contiene información de contacto.
-- Complementa el filtro client-side de phoneFilter.ts (defensa en profundidad).

CREATE OR REPLACE FUNCTION public.trg_filter_reservation_message()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF public.text_has_contact_info(NEW.content) THEN
    RAISE EXCEPTION
      'contact_info_blocked: Por seguridad no puedes compartir datos de contacto en el chat.';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_filter_message_content ON public.reservation_messages;
CREATE TRIGGER trg_filter_message_content
  BEFORE INSERT ON public.reservation_messages
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_filter_reservation_message();


-- ── 3. submit_review actualizado: valida comentario ──────────────────────────
-- Misma firma que SQL 93. Bloquea comentarios con info de contacto.

CREATE OR REPLACE FUNCTION public.submit_review(
  p_reservation_id UUID,
  p_rating         SMALLINT,
  p_comment        TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res       RECORD;
  v_review_id UUID;
BEGIN
  -- Validar reserva: debe pertenecer al cliente y estar completada
  SELECT r.id, r.group_id, r.client_id, r.event_date
  INTO v_res
  FROM public.reservations r
  WHERE r.id        = p_reservation_id
    AND r.client_id = auth.uid()
    AND r.status    = 'completed';

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_eligible');
  END IF;

  -- Verificar que no haya reseña previa
  IF EXISTS (SELECT 1 FROM public.reviews WHERE reservation_id = p_reservation_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_reviewed');
  END IF;

  -- Validar calificación
  IF p_rating < 1 OR p_rating > 5 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_rating');
  END IF;

  -- ── NUEVO: Validar que el comentario no contenga info de contacto ─────────
  IF public.text_has_contact_info(p_comment) THEN
    RETURN jsonb_build_object(
      'ok',    false,
      'error', 'contact_info_in_comment'
    );
  END IF;

  INSERT INTO public.reviews (reservation_id, client_id, group_id, rating, comment)
  VALUES (p_reservation_id, auth.uid(), v_res.group_id, p_rating, NULLIF(TRIM(COALESCE(p_comment, '')), ''))
  RETURNING id INTO v_review_id;

  RETURN jsonb_build_object('ok', true, 'review_id', v_review_id);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.submit_review(UUID, SMALLINT, TEXT) TO authenticated;


-- ── 4. get_reservation_address() — dirección enmascarada antes del pago ──────
-- Devuelve la dirección completa SOLO si el cliente ya pagó el anticipo.
-- Antes del pago devuelve solo ciudad + estado + "zona aproximada".
-- Usada por el grupo para ver dónde tocar sin revelar ubicación exacta prematura.

CREATE OR REPLACE FUNCTION public.get_reservation_address(p_reservation_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res RECORD;
  v_is_group_owner BOOLEAN;
  v_paid           BOOLEAN;
BEGIN
  SELECT r.id, r.address, r.payment_status, r.status,
         r.client_id, g.owner_id AS group_owner_id,
         r.group_id
  INTO v_res
  FROM public.reservations r
  JOIN public.groups g ON g.id = r.group_id
  WHERE r.id = p_reservation_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  -- Solo el cliente dueño o el grupo pueden consultarla
  v_is_group_owner := (auth.uid() = v_res.group_owner_id);

  IF auth.uid() != v_res.client_id AND NOT v_is_group_owner THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  -- Determinar si ya pagó el anticipo
  v_paid := v_res.payment_status IN ('deposit_paid', 'fully_paid')
          OR v_res.status IN ('in_progress', 'completed');

  -- Cliente siempre ve su propia dirección completa
  IF auth.uid() = v_res.client_id THEN
    RETURN jsonb_build_object(
      'ok',      true,
      'full',    true,
      'address', COALESCE(v_res.address, '')
    );
  END IF;

  -- Grupo: mostrar completa solo si hay pago
  IF v_paid THEN
    RETURN jsonb_build_object(
      'ok',      true,
      'full',    true,
      'address', COALESCE(v_res.address, '')
    );
  ELSE
    -- Extraer solo la ciudad/estado del address (todo antes de la primera coma o el texto completo si no hay)
    RETURN jsonb_build_object(
      'ok',      true,
      'full',    false,
      'address', SPLIT_PART(COALESCE(v_res.address, 'Dirección no disponible'), ',', 1)
                 || ' — dirección completa disponible al confirmar el anticipo'
    );
  END IF;

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_reservation_address(UUID) TO authenticated;


-- ── 5. Auto-advertencia por intentos repetidos de contacto ───────────────────
-- Trigger AFTER INSERT en contact_violation_logs.
-- Si el usuario acumula ≥3 violaciones en las últimas 24 horas:
--   • Envía una notificación de advertencia.
--   • Anti-spam: no envía más de 1 advertencia por usuario cada 24 horas.

CREATE OR REPLACE FUNCTION public.trg_warn_on_repeated_violations()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count   INT;
  v_already BOOLEAN;
BEGIN
  -- Contar violaciones del usuario en las últimas 24 horas
  SELECT COUNT(*) INTO v_count
  FROM public.contact_violation_logs
  WHERE user_id    = NEW.user_id
    AND created_at >= NOW() - INTERVAL '24 hours';

  -- Umbral: 3+ violaciones
  IF v_count < 3 THEN
    RETURN NEW;
  END IF;

  -- Anti-spam: ¿ya recibió advertencia de este tipo en las últimas 24 horas?
  SELECT EXISTS (
    SELECT 1 FROM public.notifications
    WHERE user_id    = NEW.user_id
      AND data->>'warn_key' = 'contact_violation'
      AND created_at >= NOW() - INTERVAL '24 hours'
  ) INTO v_already;

  IF v_already THEN
    RETURN NEW;
  END IF;

  -- Enviar advertencia
  INSERT INTO public.notifications (user_id, type, title, body, data)
  VALUES (
    NEW.user_id,
    'system',
    '⚠️ Aviso de seguridad',
    'Hemos detectado varios intentos de compartir información de contacto fuera de la plataforma. '
    || 'Las reservas realizadas fuera de la app no están protegidas. '
    || 'Si continúas, tu cuenta podría ser suspendida temporalmente.',
    jsonb_build_object(
      'warn_key', 'contact_violation',
      'screen',   'Home'
    )
  );

  RETURN NEW;

EXCEPTION WHEN OTHERS THEN
  RETURN NEW;  -- fallback silencioso — no bloquear la inserción del log
END;
$$;

DROP TRIGGER IF EXISTS trg_warn_repeated_violations ON public.contact_violation_logs;
CREATE TRIGGER trg_warn_repeated_violations
  AFTER INSERT ON public.contact_violation_logs
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_warn_on_repeated_violations();


SELECT '112_contact_protection: filtro server-side + reseñas blindadas + dirección enmascarada + advertencias automáticas ✅' AS status;
