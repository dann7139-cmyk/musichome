-- ════════════════════════════════════════════════════════════════════
-- 73_rating_system.sql
-- Sistema de calificaciones post-evento:
--   · Cliente califica al grupo
--   · Grupo califica al cliente
--   · Grupo califica a cada talento invitado
-- Con filtro de groserías.
-- ════════════════════════════════════════════════════════════════════

-- ── 1. Tabla: grupo califica cliente ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.client_reviews (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reservation_id UUID REFERENCES public.reservations(id),
  group_id       UUID NOT NULL REFERENCES public.groups(id),
  client_id      UUID NOT NULL REFERENCES public.profiles(id),
  reviewer_id    UUID NOT NULL REFERENCES public.profiles(id),
  rating         INTEGER NOT NULL CHECK (rating BETWEEN 1 AND 5),
  comment        TEXT,
  created_at     TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (reservation_id, group_id, client_id)
);

-- ── 2. Tabla: grupo califica talento ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.talent_reviews (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reservation_id UUID REFERENCES public.reservations(id),
  group_id       UUID NOT NULL REFERENCES public.groups(id),
  talent_id      UUID NOT NULL REFERENCES public.profiles(id),
  reviewer_id    UUID NOT NULL REFERENCES public.profiles(id),
  rating         INTEGER NOT NULL CHECK (rating BETWEEN 1 AND 5),
  comment        TEXT,
  created_at     TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (reservation_id, group_id, talent_id)
);

-- ── 3. Columnas de control en reservations ────────────────────────────────────
ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS reviewed_by_client BOOLEAN DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS reviewed_by_group  BOOLEAN DEFAULT FALSE;

-- ── 4. Columnas de calificación promedio en profiles ─────────────────────────
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS talent_rating      DECIMAL(3,2) DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS talent_reviews_count INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS client_rating      DECIMAL(3,2) DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS client_reviews_count INTEGER DEFAULT 0;

-- ── 5. Función de filtro de groserías ────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.contains_profanity(p_text TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public
AS $$
DECLARE
  v_clean TEXT;
  v_words TEXT[] := ARRAY[
    'puta','puto','chinga','chingada','chingado','pendejo','pendeja',
    'cabron','cabrona','culero','culera','mamón','mamona','mamar',
    'joder','coño','polla','verga','vergota','pinche','hijoputa',
    'hijo de puta','mierda','culo','gilipollas','idiota','imbecil',
    'estupido','estupida','perra','perro','bastardo','bastarda',
    'puta madre','chinguen','chinguen','wey','buey','bitch',
    'fuck','shit','asshole','damn','crap','idiot','moron',
    'cabrón','mamón','güey','chíngense','méndigo','méndiga'
  ];
  v_word TEXT;
BEGIN
  IF p_text IS NULL OR trim(p_text) = '' THEN
    RETURN FALSE;
  END IF;
  v_clean := lower(unaccent(p_text));
  FOREACH v_word IN ARRAY v_words LOOP
    IF v_clean ~ ('\m' || lower(v_word) || '\M') OR v_clean LIKE '%' || lower(v_word) || '%' THEN
      RETURN TRUE;
    END IF;
  END LOOP;
  RETURN FALSE;
END;
$$;

-- Necesita extensión unaccent (casi siempre disponible en Supabase)
CREATE EXTENSION IF NOT EXISTS unaccent;

-- ── 6. RPC: cliente califica al grupo ────────────────────────────────────────
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
  -- Validar rango
  IF p_rating < 1 OR p_rating > 5 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'rating_out_of_range');
  END IF;

  -- Validar groserías
  IF public.contains_profanity(p_comment) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'profanity_detected');
  END IF;

  -- Cargar reserva
  SELECT * INTO v_res FROM public.reservations WHERE id = p_reservation_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_found');
  END IF;

  -- Solo el cliente puede calificar al grupo
  IF v_res.client_id <> v_caller_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_client');
  END IF;

  -- Ya calificó
  IF v_res.reviewed_by_client THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_reviewed');
  END IF;

  -- Insertar review
  INSERT INTO public.reviews (reservation_id, client_id, group_id, rating, comment)
  VALUES (p_reservation_id, v_caller_id, v_res.group_id, p_rating, p_comment)
  ON CONFLICT DO NOTHING;

  -- Marcar reserva como calificada por cliente
  UPDATE public.reservations SET reviewed_by_client = TRUE WHERE id = p_reservation_id;

  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.submit_group_review(UUID, INTEGER, TEXT) TO authenticated;

-- ── 7. RPC: grupo califica al cliente ────────────────────────────────────────
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

  -- Solo el dueño del grupo puede calificar
  IF NOT EXISTS (SELECT 1 FROM public.groups WHERE id = v_res.group_id AND owner_id = v_caller_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_group_owner');
  END IF;

  IF v_res.reviewed_by_group THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_reviewed');
  END IF;

  INSERT INTO public.client_reviews (reservation_id, group_id, client_id, reviewer_id, rating, comment)
  VALUES (p_reservation_id, v_res.group_id, v_res.client_id, v_caller_id, p_rating, p_comment)
  ON CONFLICT DO NOTHING;

  -- Actualizar promedio del cliente
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

-- ── 8. RPC: grupo califica a un talento ──────────────────────────────────────
CREATE OR REPLACE FUNCTION public.submit_talent_review(
  p_reservation_id UUID,
  p_talent_id      UUID,
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

  INSERT INTO public.talent_reviews (reservation_id, group_id, talent_id, reviewer_id, rating, comment)
  VALUES (p_reservation_id, v_res.group_id, p_talent_id, v_caller_id, p_rating, p_comment)
  ON CONFLICT DO NOTHING;

  -- Actualizar promedio del talento
  UPDATE public.profiles
  SET
    talent_rating        = (SELECT ROUND(AVG(rating::DECIMAL), 2) FROM public.talent_reviews WHERE talent_id = p_talent_id),
    talent_reviews_count = (SELECT COUNT(*) FROM public.talent_reviews WHERE talent_id = p_talent_id)
  WHERE id = p_talent_id;

  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.submit_talent_review(UUID, UUID, INTEGER, TEXT) TO authenticated;

-- ── 9. RLS ───────────────────────────────────────────────────────────────────
ALTER TABLE public.client_reviews ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "client_reviews_select" ON public.client_reviews;
CREATE POLICY "client_reviews_select" ON public.client_reviews FOR SELECT USING (true);

ALTER TABLE public.talent_reviews ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "talent_reviews_select" ON public.talent_reviews;
CREATE POLICY "talent_reviews_select" ON public.talent_reviews FOR SELECT USING (true);

SELECT '73_rating_system: client_reviews + talent_reviews + RPCs ✅' AS status;
