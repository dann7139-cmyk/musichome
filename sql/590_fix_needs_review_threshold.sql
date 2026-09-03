-- ============================================================
-- sql/590_fix_needs_review_threshold.sql
-- ✅ APLICADO A PRODUCCIÓN 2026-09-01 con autorización explícita del
-- usuario. Corrige un bug REAL en admin_get_event_detail() que llevaba
-- desplegado desde sql/585 (mismo día). Probado en transacción
-- autorevertible junto con sql/589 (7/7 PASS) antes de aplicar.
--
-- BUG (encontrado por prueba sintética 2026-09-01, construyendo sql/589):
--   'needs_review' se activa con CUALQUIER declaración de sonido/luz/
--   escenario/led que no sea "no" — eso incluye 'si_50' (sonido CHICO,
--   ~50 personas), 'simple' (luz sencilla), 'small' (escenario 3×2m).
--   Contradice la intención explícita del usuario (2026-09-01): la
--   alerta debe encenderse SOLO cuando alguien pidió el nivel GRANDE —
--   si es chico, los grupos cotizan solos sin que el admin intervenga.
--
-- CORRECCIÓN — solo cuenta el nivel TOP de cada dimensión (confirmado
-- contra los CHECK constraints reales de `quotes`):
--   needs_sound:    si_200  (o 'si' sin especificar — no se puede asumir chico)
--   needs_lighting: premium
--   needs_stage:    wedding  (única grande, 6×4m — "Grande boda")
--   needs_led:      xl       ("XL boda")
--
-- Confirmado por hash antes de tocarla: admin_get_event_detail actual en
-- producción = md5(prosrc) 'e8e3339a85533c2404b17b9120e219a7' (verificado
-- 2026-09-01). Única función que toca este archivo. Cero cambios a
-- 'providers' ni a ningún otro dato — solo el cálculo de 'sound_summary'.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.admin_get_event_detail(p_event_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_result jsonb; v_sound jsonb;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT jsonb_build_object(
    'needs_review', COALESCE(bool_or(
      q.needs_sound IN ('si_200', 'si') OR
      q.needs_lighting = 'premium' OR
      q.needs_stage = 'wedding' OR
      q.needs_led = 'xl'
    ), false),
    'max_needs_sound', (array_agg(q.needs_sound ORDER BY
      CASE q.needs_sound WHEN 'si_200' THEN 4 WHEN 'si_100' THEN 3 WHEN 'si_50' THEN 2 WHEN 'si' THEN 1 ELSE 0 END DESC NULLS LAST
    ) FILTER (WHERE q.needs_sound IS NOT NULL))[1],
    'requested_by', COALESCE(jsonb_agg(DISTINCT g.name) FILTER (
      WHERE q.needs_sound IN ('si_200', 'si')
         OR q.needs_lighting = 'premium' OR q.needs_stage = 'wedding' OR q.needs_led = 'xl'
    ), '[]'::jsonb)
  ) INTO v_sound
  FROM public.quotes q
  JOIN public.groups g ON g.id = q.group_id
  WHERE q.event_id = p_event_id;

  SELECT jsonb_build_object(
    'ok', true,
    'event', jsonb_build_object('id', e.id, 'event_date', e.event_date, 'address', e.address, 'client_id', e.client_id),
    'sound_summary', COALESCE(v_sound, jsonb_build_object('needs_review', false)),
    'providers', (SELECT COALESCE(jsonb_agg(x3.item ORDER BY x3.created_at), '[]'::jsonb) FROM (
        SELECT r.created_at, jsonb_build_object(
          'reservation_id', r.id, 'group_id', r.group_id, 'group_name', g.name, 'genre', g.genre,
          'status', r.status, 'total_price', r.total_price, 'currency', COALESCE(r.currency_code, 'MXN'),
          'has_own_sound', g.has_sound,
          'quote', (SELECT jsonb_build_object(
              'id', q2.id, 'status', q2.status,
              'needs_sound', q2.needs_sound, 'needs_lighting', q2.needs_lighting,
              'needs_stage', q2.needs_stage, 'needs_led', q2.needs_led
            ) FROM public.quotes q2
            WHERE q2.group_id = r.group_id AND q2.event_id = e.id
            ORDER BY q2.created_at DESC LIMIT 1)
        ) AS item
        FROM public.reservations r JOIN public.groups g ON g.id = r.group_id WHERE r.event_id = e.id
        UNION ALL
        SELECT q3.created_at, jsonb_build_object(
          'reservation_id', 'quote-' || q3.id, 'group_id', q3.group_id, 'group_name', g3.name, 'genre', g3.genre,
          'status', q3.status, 'total_price', q3.total_amount,
          'currency', COALESCE((SELECT c.currency_code FROM public.countries c WHERE c.id = g3.country_id), 'MXN'),
          'has_own_sound', g3.has_sound,
          'quote', jsonb_build_object(
            'id', q3.id, 'status', q3.status,
            'needs_sound', q3.needs_sound, 'needs_lighting', q3.needs_lighting,
            'needs_stage', q3.needs_stage, 'needs_led', q3.needs_led
          )
        ) AS item
        FROM public.quotes q3 JOIN public.groups g3 ON g3.id = q3.group_id
        WHERE q3.event_id = e.id AND q3.status IN ('pending', 'quoted')
      ) x3)
  ) INTO v_result FROM public.events e WHERE e.id = p_event_id;

  IF v_result IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;
  RETURN v_result;
END;
$function$;

COMMIT;

SELECT '590_fix_needs_review_threshold — APLICADO A PRODUCCIÓN 2026-09-01' AS status;
