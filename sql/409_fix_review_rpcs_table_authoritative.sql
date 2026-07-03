-- ════════════════════════════════════════════════════════════════════
-- sql/409 — Hacer la TABLA fuente autoritativa en RPCs de calificación
--
-- Problema en sql/73: submit_group_review / submit_client_review usan
-- el flag reviewed_by_client / reviewed_by_group como guard de duplicados.
-- Si los flags quedan en TRUE pero el registro fue eliminado (ej. en pruebas),
-- los RPCs retornan 'already_reviewed' silenciosamente y las calificaciones
-- nunca se guardan.
--
-- Fix: chequear primero la tabla real. Si existe la fila → ya_calificado.
-- El flag pasa a ser cache secundario (se sincroniza pero no es autoritativo).
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. submit_group_review — usa tabla reviews como fuente primaria ──────────
CREATE OR REPLACE FUNCTION public.submit_group_review(
  p_reservation_id UUID,
  p_rating         INTEGER,
  p_comment        TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res       RECORD;
  v_caller_id UUID := auth.uid();
BEGIN
  IF p_rating < 1 OR p_rating > 5 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'rating_out_of_range');
  END IF;

  IF public.contains_profanity(p_comment) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'profanity_detected');
  END IF;

  SELECT * INTO v_res FROM public.reservations WHERE id = p_reservation_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_found');
  END IF;

  IF v_res.client_id <> v_caller_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_client');
  END IF;

  -- Fuente autoritativa: tabla reviews (no el flag, que puede quedar desincronizado)
  IF EXISTS (SELECT 1 FROM public.reviews WHERE reservation_id = p_reservation_id) THEN
    -- Sincronizar flag si estaba desfasado
    UPDATE public.reservations SET reviewed_by_client = TRUE
      WHERE id = p_reservation_id AND NOT reviewed_by_client;
    RETURN jsonb_build_object('ok', false, 'error', 'already_reviewed');
  END IF;

  INSERT INTO public.reviews (reservation_id, client_id, group_id, rating, comment)
  VALUES (p_reservation_id, v_caller_id, v_res.group_id, p_rating, p_comment)
  ON CONFLICT DO NOTHING;

  UPDATE public.reservations SET reviewed_by_client = TRUE WHERE id = p_reservation_id;

  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.submit_group_review(UUID, INTEGER, TEXT) TO authenticated;

-- ── 2. submit_client_review — usa tabla client_reviews como fuente primaria ──
CREATE OR REPLACE FUNCTION public.submit_client_review(
  p_reservation_id UUID,
  p_rating         INTEGER,
  p_comment        TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res       RECORD;
  v_caller_id UUID := auth.uid();
BEGIN
  IF p_rating < 1 OR p_rating > 5 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'rating_out_of_range');
  END IF;

  IF public.contains_profanity(p_comment) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'profanity_detected');
  END IF;

  SELECT * INTO v_res FROM public.reservations WHERE id = p_reservation_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_found');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.groups WHERE id = v_res.group_id AND owner_id = v_caller_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_group_owner');
  END IF;

  -- Fuente autoritativa: tabla client_reviews (no el flag)
  IF EXISTS (
    SELECT 1 FROM public.client_reviews
    WHERE reservation_id = p_reservation_id AND group_id = v_res.group_id
  ) THEN
    UPDATE public.reservations SET reviewed_by_group = TRUE
      WHERE id = p_reservation_id AND NOT reviewed_by_group;
    RETURN jsonb_build_object('ok', false, 'error', 'already_reviewed');
  END IF;

  INSERT INTO public.client_reviews (reservation_id, group_id, client_id, reviewer_id, rating, comment)
  VALUES (p_reservation_id, v_res.group_id, v_res.client_id, v_caller_id, p_rating, p_comment)
  ON CONFLICT DO NOTHING;

  UPDATE public.profiles
  SET
    client_rating        = (SELECT ROUND(AVG(rating::DECIMAL), 2) FROM public.client_reviews WHERE client_id = v_res.client_id),
    client_reviews_count = (SELECT COUNT(*) FROM public.client_reviews WHERE client_id = v_res.client_id)
  WHERE id = v_res.client_id;

  UPDATE public.reservations SET reviewed_by_group = TRUE WHERE id = p_reservation_id;

  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.submit_client_review(UUID, INTEGER, TEXT) TO authenticated;

COMMIT;

-- ════════════════════════════════════════════════════════════════════
-- ACCIÓN REQUERIDA EN ENTORNO DE PRUEBA (ejecutar separado):
-- Si Daniel ya intentó calificar y los flags quedaron en TRUE pero
-- reviews/client_reviews están vacías, resetear los flags manualmente:
--
-- UPDATE public.reservations
-- SET reviewed_by_client = FALSE, reviewed_by_group = FALSE
-- WHERE id = '<UUID-DE-LA-RESERVA-DEMO-001>';
--
-- Después de aplicar este SQL, los RPCs usarán la tabla como fuente
-- autoritativa y las calificaciones se guardarán correctamente.
-- ════════════════════════════════════════════════════════════════════
SELECT '409: submit_group_review + submit_client_review usan tabla como fuente autoritativa ✅' AS status;
