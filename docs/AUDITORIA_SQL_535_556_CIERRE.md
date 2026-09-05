# Cierre de auditoría — sql/535 a sql/556

**Estado: CERRADA** (2026-08-21)
**Metodología:** comparación de `md5(prosrc)` calculado localmente vs. hash real en `pg_proc`, para cada `CREATE [OR REPLACE] FUNCTION` de cada archivo del rango. Las 2 discrepancias que arrojó esa comparación se resolvieron trayendo `pg_get_functiondef()` completo desde Supabase y comparándolo línea por línea contra los archivos locales.

## SQL efectivamente vigentes en producción hoy

Esta lista cubre la cadena de trabajo de esta sesión (horas extra, backfill de anuncios, límite de 3 grupos por evento) — no incluye el bloque base de P1F (`sql/535-535d`), que es un frente aparte, ya deployado y sin cambios pendientes, documentado en su propio momento.

| SQL | Contenido vigente |
|---|---|
| 539 | `process_refund_reversal` (con notificaciones) + política RLS `prc_client_read` |
| 541 | `confirm_extra_hour_stripe_payment`, `release_extra_hours_partial`, `release_extra_hours_final` (currency-aware) |
| 542 | `request_withdrawal` (wallet personal) |
| 543 | `admin_refund_withdrawal` |
| 546 | `trg_referral_reward_on_payment` |
| 547 | `confirm_bid_payment`, `confirm_recommendation_payment`, `mark_ad_payment`, `renew_recommendation_subscription`, `renew_sponsored_subscription` |
| 548 | Backfill de datos — 13 anuncios MercadoPago acreditados ($4,087 MXN), ya aplicado, no repetible por diseño (idempotente si se re-corriera) |
| 549 | `start_event` (ancla de reloj de servidor para el timer de evento) |
| 550 | `approve_extra_hour_payment_atomic` (fix doble crédito) |
| 551 | `group_confirm_extra_hours` (fix doble crédito + auditoría) |
| 554 | `confirm_cash_extra_payment` (fix idempotencia — versión final, reemplaza a 552) |
| 556 | `create_booking_with_event` + `enforce_max_groups_per_event()` + trigger `trg_enforce_max_groups_per_event` (límite de 3 grupos por evento) |

## Discrepancias investigadas y resueltas (falsos positivos)

- **`claim_reservation_refund`** (sql/535): la versión viva coincide funcionalmente al 100% con el archivo local — la única diferencia era 1 línea de comentario ausente en producción. Sin lógica ejecutable distinta.
- **`settle_group_cancellation`** (sql/538): confirmado que el **fix real de sql/538 está activo en producción** (rama `IF v_credited > 0`, `type='debit_refund'` con monto positivo — no el bug original de sql/535c con monto negativo). La única diferencia era un bloque de 7 líneas de comentario explicativo ausente en producción.

En ambos casos, el hash no coincidía por comentarios/documentación agregados al archivo local después del despliegue original, nunca por una diferencia de comportamiento.

## Scripts de QA/regresión — nunca deben desplegarse

`sql/536`, `537`, `540`, `555` son autorevertibles por diseño (terminan siempre en `RAISE EXCEPTION`, sin `COMMIT`). `sql/553` es un documento de plan, nunca se ejecutó como archivo único. Ninguno deja ni debe dejar cambios persistentes en la base.

## Archivos de rollback — sin ejecutar

`sql/535_..._ROLLBACK`, `538_..._ROLLBACK`, `539_..._ROLLBACK` — confirmado, ninguno se ha ejecutado (evidencia: las versiones "arregladas" están vivas, no las que estos rollbacks restaurarían). Solo deben correrse en una emergencia deliberada.

## Sin pendientes

- Sin SQL por desplegar dentro del rango 535-556.
- Sin backfills pendientes.
- Sin correcciones derivadas de esta auditoría.

## Frontend asociado a sql/556

Commit `c6094e2` — `src/screens/client/BookingScreen.tsx`, `QuotePaymentScreen.tsx`, `src/i18n/locales/es.json`, `en.json` (manejo de `event_group_limit_reached` en ambas rutas de creación de reserva). Sin pipeline de deploy configurado en el repo (sin `eas.json`/`projectId`) — el build/deploy real queda pendiente del lado del usuario, con su propio mecanismo.

---

*Auditoría 535-556 cerrada 2026-08-21.*
