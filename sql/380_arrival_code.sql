-- ═══════════════════════════════════════════════════════
-- 380 — Código de inicio 4 dígitos en reservations
-- Ejecutar en Supabase SQL Editor
-- ═══════════════════════════════════════════════════════

-- PASO 1: columna
ALTER TABLE reservations
  ADD COLUMN IF NOT EXISTS arrival_code TEXT;

-- PASO 2: función de código único entre reservas activas
CREATE OR REPLACE FUNCTION generate_unique_arrival_code()
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_code    TEXT;
  v_exists  BOOLEAN;
  v_tries   INT := 0;
BEGIN
  LOOP
    -- 4 dígitos: 1000-9999
    v_code := LPAD(FLOOR(RANDOM() * 9000 + 1000)::TEXT, 4, '0');

    SELECT EXISTS (
      SELECT 1 FROM reservations
      WHERE arrival_code = v_code
        AND event_date >= CURRENT_DATE
        AND status NOT IN ('cancelled', 'rejected', 'expired')
    ) INTO v_exists;

    EXIT WHEN NOT v_exists;

    v_tries := v_tries + 1;
    IF v_tries >= 200 THEN EXIT; END IF;  -- 9000 posibles, colisión improbable
  END LOOP;

  RETURN v_code;
END;
$$;

-- PASO 3: función de trigger
CREATE OR REPLACE FUNCTION trg_fn_set_arrival_code()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.arrival_code IS NULL THEN
    NEW.arrival_code := generate_unique_arrival_code();
  END IF;
  RETURN NEW;
END;
$$;

-- PASO 4: trigger BEFORE INSERT
DROP TRIGGER IF EXISTS trg_arrival_code ON reservations;
CREATE TRIGGER trg_arrival_code
  BEFORE INSERT ON reservations
  FOR EACH ROW
  EXECUTE FUNCTION trg_fn_set_arrival_code();

-- PASO 5: backfill reservas pagadas existentes (sin código aún)
DO $$
DECLARE
  rec RECORD;
BEGIN
  FOR rec IN
    SELECT id FROM reservations
    WHERE arrival_code IS NULL
      AND payment_status IN ('paid', 'deposit_paid', 'fully_paid')
    ORDER BY created_at
  LOOP
    UPDATE reservations
    SET arrival_code = generate_unique_arrival_code()
    WHERE id = rec.id;
  END LOOP;
END;
$$;

-- ─── VERIFICACIONES ───────────────────────────────────────
-- V1: columna existe
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name = 'reservations' AND column_name = 'arrival_code';

-- V2: trigger existe
SELECT trigger_name, event_manipulation, action_timing
FROM information_schema.triggers
WHERE event_object_table = 'reservations'
  AND trigger_name = 'trg_arrival_code';

-- V3: función existe
SELECT proname, prosrc IS NOT NULL AS has_body
FROM pg_proc WHERE proname = 'generate_unique_arrival_code';

-- V4: backfill — debe mostrar reservas pagadas con código
SELECT folio, arrival_code, payment_status, event_date
FROM reservations
WHERE payment_status IN ('paid', 'deposit_paid', 'fully_paid')
ORDER BY created_at DESC
LIMIT 10;
