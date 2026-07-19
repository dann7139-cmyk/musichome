# Guion de concurrencia F2.2 — v3 (SQL Editor + PostgREST/PowerShell)

**Estado: EN REVISIÓN — no ejecutar hasta aprobación.**
**Entorno: EXCLUSIVAMENTE Supabase Branch / staging / clon. PROHIBIDO en producción.**

## Por qué v3 (hallazgo del intento v2)

El SQL Editor de Supabase NO ejecuta pestañas en sesiones concurrentes: las
consultas de todas las pestañas pasan por el mismo backend y se encolan en
serie. En el intento v2, la "pestaña 2" corrió DESPUÉS del sueño de la
pestaña 1 (lock ya liberado) → nunca hubo contención → no pudo aparecer
`temporary_lock_timeout`. El mecanismo de locking de la RPC es correcto
(hash verificado: 2006748557; pruebas de sesión única 21/21). La RPC NO se toca.

**v3 divide los papeles:**
- **SQL Editor** = retener locks (su única conexión sí los sostiene durante
  `pg_sleep`) + setup + verificaciones + cleanup.
- **PowerShell → PostgREST** = las llamadas concurrentes a la RPC, cada una en
  una conexión del pool de PostgREST con la service key de la RAMA. Es el
  MISMO camino que usarán los webhooks en producción (supabase-js → PostgREST
  → service_role), incluido el statement_timeout del rol.

Nota: si alguna llamada REST devolviera un error de timeout del servidor
(57014) en vez del JSON `temporary_lock_timeout`, eso significa que el
`statement_timeout` del rol es menor que la espera del lock — sigue probando
que el bloqueo ocurre y es exactamente lo que vería el webhook (500 →
reintento). Repórtalo tal cual.

## Decisión de entorno

Rama/staging con sql/514, 516, 518 y 519 aplicados.
- **Perfiles:** EXCLUSIVAMENTE el perfil dedicado `test-2tabs@daricefy.test`,
  creado en Auth de la rama (su fila en profiles la genera el trigger
  `on_auth_user_created` de sql/02; plan B: INSERT manual desde auth.users).
  El setup ABORTA si no existe — jamás elige otro perfil.
- **Wallets:** solo clones desechables de la rama. Nada real cambia.

## Candado duro anti-producción (sentinela)

```sql
-- ⚠️ SOLO EN LA RAMA/STAGING — JAMÁS ejecutar esto en producción
INSERT INTO payment_config (key, value, description)
VALUES ('environment', 'staging', 'Marca de entorno de pruebas — nunca debe existir en producción')
ON CONFLICT (key) DO NOTHING;
```

Todos los bloques de escritura abortan si esta clave no existe. Las claves
`environment=staging` y `test_run_id` viven SOLO en la rama: no están en
ningún archivo sql/ del repo ni migración, y mueren con la rama.

## Identificadores por corrida (test_run_id)

El setup genera `T2B_YYYYMMDDHHMMSS`, lo guarda en payment_config y todo lo
lee de ahí (SQL con subconsultas; PowerShell lo descarga por REST). Cero
edición manual de IDs.

## Qué NO participa

Cero servicios externos: SQL + REST contra la rama. La RPC no hace red;
webhooks/EFs/Stripe/Conekta no participan; órdenes y cargos son sintéticos.
Ningún pago real.

## Orden de ejecución completo

1. Crear la Supabase Branch.
2. Confirmar que 514, 516, 518 y 519 existen en la rama.
3. Crear el usuario dedicado `test-2tabs@daricefy.test` en Auth de la rama.
4. Insertar la sentinela `environment=staging` (solo en la rama).
5. **Verificar visualmente el project ref de la rama** en la URL del dashboard
   Y en la variable `$U` de PowerShell — sin esto no se ejecuta nada.
6. **Si hubo una corrida previa (aunque fallara): CLEANUP primero** y setup nuevo.
7. Preflight → `1 · 0 · 0 · 4 · 2 · 1 · <uuid>`.
8. Setup → `run · 1 · 2 · 2`.
9. Preparar PowerShell (bloque PS-0).
10. Guion A + verificación A.
11. Guion B + verificación B.
12. Guion C + verificación C.
13. Cleanup + ceros finales.
14. Eliminar la rama.

---

## PASO 1 — PREFLIGHT (solo lectura, SQL Editor)

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

**Criterio de paro:** `1 · 0 · 0 · 4 · 2 · 1 · <uuid>`. Si `perfil_test_1=0`,
crear el usuario dedicado (el setup NO elige otro: aborta). Si hay run previo
o residuos, cleanup primero.

## PASO 2 — SETUP (SQL Editor, una corrida)

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

## PASO 3 — PS-0: preparar PowerShell (una ventana, pegar completo)

Toma la URL y la **service_role key DE LA RAMA** (Settings → API de la rama).
Verifica visualmente que `$U` es el ref de la rama, no producción.

```powershell
$U = "https://TU-REF-DE-RAMA.supabase.co"    # ⚠️ ref de la RAMA
$K = "SERVICE_ROLE_KEY_DE_LA_RAMA"
$H = @{ apikey = $K; Authorization = "Bearer $K" }

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
"PS-0 listo"
```

**Criterio:** imprime `run`, `r1`, `r2` (uuid) y `PS-0 listo`. Si algo viene
vacío, detente.

---

## GUION A — Lock timeout real

**1) SQL Editor** (retiene el carril 20s — Run y cambia de ventana):

```sql
BEGIN;
SELECT pg_advisory_xact_lock(hashtext(
  (SELECT id::text FROM groups WHERE name =
    '__TEST_2TABS_' || (SELECT value FROM payment_config WHERE key='test_run_id'))));
SELECT pg_sleep(20);
COMMIT;
```

**2) PowerShell** (dentro de los 20s — tenlo pre-escrito y da Enter):

```powershell
& $rpcJob $U $K $bodyM1 "A-m1"
```

**Esperado:** ~5000 ms → `{"result":"temporary_lock_timeout"}` (o error de
timeout del servidor si el statement_timeout del rol es menor — ver nota
inicial; ambos prueban el bloqueo). Cero escrituras.

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

**Paro A:** respuesta en <4000 ms o `confirmed` → el lock no estaba retenido
(¿corriste el bloque del editor?) · escrituras tras timeout → fallo grave →
detener, pegar, NO limpiar.

---

## GUION B — Mismo pago simultáneo (carrera real sobre el UNIQUE)

**1) SQL Editor** (retiene el carril 4s):

```sql
BEGIN;
SELECT pg_advisory_xact_lock(hashtext(
  (SELECT id::text FROM groups WHERE name =
    '__TEST_2TABS_' || (SELECT value FROM payment_config WHERE key='test_run_id'))));
SELECT pg_sleep(4);
COMMIT;
```

**2) PowerShell** (INMEDIATAMENTE — dos jobs en paralelo con el MISMO pago m1):

```powershell
$j1 = Start-Job -ScriptBlock $rpcJob -ArgumentList $U,$K,$bodyM1,"B-1"
$j2 = Start-Job -ScriptBlock $rpcJob -ArgumentList $U,$K,$bodyM1,"B-2"
Receive-Job -Job $j1,$j2 -Wait -AutoRemoveJob
```

**Esperado:** ambos jobs esperan el carril (elapsed ~1000-4000 ms) y al
liberarse: **uno `confirmed` y el otro `already_processed`** — en cualquier
orden. Si los jobs arrancaron tarde y no esperaron (elapsed bajo), el
invariante se mantiene igual (uno confirma, el otro es idempotente); el
elapsed alto es la evidencia de que hubo contención real.

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

**Paro B:** 2 receipts, 2 créditos, balance ≠ 1000, o AMBOS jobs `confirmed`
→ el UNIQUE falló bajo carrera = fallo crítico → detener, pegar, NO limpiar.

---

## GUION C — Dos pagos del mismo grupo (serialización sin deadlock)

**1) SQL Editor** (retiene el carril 4s — mismo bloque que B).

**2) PowerShell** (INMEDIATAMENTE — m1 repetido y m2 en paralelo):

```powershell
$j1 = Start-Job -ScriptBlock $rpcJob -ArgumentList $U,$K,$bodyM1,"C-m1"
$j2 = Start-Job -ScriptBlock $rpcJob -ArgumentList $U,$K,$bodyM2,"C-m2"
Receive-Job -Job $j1,$j2 -Wait -AutoRemoveJob
```

**Esperado:** ambos esperan el carril y se serializan: `C-m1` →
`already_processed` (ya se confirmó en B) y `C-m2` → `confirmed`. **Sin
error de deadlock (40P01) en ninguno.**

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

**Paro C:** `40P01` en cualquier job = evidencia crítica contra el orden de
locks → detener TODO y pegar el error completo · balance ≠ 2000 → detener.

---

## CLEANUP (SQL Editor, una corrida — al terminar o tras capturar evidencia)

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
COMMIT;

-- Verificación post-cleanup (esperado: todo 0)
SELECT
  (SELECT COUNT(*) FROM payment_config WHERE key='test_run_id')                    AS run_0,
  (SELECT COUNT(*) FROM groups        WHERE name ~ '^__TEST_2TABS')                AS grupos_0,
  (SELECT COUNT(*) FROM reservations  WHERE address LIKE 'Av. Prueba T2B_%')       AS reservas_0,
  (SELECT COUNT(*) FROM payment_attempts WHERE client_key LIKE 'T2B_%')            AS attempts_0,
  (SELECT COUNT(*) FROM payment_receipts WHERE provider_payment_id LIKE 'T2B_%')   AS receipts_0,
  (SELECT COUNT(*) FROM refund_intents  WHERE provider_payment_id LIKE 'T2B_%')    AS refunds_0;
```

## Criterios de paro generales

1. Preflight/PS-0 incompletos → no seguir.
2. Cualquier resultado distinto al esperado (salvo los "también válido"
   documentados) → detener, pegar tal cual, NO ejecutar el cleanup.
3. Deadlock `40P01` → detener todo; evidencia crítica.
4. La service key de la rama muere con la rama (paso 14) — no reutilizarla.
5. Post-cleanup todo 0; si algo queda > 0, pegar antes de tocar nada.
