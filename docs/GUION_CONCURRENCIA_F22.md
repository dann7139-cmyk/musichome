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
8. Setup. **8.5. Helpers (PASO 2.5).** 9. PS-0. **9.5. A-0 calibración — guardar
locked_at, released_at, duración real y cualquier timeout de PostgREST.**
10. A + verificación. **GATE: SOLO si A da exactamente lo esperado se ejecuta B.**
11. B + verificación. 12. C + verificación. 13. Cleanup (incluye DROP de helpers).
14. Ceros. 15. Eliminar rama.
Si una prueba falla: NO correr el cleanup (preserva evidencia), pero SÍ retirar
las helpers con el bloque independiente del final — no toca datos.

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
  # v4.2: curl.exe (NO el alias 'curl' de PowerShell) — jamás retransmite un
  # POST y con Connection: close no reutiliza conexiones keep-alive muertas.
  $t0 = Get-Date
  $out = & curl.exe -sS -X POST "$Url/rest/v1/rpc/confirm_reservation_payment_v2" `
    -H "apikey: $Key" -H "Authorization: Bearer $Key" -H "Content-Type: application/json" `
    -H "Connection: close" --max-time 30 -w " [HTTP %{http_code}]" -d $Body 2>&1
  $ms = [int]((Get-Date) - $t0).TotalMilliseconds
  "[$Tag] $ms ms → $out"
}

function Wait-Lock {
  for ($i = 0; $i -lt 60; $i++) {
    try { $p = Invoke-RestMethod -Method Post -Uri "$U/rest/v1/rpc/test_lock_probe" -Headers $H -Body "{}" }
    catch { $p = @{ held = $false } }
    if ($p.held) { "PROBE: lock retenido (tras $($i*250) ms de sondeo)"; return $true }
    Start-Sleep -Milliseconds 250
  }
  "PROBE TIMEOUT: el lock nunca apareció (15 s) — ¿diste Run al bloque SQL?"; return $false
}
"PS-0 listo"
```

## A-0 — Calibración del retenedor REST — EJECUTADA Y CONCLUIDA

**Resultado real (2026-07-19):** `[HOLD] 8817 ms → http_error 500` sin JSON.
**Diagnóstico:** `statement_timeout = 8s` del rol de API de PostgREST (default
de Supabase) mató la llamada de 10s. NO es un fallo del mecanismo. Dato útil
de producción: los webhooks viven bajo el mismo tope de 8s, y una llamada de
pago que espere sus 5s de lock_timeout termina en ~5.5s < 8s ✓.

Confirmación en SQL (editor de la rama):

```sql
SELECT rolname, rolconfig FROM pg_roles
WHERE rolname IN ('service_role','authenticator','anon','authenticated','postgres');
-- Esperado: statement_timeout=8s en los roles de API; postgres sin ese tope
```

**Decisión:** el retenedor REST queda DESCARTADO para los guiones (máx ~8s,
margen insuficiente). El retenedor vuelve al SQL Editor (rol postgres, sin el
tope de 8s; D2 probó que el batch sostiene el lock). El timing humano deja de
importar porque el ORDEN SE INVIERTE: primero se lanza el bloque PowerShell
(queda sondeando con el probe hasta 15s) y DESPUÉS se da Run al SQL.
`test_hold_group_lock` puede quedar instalada (inofensiva, guardada por
sentinela) — el cleanup la borra igual.

## GUION A — Lock timeout real (holder en editor, probe-gated)

**A-0b) BASELINE de pg_stat_statements** (SQL Editor — anotar `calls` por fila):

```sql
SELECT queryid, calls FROM pg_stat_statements
WHERE query ILIKE '%confirm_reservation_payment_v2%'
ORDER BY calls DESC;
```

**A-1) PowerShell PRIMERO** (sondea hasta 15 s; línea estampada, UNA sola vez):

```powershell
"[FIRE] $(Get-Date -Format 'HH:mm:ss.fff')"; if (Wait-Lock) { & $rpcJob $U $K $bodyM1 "A-m1" }; "[DONE] $(Get-Date -Format 'HH:mm:ss.fff')"
```

**A-2) SQL Editor INMEDIATAMENTE DESPUÉS** (Run — retiene el carril 20 s):

```sql
BEGIN;
SELECT pg_advisory_xact_lock(hashtext(
  (SELECT id::text FROM groups WHERE name =
    '__TEST_2TABS_' || (SELECT value FROM payment_config WHERE key='test_run_id'))));
SELECT pg_sleep(20);
COMMIT;
```

**Esperado:** en PowerShell: `PROBE: lock retenido...` seguido de
`[A-m1] ~5000 ms → {"result":"temporary_lock_timeout"}` (si en su lugar sale
un error, el catch ahora imprime `body` con el JSON real de PostgREST —
pégalo). Si el probe expira a los 15 s, no se disparó nada: repite dando Run
más rápido.

**A-2b) DELTA de pg_stat_statements** (repetir la consulta de A-0b INMEDIATAMENTE
tras la respuesta): la fila estilo-PostgREST debe subir EXACTAMENTE +1 y no debe
aparecer ninguna fila nueva. Delta ≠ +1 → ejecuciones extra → parar y pegar.

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

## GUION B — Mismo pago simultáneo (holder en editor, probe-gated)

**B-1) PowerShell PRIMERO** (sondea y, al confirmar el lock, lanza los dos jobs):

```powershell
if (Wait-Lock) {
  $j1 = Start-Job -ScriptBlock $rpcJob -ArgumentList $U,$K,$bodyM1,"B-1"
  $j2 = Start-Job -ScriptBlock $rpcJob -ArgumentList $U,$K,$bodyM1,"B-2"
  Receive-Job -Job $j1,$j2 -Wait -AutoRemoveJob
}
```

**B-2) SQL Editor INMEDIATAMENTE DESPUÉS** (Run — retiene el carril 4 s):

```sql
BEGIN;
SELECT pg_advisory_xact_lock(hashtext(
  (SELECT id::text FROM groups WHERE name =
    '__TEST_2TABS_' || (SELECT value FROM payment_config WHERE key='test_run_id'))));
SELECT pg_sleep(4);
COMMIT;
```

**Esperado:** ambos jobs esperan lo que reste de los 4 s (timeout imposible:
espera máxima 4 s < 5 s) y al liberarse: **uno `confirmed`, el otro
`already_processed`** (cualquier orden). Si llegaron tras la liberación
(spawn lento), el invariante es idéntico; el elapsed alto es la evidencia de
contención.

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

## GUION C — Dos pagos del mismo grupo (holder en editor, sin deadlock)

**C-1) PowerShell PRIMERO:**

```powershell
if (Wait-Lock) {
  $j1 = Start-Job -ScriptBlock $rpcJob -ArgumentList $U,$K,$bodyM1,"C-m1"
  $j2 = Start-Job -ScriptBlock $rpcJob -ArgumentList $U,$K,$bodyM2,"C-m2"
  Receive-Job -Job $j1,$j2 -Wait -AutoRemoveJob
}
```

**C-2) SQL Editor INMEDIATAMENTE DESPUÉS** — el MISMO bloque de retención de
4 s de B-2.

**Esperado:** `C-m1` → `already_processed` (confirmado en B), `C-m2` →
`confirmed`. **Sin `40P01`.**

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

### Retiro de helpers INDEPENDIENTE (correr si una prueba falla y el cleanup se pospone)

No toca datos ni evidencia — solo elimina las dos funciones de prueba:

```sql
DROP FUNCTION IF EXISTS public.test_hold_group_lock(INT);
DROP FUNCTION IF EXISTS public.test_lock_probe();
```

## Criterios de paro generales

1. A-0 CONCLUIDA: statement_timeout del rol de API = 8s → retenedor por REST
   descartado; retenedor en editor (sin ese tope) con orden invertido.
2. Probe nunca ve el lock (15 s) → no se disparó nada; repetir dando Run al
   SQL más rápido. Si persiste, pegar el resultado de la consulta de pg_roles.
3. `confirmed` rápido A PESAR de probe=retenido → única evidencia que implicaría
   al mecanismo de la RPC → detener y pegar todo.
4. `40P01` → detener todo.
5. Cualquier otra desviación → detener, pegar, NO limpiar.
