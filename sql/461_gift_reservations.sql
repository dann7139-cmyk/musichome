-- ════════════════════════════════════════════════════════════════════
-- sql/461_gift_reservations.sql
-- Caja de regalo V1 — Etapa 1: marca una reserva como REGALO + datos del
-- destinatario para el Ticket de Regalo.
--
-- Solo METADATA. NO toca wallet, pagos, comisiones, GPS ni anti-fraude.
-- El comprador sigue siendo `client_id` (él paga y recibe reembolsos).
-- El destinatario NO tiene cuenta en V1: recibe el ticket del comprador.
-- Reusa el `folio` existente de la reserva como folio del regalo.
-- ════════════════════════════════════════════════════════════════════

ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS is_gift                BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS gift_recipient_name    TEXT,
  ADD COLUMN IF NOT EXISTS gift_recipient_contact TEXT,   -- opcional (para el ticket "Para:")
  ADD COLUMN IF NOT EXISTS gift_message           TEXT;

-- Mismos campos en `quotes`: el flujo programado crea la cotización en QuoteForm
-- (con el regalo) y al aceptar/pagar se copian a la reserva. Reuso del flujo 100%.
ALTER TABLE public.quotes
  ADD COLUMN IF NOT EXISTS is_gift                BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS gift_recipient_name    TEXT,
  ADD COLUMN IF NOT EXISTS gift_recipient_contact TEXT,
  ADD COLUMN IF NOT EXISTS gift_message           TEXT;

-- Índice para listar los regalos de un comprador rápido (Mis Reservas → Compartir regalo)
CREATE INDEX IF NOT EXISTS idx_reservations_gift
  ON public.reservations(client_id)
  WHERE is_gift = true;

-- ── Verificación ────────────────────────────────────────────────────
SELECT column_name, data_type, column_default
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'reservations'
  AND (column_name = 'is_gift' OR column_name LIKE 'gift_%')
ORDER BY column_name;
-- Esperado: is_gift (boolean, default false), gift_message, gift_recipient_contact, gift_recipient_name
