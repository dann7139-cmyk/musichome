# Guion de concurrencia F2.2 — v4 (probe-gated: verificación server-side del lock)

**Estado: EN REVISIÓN — no ejecutar hasta aprobación.**
**Entorno: EXCLUSIVAMENTE Supabase Branch/staging. PROHIBIDO en producción.**
La RPC, checkout y webhooks NO se modifican.

## Hallazgos que llevaron a v4

- v2: el SQL Editor encola pestañas en serie → jamás hubo dos sesiones.
- v3 (diagnóstico D1-D3): clave/hash correctos (D1: mismo_grupo=t, mismo_hash=t),
  el batch del editor SÍ sostiene el advisory lock entre sentencias (D2=1),
  las conexiones rotan entre Runs (D3: pids 8317→8341). Conclusión del fallo
  de A ("confirmed" en 806 ms): en el instante del disparo REST el lock no
  estaba retenido — el guion dependía de timing humano/UI sin verificación.
- **v4 elimina el timing humano:** un probe server-side (`test_lock_probe`)
  confirma que el lock está retenido ANTES de disparar los pagos, y el
  retenedor puede correr también por REST (`test_hold_group_lock`) con
  timestamps del servidor como evidencia de la ventana de contención.

## Helpers SOLO-STAGING (no son migración; mueren con la rama)

Guardadas por la sentinela, service_role-only, jamás entran al sql/ del repo.

```sql
-- PASO 2.5 — helpers de prueba (SQL Editor de la RAMA, tras el setup)
CREATE OR REPLACE FUNCTION public.test_hold_group_lock(p_seconds INT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_key INT; v_group UUID; v_t0 TIMESTAMPTZ;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM payment_config WHERE key='environment' AND value='staging') THEN
    RAISE EXCEPTION 'Solo staging';
  END IF;
  SELECT id INTO v_group FROM groups
  WHERE name = '__TEST_2TABS_' || (SELECT value FROM payment_config WHERE key='test_run_id');
  IF v_group IS NULL THEN RAISE EXCEPTION 'grupo de prueba no encontrado'; END IF;
  v_key := hashtext(v_group::text);          -- MISMA clave que la RPC
  v_t0  := clock_timestamp();
  PERFORM pg_advisory_xact_lock(v_key);
  PERFORM pg_sleep(LEAST(GREATEST(p_seconds, 1), 25));
  RETURN jsonb_build_object('key', v_key, 'locked_at', v_t0,
                            'released_at', clock_timestamp());
END $$;
REVOKE ALL ON FUNCTION public.test_hold_group_lock(INT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.test_hold_group_lock(INT) TO service_role;

CREATE OR REPLACE FUNCTION public.test_lock_probe()
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_key INT; v_group UUID; v_free BOOLEAN;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM payment_config WHERE key='environment' AND value='staging') THEN
    RAISE EXCEPTION 'Solo staging';
  END IF;
  SELECT id INTO v_group FROM groups
  WHERE name = '__TEST_2TABS_' || (SELECT value FROM payment_config WHERE key='test_run_id');
  IF v_group IS NULL THEN RAISE EXCEPTION 'grupo de prueba no encontrado'; END IF;
  v_key  := hashtext(v_group::text);
  v_free := pg_try_advisory_xact_lock(v_key);  -- si lo consigue, se libera al terminar esta llamada
  RETURN jsonb_build_object('key', v_key, 'held', NOT v_free);
END $$;
REVOKE ALL ON FUNCTION public.test_lock_probe() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.test_lock_probe() TO service_role;

SELECT 'helpers de staging instaladas ✅' AS status;
```

## Orden de ejecución v4

1. Crear la Branch. 2. Confirmar 514/516/518/519. 3. Usuario `test-2tabs@daricefy.test`
en Auth. 4. Sentinela. 5. Verificar visualmente el ref de la rama (dashboard y `$U`).
6. **CLEANUP del run anterior** (m1 quedó confirmed en el intento v3). 7. Preflight.
8. Setup. **8.5. Helpers (PASO 2.5).** 9. PS-0. **9.5. A-0 calibración.** 10. A.
11. B. 12. C. 13. Cleanup (incluye DROP de helpers). 14. Ceros. 15. Eliminar rama.

Preflight, setup y sentinela: idénticos a v3 (secciones más abajo, sin cambios).

## PS-0 v4 — preparar PowerShell (una ventana, pegar completo)

```powershell
$U = "https://TU-REF-DE-RAMA.supabase.co"    # ⚠️ ref de la RAMA
$K = "SERVICE_ROLE_KEY_DE_LA_RAMA"
$H = @{ apikey = $K; Authorization = "Bearer $K"; "Content-Type" = "application/json" }

$run  = (Invoke-RestMethod -Uri "$U/rest/v1/payment_config?key=eq.test_run_id&select=value" -Headers $H)[0].value
$addr = [uri]::EscapeDataString("Av. Prueba $run")
$r1 = (Invoke-RestMethod -Uri "$U/rest/v1/reservations?address=eq.$addr&event_date=eq.2031-01-01&select=id" -Headers $H)[0].id
$r2 = (Invoke-RestMethod -Uri "$U/rest/v1/reservations?address=eq.$addr&event_date=eq.2031-01-02&select=id" -Headers $H)[0].id
"run=$run"; "r1=$r1"; "r2=$r2"

function New-PayBody($ord, $ch, $res) {
  @{ p_provider="stripe"; p_provider_order_id="${run}_$ord"; p_provider_payment_id="${run}_$ch";
     p_reservation_id=$res; p_amount_minor=120000; p_currency="MXN"; p_method="card";
     p_fee_minor=$null; p_fee_source=$null; p_legacy_expected=$null } | ConvertTo-Json
}
$bodyM1 = New-PayBody "ord_m1" "ch_m1" $r1
$bodyM2 = New-PayBody "ord_m2" "ch_m2" $r2

$rpcJob = {
  param($Url, $Key, $Body, $Tag)
  $H2 = @{ apikey = $Key; Authorization = "Bearer $Key"; "Content-Type" = "application/json" }
  $t0 = Get-Date
  try   { $r = Invoke-RestMethod -Method Post -Uri "$Url/rest/v1/rpc/confirm_reservation_payment_v2" -Headers $H2 -Body $Body }
  catch { $r = @{ http_error = $_.Exception.Message } }
  $ms = [int]((Get-Date) - $t0).TotalMilliseconds
  "[$Tag] $ms ms → " + ($r | ConvertTo-Json -Compress)
}

$holdJob = {
  param($Url, $Key, $Seconds)
  $H2 = @{ apikey = $Key; Authorization = "Bearer $Key"; "Content-Type" = "application/json" }
  $t0 = Get-Date
  try   { $r = Invoke-RestMethod -Method Post -Uri "$Url/rest/v1/rpc/test_hold_group_lock" -Headers $H2 -Body (@{ p_seconds = $Seconds } | ConvertTo-Json) }
  catch { $r = @{ http_error = $_.Exception.Message } }
  $ms = [int]((Get-Date) - $t0).TotalMilliseconds
  "[HOLD] $ms ms → " + ($r | ConvertTo-Json -Compress)
}

function Wait-Lock {
  for ($i = 0; $i -lt 40; $i++) {
    try { $p = Invoke-RestMethod -Method Post -Uri "$U/rest/v1/rpc/test_lock_probe" -Headers $H -Body "{}" }
    catch { $p = @{ held = $false } }
    if ($p.held) { "PROBE: lock retenido (tras $($i*250) ms de espera)"; return $true }
    Start-Sleep -Milliseconds 250
  }
  "PROBE TIMEOUT: el lock nunca apareció (10 s)"; return $false
}
"PS-0 listo"
```

## A-0 — Calibración del retenedor REST (una vez)

PostgREST aplica el statement_timeout del rol; hay que medir cuánto sostiene:

```powershell
$hold = Start-Job -ScriptBlock $holdJob -ArgumentList $U,$K,10
Receive-Job -Job $hold -Wait -AutoRemoveJob
```

- **~10000 ms con JSON (`locked_at`/`released_at`)** → el retenedor aguanta ≥10s → usar 15s en A.
- **http_error a los ~N ms** → el statement_timeout del rol corta en N; mientras N > 6000 el guion funciona (el probe dispara en <1s y el pago espera 5s). Si N ≤ 6000, repórtalo y paramos.

## GUION A — Lock timeout real (probe-gated)

```powershell
$hold = Start-Job -ScriptBlock $holdJob -ArgumentList $U,$K,15
if (Wait-Lock) { & $rpcJob $U $K $bodyM1 "A-m1" }
Receive-Job -Job $hold -Wait -AutoRemoveJob
```

**Esperado:** `PROBE: lock retenido...` → `[A-m1] ~5000 ms → {"result":"temporary_lock_timeout"}` → `[HOLD]` con `locked_at`/`released_at` que ENVUELVEN la ventana del pago (evidencia del servidor). Si el probe nunca ve el lock → pegar el `[HOLD]` (dirá por qué).

**Verificación A (SQL Editor — esperado: 0 · created · pending_payment/unpaid · 0):**

```sql
SELECT
  (SELECT COUNT(*) FROM payment_receipts WHERE provider_payment_id =
    (SELECT value || '_ch_m1' FROM payment_config WHERE key='test_run_id'))          AS receipts_0,
  (SELECT status FROM payment_attempts WHERE client_key =
    (SELECT value || '_k_m1' FROM payment_config WHERE key='test_run_id'))           AS attempt_created,
  (SELECT r.status || '/' || r.payment_status FROM reservations r
    WHERE r.address = 'Av. Prueba ' || (SELECT value FROM payment_config WHERE key='test_run_id')
      AND r.event_date = DATE '2031-01-01')                                          AS reserva,
  (SELECT COUNT(*) FROM group_wallets gw JOIN groups g ON g.id = gw.group_id
    WHERE g.name = '__TEST_2TABS_' || (SELECT value FROM payment_config WHERE key='test_run_id')
      AND gw.pending_balance <> 0)                                                   AS wallet_0;
```

**Paro A:** `confirmed` con elapsed <4000 ms A PESAR de probe=retenido → eso sí
implicaría al mecanismo → detener y pegar todo · escrituras tras timeout → grave.

## GUION B — Mismo pago simultáneo (probe-gated)

```powershell
$hold = Start-Job -ScriptBlock $holdJob -ArgumentList $U,$K,4
if (Wait-Lock) {
  $j1 = Start-Job -ScriptBlock $rpcJob -ArgumentList $U,$K,$bodyM1,"B-1"
  $j2 = Start-Job -ScriptBlock $rpcJob -ArgumentList $U,$K,$bodyM1,"B-2"
  Receive-Job -Job $j1,$j2 -Wait -AutoRemoveJob
}
Receive-Job -Job $hold -Wait -AutoRemoveJob
```

**Esperado:** ambos esperan (elapsed alto = contención real) y al liberarse:
**uno `confirmed`, el otro `already_processed`** (cualquier orden).

**Verificación B (SQL Editor — esperado: 1 · confirmed/credited · 1 · 1000):**

```sql
SELECT
  (SELECT COUNT(*) FROM payment_receipts WHERE provider_payment_id =
    (SELECT value || '_ch_m1' FROM payment_config WHERE key='test_run_id'))          AS receipts_1,
  (SELECT result || '/' || money_state FROM payment_receipts WHERE provider_payment_id =
    (SELECT value || '_ch_m1' FROM payment_config WHERE key='test_run_id'))          AS receipt_estado,
  (SELECT COUNT(*) FROM wallet_transactions wt
     JOIN reservations r ON r.id = wt.reservation_id
    WHERE r.address = 'Av. Prueba ' || (SELECT value FROM payment_config WHERE key='test_run_id')
      AND wt.type = 'credit_pending')                                                AS creditos_1,
  (SELECT gw.pending_balance FROM group_wallets gw JOIN groups g ON g.id = gw.group_id
    WHERE g.name = '__TEST_2TABS_' || (SELECT value FROM payment_config WHERE key='test_run_id')) AS bal_1000;
```

**Paro B:** 2 receipts, 2 créditos, balance ≠ 1000, o ambos `confirmed` → fallo crítico del UNIQUE.

## GUION C — Dos pagos del mismo grupo (probe-gated, sin deadlock)

```powershell
$hold = Start-Job -ScriptBlock $holdJob -ArgumentList $U,$K,4
if (Wait-Lock) {
  $j1 = Start-Job -ScriptBlock $rpcJob -ArgumentList $U,$K,$bodyM1,"C-m1"
  $j2 = Start-Job -ScriptBlock $rpcJob -ArgumentList $U,$K,$bodyM2,"C-m2"
  Receive-Job -Job $j1,$j2 -Wait -AutoRemoveJob
}
Receive-Job -Job $hold -Wait -AutoRemoveJob
```

**Esperado:** `C-m1` → `already_processed` (confirmado en B), `C-m2` → `confirmed`. **Sin `40P01`.**

**Verificación C (SQL Editor — esperado: 1 · 2 · 2000 · confirmed/paid · confirmed/paid):**

```sql
SELECT
  (SELECT COUNT(*) FROM payment_receipts WHERE provider_payment_id =
    (SELECT value || '_ch_m2' FROM payment_config WHERE key='test_run_id'))          AS receipt_m2_1,
  (SELECT COUNT(*) FROM wallet_transactions wt
     JOIN reservations r ON r.id = wt.reservation_id
    WHERE r.address = 'Av. Prueba ' || (SELECT value FROM payment_config WHERE key='test_run_id')
      AND wt.type = 'credit_pending')                                                AS creditos_2,
  (SELECT gw.pending_balance FROM group_wallets gw JOIN groups g ON g.id = gw.group_id
    WHERE g.name = '__TEST_2TABS_' || (SELECT value FROM payment_config WHERE key='test_run_id')) AS bal_2000,
  (SELECT string_agg(r.status || '/' || r.payment_status, ' · ' ORDER BY r.event_date)
     FROM reservations r
    WHERE r.address = 'Av. Prueba ' || (SELECT value FROM payment_config WHERE key='test_run_id')) AS reservas;
```

**Paro C:** `40P01` → detener TODO · balance ≠ 2000 → detener.

---

## Secciones sin cambios respecto a v3 (usar tal cual)

### Sentinela (solo rama)

```sql
INSERT INTO payment_config (key, value, description)
VALUES ('environment', 'staging', 'Marca de entorno de pruebas — nunca debe existir en producción')
ON CONFLICT (key) DO NOTHING;
```

### Preflight

```sql
SELECT
  (SELECT COUNT(*) FROM payment_config WHERE key='environment' AND value='staging') AS entorno_staging_1,
  (SELECT COUNT(*) FROM payment_config WHERE key='test_run_id')                     AS run_previo_0,
  (SELECT COUNT(*) FROM groups WHERE name ~ '^__TEST_2TABS')                        AS grupos_residuales_0,
  (SELECT COUNT(*) FROM pg_tables WHERE tablename IN
    ('payment_attempts','payment_receipts','refund_intents','payment_config'))      AS gate_tablas_4,
  (SELECT COUNT(*) FROM pg_proc WHERE proname IN
    ('can_schedule','confirm_reservation_payment_v2'))                              AS gate_funcs_2,
  (SELECT COUNT(*) FROM profiles WHERE email = 'test-2tabs@daricefy.test')          AS perfil_test_1,
  (SELECT id::text FROM profiles WHERE email = 'test-2tabs@daricefy.test')          AS perfil_test_id;
```

### Setup

```sql
BEGIN;
DO $$
DECLARE
  v_run  TEXT;
  v_user UUID;
  v_g    UUID;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM payment_config WHERE key='environment' AND value='staging') THEN
    RAISE EXCEPTION 'ABORTADO: sin marca de staging — esto parece PRODUCCIÓN. No se escribió nada.';
  END IF;
  IF EXISTS (SELECT 1 FROM payment_config WHERE key='test_run_id') THEN
    RAISE EXCEPTION 'ABORTADO: hay un test_run_id previo sin limpiar. Corre el cleanup primero.';
  END IF;

  SELECT id INTO v_user FROM profiles WHERE email = 'test-2tabs@daricefy.test';
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'ABORTADO: no existe el perfil dedicado test-2tabs@daricefy.test. Créalo en Auth de la rama. NO se elige otro perfil.';
  END IF;

  v_run := 'T2B_' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISS');
  INSERT INTO payment_config (key, value, description)
  VALUES ('test_run_id', v_run, 'Corrida activa del guion de concurrencia F2.2');

  INSERT INTO groups (name, owner_id, state, country, is_active)
  VALUES ('__TEST_2TABS_' || v_run, v_user, 'Jalisco', 'México', false)
  RETURNING id INTO v_g;

  INSERT INTO reservations (group_id, client_id, event_date, event_time, hours_count,
                            status, payment_status, total_price, base_price, address)
  SELECT v_g, v_user, d.event_date, TIME '18:00', 3,
         'pending_payment', 'unpaid', 1200, 1000, 'Av. Prueba ' || v_run
  FROM (VALUES (DATE '2031-01-01'), (DATE '2031-01-02')) AS d(event_date);

  INSERT INTO payment_attempts (provider, client_key, provider_order_id, reservation_id,
                                expected_amount_minor, currency, method, status)
  SELECT 'stripe',
         v_run || CASE r.event_date WHEN DATE '2031-01-01' THEN '_k_m1' ELSE '_k_m2' END,
         v_run || CASE r.event_date WHEN DATE '2031-01-01' THEN '_ord_m1' ELSE '_ord_m2' END,
         r.id, 120000, 'MXN', 'card', 'created'
  FROM reservations r WHERE r.group_id = v_g;

  RAISE NOTICE 'SETUP OK — test_run_id = %', v_run;
END $$;
COMMIT;

-- Verificación del setup (esperado: run · 1 · 2 · 2)
SELECT
  (SELECT value FROM payment_config WHERE key='test_run_id')                          AS run,
  (SELECT COUNT(*) FROM groups
    WHERE name = '__TEST_2TABS_' || (SELECT value FROM payment_config WHERE key='test_run_id')) AS grupo_1,
  (SELECT COUNT(*) FROM reservations
    WHERE address = 'Av. Prueba ' || (SELECT value FROM payment_config WHERE key='test_run_id')) AS reservas_2,
  (SELECT COUNT(*) FROM payment_attempts
    WHERE client_key LIKE (SELECT value FROM payment_config WHERE key='test_run_id') || '%')     AS attempts_2;
```

### Cleanup (v4: añade el DROP de las helpers al final)

```sql
BEGIN;
DO $$
DECLARE
  v_run          TEXT;
  v_group        UUID;
  v_res          UUID[];
  v_res_txt      TEXT[];
  v_admin        UUID;
  v_admin_credit NUMERIC := 0;
  v_mal          INT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM payment_config WHERE key='environment' AND value='staging') THEN
    RAISE EXCEPTION 'ABORTADO: sin marca de staging — esto parece PRODUCCIÓN.';
  END IF;
  SELECT value INTO v_run FROM payment_config WHERE key='test_run_id';
  IF v_run IS NULL THEN
    RAISE NOTICE 'Nada que limpiar: no hay test_run_id activo';
    RETURN;
  END IF;

  SELECT id INTO v_group FROM groups WHERE name = '__TEST_2TABS_' || v_run;
  v_res     := ARRAY(SELECT id       FROM reservations WHERE group_id = v_group);
  v_res_txt := ARRAY(SELECT id::text FROM reservations WHERE group_id = v_group);

  SELECT COUNT(*) INTO v_mal FROM reservations
  WHERE id = ANY(v_res) AND address <> 'Av. Prueba ' || v_run;
  IF v_mal > 0 THEN
    RAISE EXCEPTION 'ABORTADO: % reservas del grupo NO llevan la etiqueta del run %', v_mal, v_run;
  END IF;

  RAISE NOTICE 'A borrar [run %]: receipts=%, refunds=%, attempts=%, ledger=%, reservas=%, grupo=%',
    v_run,
    (SELECT COUNT(*) FROM payment_receipts  WHERE provider_payment_id LIKE v_run || '%' OR reservation_id = ANY(v_res)),
    (SELECT COUNT(*) FROM refund_intents    WHERE provider_payment_id LIKE v_run || '%' OR reservation_id = ANY(v_res)),
    (SELECT COUNT(*) FROM payment_attempts  WHERE client_key LIKE v_run || '%'),
    (SELECT COUNT(*) FROM wallet_transactions WHERE reservation_id = ANY(v_res)),
    COALESCE(array_length(v_res,1),0),
    (v_group IS NOT NULL)::TEXT;

  SELECT user_id, COALESCE(SUM(amount),0) INTO v_admin, v_admin_credit
  FROM wallet_transactions
  WHERE reservation_id = ANY(v_res) AND user_id IS NOT NULL AND type='platform_income'
  GROUP BY user_id;
  IF v_admin IS NOT NULL AND v_admin_credit > 0 THEN
    UPDATE wallets SET
      available_balance = available_balance - v_admin_credit,
      total_earned      = total_earned      - v_admin_credit,
      updated_at        = NOW()
    WHERE user_id = v_admin;
    RAISE NOTICE 'Revertido crédito admin-clon: %', v_admin_credit;
  END IF;

  DELETE FROM refund_intents       WHERE provider_payment_id LIKE v_run || '%' OR reservation_id = ANY(v_res);
  DELETE FROM payment_receipts     WHERE provider_payment_id LIKE v_run || '%' OR reservation_id = ANY(v_res);
  DELETE FROM payment_attempts     WHERE client_key LIKE v_run || '%';
  DELETE FROM wallet_transactions  WHERE reservation_id = ANY(v_res);
  DELETE FROM group_wallets        WHERE group_id = v_group;
  DELETE FROM notifications        WHERE (data->>'reservation_id') = ANY(v_res_txt);
  DELETE FROM financial_audit_logs WHERE entity_id = ANY(v_res);
  DELETE FROM reservations         WHERE id = ANY(v_res);
  DELETE FROM groups               WHERE id = v_group;
  DELETE FROM payment_config       WHERE key = 'test_run_id';

  RAISE NOTICE 'CLEANUP OK — run % eliminado', v_run;
END $$;

DROP FUNCTION IF EXISTS public.test_hold_group_lock(INT);
DROP FUNCTION IF EXISTS public.test_lock_probe();
COMMIT;
```

### Verificación final de ceros

```sql
SELECT
  (SELECT COUNT(*) FROM payment_config WHERE key='test_run_id')                    AS run_0,
  (SELECT COUNT(*) FROM groups        WHERE name ~ '^__TEST_2TABS')                AS grupos_0,
  (SELECT COUNT(*) FROM reservations  WHERE address LIKE 'Av. Prueba T2B_%')       AS reservas_0,
  (SELECT COUNT(*) FROM payment_attempts WHERE client_key LIKE 'T2B_%')            AS attempts_0,
  (SELECT COUNT(*) FROM payment_receipts WHERE provider_payment_id LIKE 'T2B_%')   AS receipts_0,
  (SELECT COUNT(*) FROM refund_intents  WHERE provider_payment_id LIKE 'T2B_%')    AS refunds_0,
  (SELECT COUNT(*) FROM pg_proc WHERE proname IN ('test_hold_group_lock','test_lock_probe')) AS helpers_0;
```

## Criterios de paro generales

1. A-0 con corte ≤6000 ms → parar y reportar (el rol no sostiene la ventana).
2. Probe nunca ve el lock → pegar el `[HOLD]` (dice por qué) — no disparar pagos.
3. `confirmed` rápido A PESAR de probe=retenido → única evidencia que implicaría
   al mecanismo de la RPC → detener y pegar todo.
4. `40P01` → detener todo.
5. Cualquier otra desviación → detener, pegar, NO limpiar.
