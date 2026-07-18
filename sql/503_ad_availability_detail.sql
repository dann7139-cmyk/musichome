-- ============================================================
-- sql/503_ad_availability_detail.sql
-- 📍 "Dónde aparecerá tu anuncio" (2026-07-17)
--
--  check_ad_availability v2 — misma firma, ahora SIEMPRE devuelve el
--  detalle para que la app muestre ANTES de pagar:
--   · por estado: usados / límite / libres (banner y anuncio de perfil)
--   · bolsa nacional/internacional: usados / límite
--
--  La regla no cambia: nacional/internacional tiene sus lugares
--  APARTE (nunca choca con los estados ni se bloquea por un estado
--  lleno); un estado lleno solo frena compras dirigidas a ESE estado.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.check_ad_availability(
  p_type   TEXT,
  p_states TEXT[] DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_state_limit  INT := ad_state_limit(p_type);
  v_global_limit INT := ad_global_limit(p_type);
  v_global_cnt   INT;
  v_full         TEXT[] := '{}';
  v_detail       JSONB  := '[]'::jsonb;
  v_st           TEXT;
  v_st_norm      TEXT;
  v_cnt          INT;
BEGIN
  IF p_type NOT IN ('banner_home', 'sponsored_group', 'profile_ad') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_type');
  END IF;

  -- Bolsa nacional/internacional (anuncios sin estado: visibles en todos)
  SELECT COUNT(*) INTO v_global_cnt
  FROM advertisements a
  WHERE a.type = p_type
    AND a.status IN ('active', 'pending_review')
    AND (a.ends_at IS NULL OR a.ends_at > NOW())
    AND a.target_states IS NULL
    AND a.target_state IS NULL;

  IF p_states IS NULL OR array_length(p_states, 1) IS NULL THEN
    -- El anuncio nuevo es nacional/internacional
    RETURN jsonb_build_object(
      'ok',    v_global_cnt < v_global_limit,
      'error', CASE WHEN v_global_cnt >= v_global_limit THEN 'no_capacity' ELSE NULL END,
      'scope', 'global',
      'used',  v_global_cnt,
      'limit', v_global_limit,
      'free',  GREATEST(v_global_limit - v_global_cnt, 0)
    );
  END IF;

  -- Estados concretos: detalle de cada uno
  FOREACH v_st IN ARRAY p_states LOOP
    v_st_norm := normalize_state_name(v_st);
    SELECT COUNT(*) INTO v_cnt
    FROM advertisements a
    WHERE a.type = p_type
      AND a.status IN ('active', 'pending_review')
      AND (a.ends_at IS NULL OR a.ends_at > NOW())
      AND (
        (a.target_states IS NULL AND a.target_state IS NULL)      -- nacional/int'l
        OR (a.target_states IS NOT NULL AND v_st_norm = ANY(a.target_states))
        OR (a.target_states IS NULL AND a.target_state = v_st_norm)
      );
    v_detail := v_detail || jsonb_build_object(
      'state', v_st,
      'used',  v_cnt,
      'limit', v_state_limit,
      'free',  GREATEST(v_state_limit - v_cnt, 0)
    );
    IF v_cnt >= v_state_limit THEN
      v_full := array_append(v_full, v_st);
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'ok',          array_length(v_full, 1) IS NULL,
    'error',       CASE WHEN array_length(v_full, 1) IS NOT NULL THEN 'no_capacity' ELSE NULL END,
    'scope',       'state',
    'full_states', to_jsonb(v_full),
    'limit',       v_state_limit,
    'states_detail', v_detail
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.check_ad_availability(TEXT, TEXT[]) TO authenticated;

COMMIT;

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
SELECT prosrc LIKE '%states_detail%' AS con_detalle
FROM pg_proc WHERE proname = 'check_ad_availability';
-- Esperado: true

SELECT '503_ad_availability_detail.sql ejecutado ✅' AS status;
