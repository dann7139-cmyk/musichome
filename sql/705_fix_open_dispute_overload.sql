-- ═══════════════════════════════════════════════════════════════════════════
-- 705 — desambigua `open_dispute`: retira la firma de 3 argumentos
-- ═══════════════════════════════════════════════════════════════════════════
-- CORRECCIÓN PRE-RELEASE. NO cambia la lógica de disputas, ni la de resolución,
-- ni nada financiero. Solo elimina una de dos firmas duplicadas para que la
-- llamada que ya hace la app resuelva de forma inequívoca. El cuerpo de la firma
-- que sobrevive no se toca ni una línea.
--
-- ── EL PROBLEMA (medido) ───────────────────────────────────────────────────
-- La app llama con 2 claves: `p_reservation_id, p_reason`
-- (src/screens/client/ReservationsScreen.tsx:1688). En producción hay dos
-- funciones que aceptan justo ese conjunto:
--   · oid 77550 → (uuid, text)
--   · oid 51572 → (uuid, text, text[] DEFAULT '{}')
-- La segunda encaja porque su tercer parámetro tiene DEFAULT → **42725 "function
-- is not unique"**, verificado con las claves exactas de la app en una
-- transacción revertida. Consecuencia real hoy: **el cliente no puede abrir una
-- disputa**; el botón "Reportar un problema" falla siempre.
--
-- ── CUÁL SOBREVIVE Y POR QUÉ: la de 2 argumentos (oid 77550) ───────────────
-- No es una cuestión de antigüedad, es de a qué tabla escriben:
--   · La de 2 args escribe en **`disputes`**, que es la tabla que leen **15
--     funciones**, entre ellas las guardas financieras
--     `release_group_earnings_atomic`, `claim_reservation_refund`,
--     `release_all_eligible_payments`, `group_request_payment` y
--     `resolve_dispute`, más las colas del admin. Es decir: una disputa abierta
--     por esta vía SÍ bloquea pagos y reembolsos, que es el efecto que se espera.
--   · La de 3 args escribe en **`event_disputes`**, tabla que solo leen
--     `open_dispute` (ella misma) y `recalculate_group_reputation`. Ninguna guarda
--     financiera la consulta → una disputa abierta por ahí **no bloquearía nada**.
-- Además la de 2 args tiene el OID más alto (77550 > 51572), o sea es la
-- posterior, y es la que referencia el comentario del código de la app
-- ("open_dispute, sql/483"). Trae también la ventana de 7 días y el límite de 3
-- disputas por usuario en 30 días, protecciones que la otra no tiene.
--
-- ── SE DEMUESTRA QUE NADIE DEPENDE DE LA QUE SE RETIRA ────────────────────
--   · funciones SQL que invocan open_dispute ... NINGUNA
--   · triggers ................................ NINGUNO
--   · crons ................................... NINGUNO
--   · Edge Functions .......................... NINGUNA (las coincidencias en
--       `process-refund` son la cadena de error `open_dispute_blocks_refund`,
--       no una llamada)
--   · web/src ................................. NINGUNA
--   · app ..................................... 1 sitio, con 2 claves
--   · nadie, en ningún lado, manda `p_evidence_urls`
-- Y la tabla `event_disputes` tiene **0 filas**, coherente con que su único
-- escritor era inalcanzable por la propia ambigüedad. Retirarla no pierde datos.
--
-- Lo que NO se hace aquí: no se borra la tabla `event_disputes` ni se toca
-- `recalculate_group_reputation` (seguirá leyéndola y encontrando 0 filas, igual
-- que hoy). Eso sería limpieza fuera de alcance.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

DO $guard$
DECLARE v_n INT;
BEGIN
  SELECT COUNT(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='open_dispute';
  IF v_n <> 2 THEN
    RAISE EXCEPTION 'Se esperaban 2 firmas de open_dispute y hay %. Reauditar antes de continuar.', v_n;
  END IF;
  IF to_regprocedure('public.open_dispute(uuid, text)') IS NULL THEN
    RAISE EXCEPTION 'No existe la firma de 2 argumentos que debe sobrevivir. Abortando.';
  END IF;
  -- Si event_disputes tuviera filas, alguien sí usó la otra firma: parar.
  IF (SELECT COUNT(*) FROM public.event_disputes) > 0 THEN
    RAISE EXCEPTION 'event_disputes tiene filas: la firma de 3 argumentos SI se uso. Revisar antes de retirarla.';
  END IF;
END
$guard$;

DROP FUNCTION public.open_dispute(UUID, TEXT, TEXT[]);

NOTIFY pgrst, 'reload schema';

COMMIT;
