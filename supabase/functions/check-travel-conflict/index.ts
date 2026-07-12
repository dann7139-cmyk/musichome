// ═══════════════════════════════════════════════════════════════════
// check-travel-conflict  –  Supabase Edge Function
//
// Valida si agregar un evento al grupo genera conflicto logístico:
//   • Traslape de horario
//   • Buffer insuficiente (< 2h)
//   • Tiempo de traslado > tiempo disponible (si hay coordenadas)
//
// Body: {
//   group_id:       string  (UUID del grupo)
//   event_date:     string  (YYYY-MM-DD)
//   event_time?:    string  (HH:MM o HH:MM:SS, default 20:00)
//   duration_hours?: number (default 3)
//   lat?:           number  (latitud del nuevo evento)
//   lng?:           number  (longitud del nuevo evento)
//   skip_id?:       string  (UUID de reserva a ignorar — para reschedule)
// }
//
// Requiere en Supabase Secrets (opcional):
//   GOOGLE_MAPS_API_KEY  — habilita cálculo de tiempo de traslado real.
//                          Sin clave, solo valida buffer de tiempo.
// ═══════════════════════════════════════════════════════════════════

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const supabase = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
);

const GOOGLE_KEY    = Deno.env.get('GOOGLE_MAPS_API_KEY') ?? '';
const BUFFER_MIN    = 120;  // minutos de buffer mínimo entre eventos
const SETUP_MIN     = 30;   // minutos de instalación/prep (se descuenta del gap)

const cors = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function ok(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, 'Content-Type': 'application/json' },
  });
}

/** Parsea 'HH:MM' o 'HH:MM:SS' → minutos desde medianoche */
function toMin(time: string): number {
  const [h, m] = time.split(':').map(Number);
  return h * 60 + (m ?? 0);
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });

  try {
    // ── Auth ──────────────────────────────────────────────────────────
    const jwt = (req.headers.get('Authorization') ?? '').replace('Bearer ', '').trim();
    if (!jwt) return ok({ error: 'No autorizado' }, 401);
    const { data: { user }, error: authErr } = await supabase.auth.getUser(jwt);
    if (authErr || !user) return ok({ error: 'No autorizado' }, 401);

    const {
      group_id,
      event_date,
      event_time    = '20:00',
      duration_hours = 3,
      lat,
      lng,
      skip_id       = '',
    } = await req.json();

    if (!group_id || !event_date) {
      return ok({ error: 'group_id y event_date son requeridos' }, 400);
    }

    // ── Calcular rango de fechas a consultar (día anterior y siguiente) ──
    const base    = new Date(event_date + 'T12:00:00Z');
    const prevDay = new Date(base); prevDay.setUTCDate(base.getUTCDate() - 1);
    const nextDay = new Date(base); nextDay.setUTCDate(base.getUTCDate() + 1);

    const fmt = (d: Date) => d.toISOString().split('T')[0];
    const prevDateStr = fmt(prevDay);
    const nextDateStr = fmt(nextDay);

    // ── Consultar otros eventos del grupo en ±1 día ────────────────────
    // Cubre reservas de AMBOS flujos (programadas y express): todas viven en
    // reservations. Duración real: hours_count → quote.duration_hours → 3.
    // (La tabla packages fue erradicada — sql/445; no referenciarla.)
    let query = supabase
      .from('reservations')
      .select('id, event_date, event_time, event_lat, event_lng, hours_count, quote:quotes!quote_id(duration_hours)')
      .eq('group_id', group_id)
      .in('event_date', [prevDateStr, event_date, nextDateStr])
      .in('status', ['confirmed', 'accepted', 'in_progress']);
    if (skip_id) query = query.neq('id', skip_id);
    const { data: others, error: qErr } = await query;

    if (qErr) {
      // No fallar cerrado por un error de consulta, pero dejarlo VISIBLE en logs
      console.error('check-travel-conflict query error:', qErr.message);
      return ok({ conflict: false, warning: 'query_failed' });
    }
    if (!others || others.length === 0) {
      return ok({ conflict: false });
    }

    // ── Nuevo evento: rango en minutos relativos al día objetivo ───────
    const newStart = toMin(event_time);
    const newEnd   = newStart + duration_hours * 60;

    for (const ev of others) {
      if (!ev.event_time) continue;

      const evDuration = Number(ev.hours_count)
        || (ev.quote as any)?.duration_hours
        || 3;
      const evStartRaw = toMin(ev.event_time as string);
      const evEndRaw   = evStartRaw + evDuration * 60;

      // Offset en minutos según diferencia de fecha
      const offset = ev.event_date === prevDateStr ? -1440
                   : ev.event_date === nextDateStr ?  1440
                   : 0;

      const evStart = evStartRaw + offset;
      const evEnd   = evEndRaw   + offset;

      // Gap mínimo entre los dos eventos (negativo = traslape)
      const gapAfterEv  = newStart - evEnd;   // nuevo empieza X min después de ev
      const gapBeforeEv = evStart - newEnd;   // ev empieza X min después de nuevo

      const gap = Math.min(gapAfterEv, gapBeforeEv);

      if (gap >= BUFFER_MIN) continue;  // suficiente buffer — no hay conflicto

      // ── Verificar si hay traslado real (Google Distance Matrix) ────
      let travel_minutes: number | undefined;

      if (GOOGLE_KEY && lat != null && lng != null && ev.event_lat != null && ev.event_lng != null) {
        try {
          const url = [
            'https://maps.googleapis.com/maps/api/distancematrix/json',
            `?origins=${ev.event_lat},${ev.event_lng}`,
            `&destinations=${lat},${lng}`,
            '&mode=driving',
            `&key=${GOOGLE_KEY}`,
          ].join('');

          const r = await fetch(url);
          const d = await r.json();
          const secs = d?.rows?.[0]?.elements?.[0]?.duration?.value;
          if (secs) travel_minutes = Math.ceil(secs / 60);
        } catch (_) { /* skip — tiempo-only fallback */ }
      }

      if (travel_minutes != null) {
        // Con distancia: verificar si cabe el traslado en el gap disponible
        const availableForTravel = gap - SETUP_MIN;
        if (travel_minutes <= availableForTravel) continue; // cabe — no hay conflicto

        const hrs = Math.floor(travel_minutes / 60);
        const min = travel_minutes % 60;
        return ok({
          conflict:       true,
          reason:         'travel_time',
          gap_minutes:    gap,
          travel_minutes,
          message_client: 'Este grupo no está disponible por logística y tiempo de traslado.',
          message_group:  `Tiempo de traslado estimado: ${hrs}h ${min}m — insuficiente para llegar a tiempo.`,
        });
      }

      // Sin distancia: verificar buffer mínimo puro
      if (gap < BUFFER_MIN) {
        return ok({
          conflict:       true,
          reason:         gap < 0 ? 'overlap' : 'time_buffer',
          gap_minutes:    gap,
          travel_minutes: undefined,
          message_client: gap < 0
            ? 'Este grupo ya tiene un evento en ese horario.'
            : 'Este grupo no está disponible por logística y tiempo de traslado.',
          message_group: gap < 0
            ? `Los eventos se traslapan (${Math.abs(gap)} min de traslape).`
            : `Buffer insuficiente entre eventos: ${gap} min disponibles, mínimo ${BUFFER_MIN} min.`,
        });
      }
    }

    return ok({ conflict: false });

  } catch (err: any) {
    console.error('[check-travel-conflict]', err);
    return ok({ conflict: false }); // fail open — no bloquear por error del server
  }
});
